import NIOCore
import NIOHTTP1
import Logging

/// Installed on the upstream channel during forward proxy mode.
/// Receives HTTP responses from the upstream server and relays them back to the client channel.
final class UpstreamRelayHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart

    private weak var clientChannel: Channel?
    private let logger: Logger
    private let stats: ProxyStats
    private var responseComplete = false

    init(clientChannel: Channel, logger: Logger, stats: ProxyStats) {
        self.clientChannel = clientChannel
        self.logger = logger
        self.stats = stats
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        guard let clientChannel = self.clientChannel, clientChannel.isActive else {
            context.close(promise: nil)
            return
        }
        switch part {
        case .head(let response):
            var headers = response.headers
            HTTPHeaderUtils.removeHopByHopHeaders(&headers)
            let clientResponse = HTTPResponseHead(
                version: response.version,
                status: response.status,
                headers: headers
            )
            clientChannel.write(HTTPServerResponsePart.head(clientResponse), promise: nil)

        case .body(let buffer):
            clientChannel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)

        case .end(let trailers):
            responseComplete = true
            clientChannel.writeAndFlush(HTTPServerResponsePart.end(trailers)).whenSuccess {
                // Tell the client channel to read the next request (keep-alive)
                clientChannel.read()
            }
            // Close upstream after response is complete
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !responseComplete, let clientChannel = self.clientChannel, clientChannel.isActive {
            clientChannel.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("Upstream relay error: \(error)")
        let errorMsg = "\(error)"
        Task { @MainActor in
            self.stats.recordFailed(description: "Upstream: \(errorMsg)")
        }
        if let clientChannel = self.clientChannel, clientChannel.isActive {
            clientChannel.close(promise: nil)
        }
        context.close(promise: nil)
    }
}
