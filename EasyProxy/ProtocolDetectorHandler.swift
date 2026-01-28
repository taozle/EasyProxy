import NIOCore
import NIOHTTP1
import Logging

/// Reads the first byte of each new connection to determine if it's HTTP or SOCKS5.
/// - ASCII byte (e.g., 'G', 'C', 'P', 'H') → HTTP protocol: install HTTP codec + ProxyHandler
/// - 0x05 → SOCKS5 protocol: install SOCKS5Handler
final class ProtocolDetectorHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let stats: ProxyStats
    private var logger = Logger(label: "proxy.detector")
    private var detected = false

    init(stats: ProxyStats) {
        self.stats = stats
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !detected else {
            context.fireChannelRead(data)
            return
        }

        let buffer = unwrapInboundIn(data)
        guard let firstByte = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) else {
            logger.error("Empty first read — closing")
            context.close(promise: nil)
            return
        }

        detected = true

        if firstByte == 0x05 {
            installSOCKS5(context: context, buffer: buffer)
        } else {
            installHTTP(context: context, buffer: buffer)
        }
    }

    // MARK: - HTTP pipeline

    private func installHTTP(context: ChannelHandlerContext, buffer: ByteBuffer) {
        let channel = context.channel
        let pipeline = context.pipeline
        let handlers: [ChannelHandler] = [
            ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
            HTTPResponseEncoder(),
            IdleStateHandler(
                readTimeout: TimeAmount.seconds(ProxyConfig.idleTimeoutSeconds),
                writeTimeout: TimeAmount.seconds(ProxyConfig.idleTimeoutSeconds)
            ),
            CloseOnIdleHandler(),
            ConcurrencyHandler(stats: stats),
            ProxyHandler(stats: stats),
        ]

        // Remove self and add HTTP handlers
        pipeline.removeHandler(self).whenSuccess {
            pipeline.addHandlers(handlers).whenComplete { result in
                switch result {
                case .success:
                    // Re-fire from pipeline head (context is invalid after removeHandler)
                    channel.pipeline.fireChannelRead(NIOAny(buffer))
                case .failure(let error):
                    self.logger.error("Failed to install HTTP handlers: \(error)")
                    channel.close(promise: nil)
                }
            }
        }
    }

    // MARK: - SOCKS5 pipeline

    private func installSOCKS5(context: ChannelHandlerContext, buffer: ByteBuffer) {
        let channel = context.channel
        let pipeline = context.pipeline
        let socks5Handler = SOCKS5Handler(stats: stats)

        pipeline.removeHandler(self).whenSuccess {
            pipeline.addHandler(socks5Handler).whenComplete { result in
                switch result {
                case .success:
                    channel.pipeline.fireChannelRead(NIOAny(buffer))
                case .failure(let error):
                    self.logger.error("Failed to install SOCKS5 handler: \(error)")
                    channel.close(promise: nil)
                }
            }
        }
    }
}
