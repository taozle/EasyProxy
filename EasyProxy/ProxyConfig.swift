import Foundation

enum ProxyConfig {
    static let port: Int = 8080
    static let maxConcurrentConnections: Int = 1024
    static let connectTimeoutSeconds: Int64 = 8
    static let idleTimeoutSeconds: Int64 = 120
    static let maxRecentErrors: Int = 50

    // SOCKS5 / UDP relay
    static let udpRelayTimeoutSeconds: Int64 = 120
    static let maxUDPOutboundChannels: Int = 256
}
