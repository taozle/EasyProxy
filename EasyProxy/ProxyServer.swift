import NIOCore
import NIOHTTP1
import NIOPosix
import Logging

#if canImport(Network)
import NIOTransportServices
import Network
#endif

final class ProxyServer: @unchecked Sendable {
    private var channel: Channel?
    private var group: EventLoopGroup?
    private var logger = Logger(label: "proxy.server")

    func start(stats: ProxyStats) async throws {
        let port = ProxyConfig.port

        #if canImport(Network)
        let group = NIOTSEventLoopGroup()
        self.group = group

        let channel = try await NIOTSListenerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(ProtocolDetectorHandler(stats: stats))
            }
            .bind(host: "0.0.0.0", port: port)
            .get()
        #else
        let group = MultiThreadedEventLoopGroup.singleton
        self.group = group

        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(ProtocolDetectorHandler(stats: stats))
            }
            .bind(host: "0.0.0.0", port: port)
            .get()
        #endif

        self.channel = channel
        logger.info("Proxy server started on 0.0.0.0:\(port)")
    }

    func stop() {
        logger.info("Stopping proxy server")
        channel?.close(mode: .all, promise: nil)
        channel = nil

        group?.shutdownGracefully { error in
            if let error = error {
                self.logger.error("EventLoopGroup shutdown error: \(error)")
            }
        }
        group = nil
    }
}

// MARK: - Idle timeout handler

/// Closes the channel when an idle event is triggered by IdleStateHandler.
final class CloseOnIdleHandler: ChannelInboundHandler {
    typealias InboundIn = NIOAny

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent {
            context.close(promise: nil)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }
}
