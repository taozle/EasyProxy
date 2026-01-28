import NIOCore
import NIOHTTP1
import Logging

#if canImport(Network)
import NIOTransportServices
#endif

/// Core proxy handler that dispatches between CONNECT (tunnel) and forward (HTTP) proxy modes.
final class ProxyHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let stats: ProxyStats
    private var logger = Logger(label: "proxy.handler")

    private enum Mode {
        case idle
        case connect(host: String, port: Int)
        case forward(ForwardState)
    }

    private struct ForwardState {
        let host: String
        let port: Int
        var requestHead: HTTPRequestHead
        var bodyParts: [ByteBuffer] = []
    }

    private var mode: Mode = .idle

    // References for handler removal in CONNECT mode
    private weak var decoder: ChannelHandler?
    private weak var encoder: ChannelHandler?

    init(stats: ProxyStats) {
        self.stats = stats
    }

    // MARK: - ChannelInboundHandler

    func handlerAdded(context: ChannelHandlerContext) {
        // Capture references to the HTTP codec handlers for later removal
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let request):
            if request.method == .CONNECT {
                handleConnectHead(context: context, request: request)
            } else {
                handleForwardHead(context: context, request: request)
            }

        case .body(let buffer):
            switch mode {
            case .forward(var state):
                state.bodyParts.append(buffer)
                mode = .forward(state)
            default:
                break
            }

        case .end:
            switch mode {
            case .connect(let host, let port):
                executeConnect(context: context, host: host, port: port)
            case .forward(let state):
                executeForward(context: context, state: state)
            default:
                break
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("ProxyHandler error: \(error)")
        let errorMsg = "\(error)"
        Task { @MainActor in
            self.stats.recordFailed(description: errorMsg)
        }
        context.close(promise: nil)
    }

    // MARK: - CONNECT mode

    private func handleConnectHead(context: ChannelHandlerContext, request: HTTPRequestHead) {
        guard let target = HTTPHeaderUtils.parseConnectTarget(request.uri) else {
            sendErrorAndClose(context: context, status: .badRequest, message: "Invalid CONNECT target")
            return
        }
        logger.info("CONNECT \(target.host):\(target.port)")
        mode = .connect(host: target.host, port: target.port)
    }

    private func executeConnect(context: ChannelHandlerContext, host: String, port: Int) {
        // For CONNECT, upstream is raw TCP — no HTTP codecs
        connectRawUpstream(host: host, port: port, eventLoop: context.eventLoop).whenComplete { result in
            switch result {
            case .success(let upstreamChannel):
                self.connectSucceeded(
                    context: context,
                    upstreamChannel: upstreamChannel
                )
            case .failure(let error):
                self.logger.error("CONNECT upstream failed: \(error)")
                let errorMsg = "\(error)"
                Task { @MainActor in
                    self.stats.recordFailed(description: "CONNECT \(host):\(port) – \(errorMsg)")
                }
                self.sendErrorAndClose(context: context, status: .badGateway, message: "Failed to connect upstream")
            }
        }
    }

    private func connectSucceeded(context: ChannelHandlerContext, upstreamChannel: Channel) {
        // Send 200 Connection Established
        // Must set Content-Length: 0 to prevent HTTPResponseEncoder from adding
        // Transfer-Encoding: chunked, which would inject a "0\r\n\r\n" terminator
        // into the raw TCP stream and corrupt the subsequent TLS handshake.
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "0")
        let response = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(response)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenSuccess {
            // Remove HTTP codecs from client pipeline, then install GlueHandler pair
            self.removeHTTPHandlers(context: context).whenComplete { result in
                switch result {
                case .success:
                    let (clientGlue, upstreamGlue) = GlueHandler.matchedPair()
                    upstreamChannel.pipeline.addHandler(upstreamGlue).flatMap {
                        context.pipeline.addHandler(clientGlue)
                    }.whenComplete { result in
                        switch result {
                        case .success:
                            upstreamChannel.read()
                            context.read()
                        case .failure(let error):
                            self.logger.error("Failed to install GlueHandlers: \(error)")
                            context.close(promise: nil)
                            upstreamChannel.close(promise: nil)
                        }
                    }
                case .failure(let error):
                    self.logger.error("Failed to remove HTTP handlers: \(error)")
                    context.close(promise: nil)
                    upstreamChannel.close(promise: nil)
                }
            }
        }
    }

    private func removeHTTPHandlers(context: ChannelHandlerContext) -> EventLoopFuture<Void> {
        let pipeline = context.pipeline

        // Remove handlers by type — remove self first, then the HTTP encoder, then the decoder
        // Also remove IdleStateHandler and CloseOnIdleHandler since CONNECT tunnels
        // manage their own lifecycle via GlueHandler
        return pipeline.removeHandler(self).flatMap {
            pipeline.context(handlerType: HTTPResponseEncoder.self).flatMap { ctx in
                pipeline.removeHandler(context: ctx)
            }
        }.flatMap {
            pipeline.context(handlerType: ByteToMessageHandler<HTTPRequestDecoder>.self).flatMap { ctx in
                pipeline.removeHandler(context: ctx)
            }
        }.flatMap {
            pipeline.context(handlerType: IdleStateHandler.self).flatMap { ctx in
                pipeline.removeHandler(context: ctx)
            }.flatMapError { _ in
                // IdleStateHandler may have already been removed
                context.eventLoop.makeSucceededVoidFuture()
            }
        }.flatMap {
            pipeline.context(handlerType: CloseOnIdleHandler.self).flatMap { ctx in
                pipeline.removeHandler(context: ctx)
            }.flatMapError { _ in
                context.eventLoop.makeSucceededVoidFuture()
            }
        }
    }

    // MARK: - Forward proxy mode

    private func handleForwardHead(context: ChannelHandlerContext, request: HTTPRequestHead) {
        guard let target = HTTPHeaderUtils.extractTarget(from: request) else {
            sendErrorAndClose(context: context, status: .badRequest, message: "Cannot determine target host")
            return
        }

        logger.info("\(request.method) \(request.uri) -> \(target.host):\(target.port)")

        // Rewrite absolute URI to relative path
        var rewritten = request
        rewritten.uri = HTTPHeaderUtils.rewriteURIToRelative(request.uri)
        HTTPHeaderUtils.removeHopByHopHeaders(&rewritten.headers)

        // Ensure Host header is set
        if rewritten.headers["Host"].isEmpty {
            rewritten.headers.add(name: "Host", value: target.host)
        }

        let state = ForwardState(host: target.host, port: target.port, requestHead: rewritten)
        mode = .forward(state)
    }

    private func executeForward(context: ChannelHandlerContext, state: ForwardState) {
        let clientChannel = context.channel

        connectHTTPUpstream(host: state.host, port: state.port, eventLoop: context.eventLoop).whenComplete { result in
            switch result {
            case .success(let upstreamChannel):
                self.forwardRequest(
                    context: context,
                    clientChannel: clientChannel,
                    upstreamChannel: upstreamChannel,
                    state: state
                )
            case .failure(let error):
                self.logger.error("Forward upstream failed: \(error)")
                let errorMsg = "\(error)"
                Task { @MainActor in
                    self.stats.recordFailed(description: "Forward \(state.host):\(state.port) – \(errorMsg)")
                }
                self.sendErrorAndClose(context: context, status: .badGateway, message: "Failed to connect upstream")
            }
        }
    }

    private func forwardRequest(
        context: ChannelHandlerContext,
        clientChannel: Channel,
        upstreamChannel: Channel,
        state: ForwardState
    ) {
        // Install relay handler on upstream channel
        let relay = UpstreamRelayHandler(
            clientChannel: clientChannel,
            logger: logger,
            stats: stats
        )
        upstreamChannel.pipeline.addHandler(relay).whenComplete { result in
            switch result {
            case .success:
                // Send request head
                upstreamChannel.write(NIOAny(HTTPClientRequestPart.head(state.requestHead)), promise: nil)

                // Send body parts
                for bodyPart in state.bodyParts {
                    upstreamChannel.write(NIOAny(HTTPClientRequestPart.body(.byteBuffer(bodyPart))), promise: nil)
                }

                // Send end
                upstreamChannel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil)), promise: nil)

                // Reset mode for possible keep-alive
                self.mode = .idle

            case .failure(let error):
                self.logger.error("Failed to install relay handler: \(error)")
                upstreamChannel.close(promise: nil)
                self.sendErrorAndClose(context: context, status: .badGateway, message: "Failed to set up upstream relay")
            }
        }
    }

    // MARK: - Upstream connections

    /// Raw TCP connection for CONNECT tunnel (no HTTP codecs).
    private func connectRawUpstream(host: String, port: Int, eventLoop: EventLoop) -> EventLoopFuture<Channel> {
        let timeout = TimeAmount.seconds(ProxyConfig.connectTimeoutSeconds)

        #if canImport(Network)
        let bootstrap = NIOTSConnectionBootstrap(group: eventLoop)
            .connectTimeout(timeout)
        #else
        let bootstrap = ClientBootstrap(group: eventLoop)
            .connectTimeout(timeout)
        #endif

        return bootstrap.connect(host: host, port: port)
    }

    /// HTTP connection for forward proxy mode (with HTTP codecs).
    private func connectHTTPUpstream(host: String, port: Int, eventLoop: EventLoop) -> EventLoopFuture<Channel> {
        let timeout = TimeAmount.seconds(ProxyConfig.connectTimeoutSeconds)

        #if canImport(Network)
        let bootstrap = NIOTSConnectionBootstrap(group: eventLoop)
            .connectTimeout(timeout)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    HTTPRequestEncoder(),
                    ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes)),
                ])
            }
        #else
        let bootstrap = ClientBootstrap(group: eventLoop)
            .connectTimeout(timeout)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    HTTPRequestEncoder(),
                    ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes)),
                ])
            }
        #endif

        return bootstrap.connect(host: host, port: port)
    }

    // MARK: - Helpers

    private func sendErrorAndClose(context: ChannelHandlerContext, status: HTTPResponseStatus, message: String) {
        guard context.channel.isActive else { return }

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Connection", value: "close")
        let body = ByteBuffer(string: message)
        headers.add(name: "Content-Length", value: "\(body.readableBytes)")

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}
