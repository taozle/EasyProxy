import NIOCore
import NIOPosix
import Logging

/// Manages a single SOCKS5 UDP relay session.
/// Binds a UDP port, installs the inbound handler, and tracks outbound channels.
final class UDPRelaySession {
    private let stats: ProxyStats
    private let logger: Logger
    private var udpChannel: Channel?
    private var outboundChannels: [String: Channel] = [:]

    // UDP uses NIOPosix DatagramBootstrap which needs a compatible event loop.
    private let udpGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    init(stats: ProxyStats, logger: Logger) {
        self.stats = stats
        self.logger = logger
    }

    /// Bind a UDP port. Returns the bound port number.
    func bind(on eventLoop: EventLoop) -> EventLoopFuture<Int> {
        let bootstrap = DatagramBootstrap(group: udpGroup)
            .channelInitializer { channel in
                channel.pipeline.addHandler(UDPRelayInboundHandler(session: self, logger: self.logger, stats: self.stats))
            }

        let promise = eventLoop.makePromise(of: Int.self)

        bootstrap.bind(host: "0.0.0.0", port: 0).whenComplete { result in
            switch result {
            case .success(let channel):
                self.udpChannel = channel
                let port = channel.localAddress?.port ?? 0
                self.logger.info("UDP relay session bound on port \(port)")
                promise.succeed(port)
            case .failure(let error):
                promise.fail(error)
            }
        }

        return promise.futureResult
    }

    /// Get or create an outbound UDP channel to forward data to the target.
    func getOrCreateOutboundChannel(
        targetHost: String,
        targetPort: Int,
        clientAddress: SocketAddress
    ) -> EventLoopFuture<Channel> {
        let key = "\(targetHost):\(targetPort)"

        if let existing = outboundChannels[key], existing.isActive {
            return existing.eventLoop.makeSucceededFuture(existing)
        }

        let bootstrap = DatagramBootstrap(group: udpGroup)
            .channelInitializer { channel in
                channel.pipeline.addHandler(
                    UDPRelayOutboundHandler(
                        relayChannel: self.udpChannel!,
                        clientAddress: clientAddress,
                        targetHost: targetHost,
                        targetPort: targetPort,
                        logger: self.logger
                    )
                )
            }

        return bootstrap.bind(host: "0.0.0.0", port: 0).map { channel in
            self.outboundChannels[key] = channel
            return channel
        }
    }

    /// Tear down the UDP session: close all outbound channels and the relay channel.
    func tearDown() {
        logger.info("Tearing down UDP relay session")
        for (_, channel) in outboundChannels {
            channel.close(promise: nil)
        }
        outboundChannels.removeAll()
        udpChannel?.close(promise: nil)
        udpChannel = nil

        udpGroup.shutdownGracefully { error in
            if let error = error {
                self.logger.error("UDP event loop shutdown error: \(error)")
            }
        }
    }
}
