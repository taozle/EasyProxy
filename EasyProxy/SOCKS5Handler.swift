import NIOCore
import Logging

#if canImport(Network)
import NIOTransportServices
#endif

/// SOCKS5 proxy handler implementing the state machine:
/// greeting → command → CONNECT (TCP relay via GlueHandler) or UDP ASSOCIATE.
final class SOCKS5Handler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let stats: ProxyStats
    private var logger = Logger(label: "proxy.socks5")

    private enum State {
        case waitingGreeting
        case waitingCommand
        case relaying
    }

    private var state: State = .waitingGreeting
    private var accumulated = ByteBuffer()

    init(stats: ProxyStats) {
        self.stats = stats
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        accumulated.writeBuffer(&buffer)

        switch state {
        case .waitingGreeting:
            handleGreeting(context: context)
        case .waitingCommand:
            handleCommand(context: context)
        case .relaying:
            context.fireChannelRead(data)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("SOCKS5 error: \(error)")
        let errorMsg = "\(error)"
        Task { @MainActor in
            self.stats.recordFailed(description: "SOCKS5: \(errorMsg)")
        }
        context.close(promise: nil)
    }

    // MARK: - Greeting

    private func handleGreeting(context: ChannelHandlerContext) {
        var copy = accumulated
        guard let greeting = SOCKS5GreetingRequest.decode(from: &copy) else {
            // Need more data
            return
        }
        accumulated = copy

        // Accept no-auth if offered, otherwise reject
        let method: SOCKS5.AuthMethod = greeting.methods.contains(SOCKS5.AuthMethod.noAuth.rawValue)
            ? .noAuth
            : .noAcceptable

        let response = SOCKS5GreetingResponse(method: method)
        var out = context.channel.allocator.buffer(capacity: 2)
        response.encode(into: &out)
        context.writeAndFlush(wrapOutboundOut(out), promise: nil)

        if method == .noAcceptable {
            context.close(promise: nil)
            return
        }

        state = .waitingCommand

        // Try to decode command if data was pipelined
        if accumulated.readableBytes > 0 {
            handleCommand(context: context)
        }
    }

    // MARK: - Command

    private func handleCommand(context: ChannelHandlerContext) {
        var copy = accumulated
        guard let request = SOCKS5CommandRequest.decode(from: &copy) else {
            return
        }
        accumulated = copy

        Task { @MainActor in
            self.stats.recordAccepted()
            self.stats.recordSOCKS5Connection()
        }

        switch request.command {
        case .connect:
            logger.info("SOCKS5 CONNECT \(request.address.host):\(request.address.port)")
            executeConnect(context: context, address: request.address)
        case .udpAssociate:
            logger.info("SOCKS5 UDP ASSOCIATE \(request.address.host):\(request.address.port)")
            Task { @MainActor in
                self.stats.recordUDPSessionStarted()
            }
            executeUDPAssociate(context: context, address: request.address)
        case .bind:
            logger.warning("SOCKS5 BIND not supported")
            sendReply(context: context, status: .commandNotSupported,
                      boundAddress: SOCKS5Address(type: .ipv4, host: "0.0.0.0", port: 0))
            context.close(promise: nil)
        }
    }

    // MARK: - CONNECT

    private func executeConnect(context: ChannelHandlerContext, address: SOCKS5Address) {
        let host = address.host
        let port = Int(address.port)

        connectUpstream(host: host, port: port, eventLoop: context.eventLoop).whenComplete { result in
            switch result {
            case .success(let upstreamChannel):
                self.connectSucceeded(context: context, upstreamChannel: upstreamChannel)
            case .failure(let error):
                self.logger.error("SOCKS5 CONNECT failed: \(error)")
                let errorMsg = "\(error)"
                Task { @MainActor in
                    self.stats.recordFailed(description: "SOCKS5 CONNECT \(host):\(port) – \(errorMsg)")
                }
                self.sendReply(context: context, status: .hostUnreachable,
                               boundAddress: SOCKS5Address(type: .ipv4, host: "0.0.0.0", port: 0))
                context.close(promise: nil)
            }
        }
    }

    private func connectSucceeded(context: ChannelHandlerContext, upstreamChannel: Channel) {
        let boundAddr = SOCKS5Address(type: .ipv4, host: "0.0.0.0", port: 0)

        sendReply(context: context, status: .succeeded, boundAddress: boundAddr)

        state = .relaying

        // Track disconnection when the client channel closes
        context.channel.closeFuture.whenComplete { _ in
            Task { @MainActor in
                self.stats.recordDisconnected()
            }
        }

        // Remove self and install GlueHandler pair
        let pipeline = context.pipeline
        pipeline.removeHandler(self).whenSuccess {
            let (clientGlue, upstreamGlue) = GlueHandler.matchedPair()
            upstreamChannel.pipeline.addHandler(upstreamGlue).flatMap {
                pipeline.addHandler(clientGlue)
            }.whenComplete { result in
                switch result {
                case .success:
                    // If there's leftover data after the SOCKS5 handshake, forward it
                    if self.accumulated.readableBytes > 0 {
                        context.fireChannelRead(NIOAny(self.accumulated))
                    }
                    upstreamChannel.read()
                    context.read()
                case .failure(let error):
                    self.logger.error("Failed to install GlueHandlers: \(error)")
                    context.close(promise: nil)
                    upstreamChannel.close(promise: nil)
                }
            }
        }
    }

    // MARK: - UDP ASSOCIATE

    private func executeUDPAssociate(context: ChannelHandlerContext, address: SOCKS5Address) {
        let udpSession = UDPRelaySession(stats: stats, logger: logger)

        udpSession.bind(on: context.eventLoop).whenComplete { result in
            switch result {
            case .success(let boundPort):
                self.logger.info("SOCKS5 UDP relay bound on port \(boundPort)")

                // Reply with the bound address
                let boundAddr = SOCKS5Address(type: .ipv4, host: "0.0.0.0", port: UInt16(boundPort))
                self.sendReply(context: context, status: .succeeded, boundAddress: boundAddr)

                // When the TCP control connection closes, tear down UDP
                context.channel.closeFuture.whenComplete { _ in
                    udpSession.tearDown()
                    Task { @MainActor in
                        self.stats.recordDisconnected()
                        self.stats.recordUDPSessionEnded()
                    }
                }

            case .failure(let error):
                self.logger.error("UDP bind failed: \(error)")
                let errorMsg = "\(error)"
                Task { @MainActor in
                    self.stats.recordFailed(description: "UDP bind: \(errorMsg)")
                }
                self.sendReply(context: context, status: .generalFailure,
                               boundAddress: SOCKS5Address(type: .ipv4, host: "0.0.0.0", port: 0))
                context.close(promise: nil)
            }
        }
    }

    // MARK: - Helpers

    private func sendReply(context: ChannelHandlerContext, status: SOCKS5.ReplyStatus, boundAddress: SOCKS5Address) {
        let reply = SOCKS5CommandReply(status: status, boundAddress: boundAddress)
        var out = context.channel.allocator.buffer(capacity: 32)
        reply.encode(into: &out)
        context.writeAndFlush(wrapOutboundOut(out), promise: nil)
    }

    private func connectUpstream(host: String, port: Int, eventLoop: EventLoop) -> EventLoopFuture<Channel> {
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
}
