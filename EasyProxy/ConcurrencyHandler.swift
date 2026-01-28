import NIOCore
import NIOConcurrencyHelpers
import NIOHTTP1
import Logging

/// Limits concurrent proxy connections. Returns 503 when the limit is exceeded.
final class ConcurrencyHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias InboundOut = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private static let activeCount = NIOLockedValueBox<Int>(0)

    private let stats: ProxyStats
    private var logger = Logger(label: "proxy.concurrency")
    private var counted = false

    init(stats: ProxyStats) {
        self.stats = stats
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let count = Self.activeCount.withLockedValue { c -> Int in
            c += 1
            return c
        }
        counted = true

        if count > ProxyConfig.maxConcurrentConnections {
            logger.warning("Connection limit exceeded: \(count)/\(ProxyConfig.maxConcurrentConnections)")
            Task { @MainActor in
                self.stats.recordRejected()
            }
            send503AndClose(context: context)
            return
        }

        Task { @MainActor in
            self.stats.recordAccepted()
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        if counted {
            counted = false
            Self.activeCount.withLockedValue { $0 -= 1 }
            Task { @MainActor in
                self.stats.recordDisconnected()
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.fireChannelRead(data)
    }

    private func send503AndClose(context: ChannelHandlerContext) {
        // Decrement since we're rejecting immediately
        if counted {
            counted = false
            Self.activeCount.withLockedValue { $0 -= 1 }
        }

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Connection", value: "close")
        let body = ByteBuffer(string: "503 Service Unavailable – connection limit reached")
        headers.add(name: "Content-Length", value: "\(body.readableBytes)")

        let head = HTTPResponseHead(version: .http1_1, status: .serviceUnavailable, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}
