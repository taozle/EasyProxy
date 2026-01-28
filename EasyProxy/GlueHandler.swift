// GlueHandler.swift
// Based on Apple's swift-nio-examples/connect-proxy
// https://github.com/apple/swift-nio-examples/blob/main/connect-proxy/Sources/ConnectProxy/GlueHandler.swift
//
// Bidirectional TCP relay with backpressure support.
// Used for CONNECT tunnel mode.

import NIOCore

final class GlueHandler {
    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    private init() {}
}

extension GlueHandler {
    /// Creates a matched pair of GlueHandlers that relay data between two channels.
    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler()
        let second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }
}

extension GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias InboundOut = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        self.partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.partnerWrite(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerCloseFull(context: context)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            partner?.partnerWriteEOF()
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        partner?.partnerCloseFull(context: context)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        } else {
            partner?.partnerBecameUnwritable()
        }
    }

    func read(context: ChannelHandlerContext) {
        if let partner = self.partner, partner.partnerIsWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }

    // MARK: - Partner callbacks

    private var partnerIsWritable: Bool {
        context?.channel.isWritable ?? false
    }

    private func partnerWrite(_ data: NIOAny) {
        guard let context = self.context else { return }
        context.write(data).whenFailure { [weak self] _ in
            self?.context?.close(promise: nil)
        }
    }

    private func partnerFlush() {
        context?.flush()
    }

    private func partnerWriteEOF() {
        context?.close(mode: .output, promise: nil)
    }

    private func partnerCloseFull(context partnerContext: ChannelHandlerContext) {
        guard let ownContext = self.context else { return }
        ownContext.close(promise: nil)
        // Ensure partner side is also closed
        if partnerContext.channel.isActive {
            partnerContext.close(promise: nil)
        }
    }

    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }

    private func partnerBecameUnwritable() {
        // No action needed — read() will check writability
    }
}
