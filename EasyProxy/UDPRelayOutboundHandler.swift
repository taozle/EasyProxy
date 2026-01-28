import NIOCore
import Logging

/// Handles replies from the target server on an outbound UDP channel.
/// Wraps replies in a SOCKS5 UDP header and sends them back to the client via the relay channel.
final class UDPRelayOutboundHandler: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let relayChannel: Channel
    private let clientAddress: SocketAddress
    private let targetHost: String
    private let targetPort: Int
    private let logger: Logger

    init(relayChannel: Channel, clientAddress: SocketAddress, targetHost: String, targetPort: Int, logger: Logger) {
        self.relayChannel = relayChannel
        self.clientAddress = clientAddress
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        let payload = envelope.data

        logger.debug("UDP reply from \(targetHost):\(targetPort) (\(payload.readableBytes) bytes)")

        // Determine address type for the header
        let addressType: SOCKS5.AddressType
        if targetHost.contains(":") {
            addressType = .ipv6
        } else if targetHost.first?.isLetter == true {
            addressType = .domain
        } else {
            addressType = .ipv4
        }

        let socks5Addr = SOCKS5Address(type: addressType, host: targetHost, port: UInt16(targetPort))
        let header = SOCKS5UDPHeader(frag: 0, address: socks5Addr)

        // Build response: SOCKS5 UDP header + payload
        var outBuffer = context.channel.allocator.buffer(capacity: 32 + payload.readableBytes)
        header.encode(into: &outBuffer)
        var payloadCopy = payload
        outBuffer.writeBuffer(&payloadCopy)

        let replyEnvelope = AddressedEnvelope(remoteAddress: clientAddress, data: outBuffer)
        relayChannel.writeAndFlush(NIOAny(replyEnvelope), promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("UDP outbound error for \(targetHost):\(targetPort): \(error)")
    }
}
