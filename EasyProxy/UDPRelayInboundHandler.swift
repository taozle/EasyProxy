import NIOCore
import Logging

/// Handles inbound UDP datagrams on the relay port.
/// Parses the SOCKS5 UDP header and forwards the payload to the target.
final class UDPRelayInboundHandler: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let session: UDPRelaySession
    private let logger: Logger
    private let stats: ProxyStats

    init(session: UDPRelaySession, logger: Logger, stats: ProxyStats) {
        self.session = session
        self.logger = logger
        self.stats = stats
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        var buffer = envelope.data
        let clientAddress = envelope.remoteAddress

        // Parse SOCKS5 UDP header
        guard let (header, payload) = SOCKS5UDPHeader.decode(from: &buffer) else {
            logger.warning("Invalid SOCKS5 UDP header from \(clientAddress)")
            return
        }

        // Fragment reassembly not supported — only accept frag=0
        guard header.frag == 0 else {
            logger.warning("Fragmented SOCKS5 UDP not supported (frag=\(header.frag))")
            return
        }

        let targetHost = header.address.host
        let targetPort = Int(header.address.port)

        logger.debug("UDP relay: \(clientAddress) -> \(targetHost):\(targetPort) (\(payload.readableBytes) bytes)")

        Task { @MainActor in
            self.stats.recordUDPPacket()
        }

        // Get or create outbound channel to the target
        session.getOrCreateOutboundChannel(
            targetHost: targetHost,
            targetPort: targetPort,
            clientAddress: clientAddress
        ).whenComplete { result in
            switch result {
            case .success(let outboundChannel):
                // Resolve target and forward
                do {
                    let targetAddr = try SocketAddress.makeAddressResolvingHost(targetHost, port: targetPort)
                    let outEnvelope = AddressedEnvelope(remoteAddress: targetAddr, data: payload)
                    outboundChannel.writeAndFlush(NIOAny(outEnvelope), promise: nil)
                } catch {
                    self.logger.error("Failed to resolve \(targetHost):\(targetPort): \(error)")
                }
            case .failure(let error):
                self.logger.error("Failed to create outbound channel: \(error)")
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("UDP relay inbound error: \(error)")
    }
}
