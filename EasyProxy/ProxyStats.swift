import Foundation
import SwiftUI

struct ErrorEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let description: String
}

@MainActor
final class ProxyStats: ObservableObject {
    @Published var isRunning = false
    @Published var localIPAddress: String = "–"
    @Published var listeningPort: Int = ProxyConfig.port

    @Published var activeConnections: Int = 0
    @Published var totalAccepted: Int = 0
    @Published var totalRejected: Int = 0
    @Published var totalFailed: Int = 0

    // SOCKS5 / UDP statistics
    @Published var socks5Connections: Int = 0
    @Published var udpPacketsRelayed: Int = 0
    @Published var activeUDPSessions: Int = 0

    @Published var recentErrors: [ErrorEntry] = []

    func recordAccepted() {
        totalAccepted += 1
        activeConnections += 1
    }

    func recordDisconnected() {
        activeConnections = max(activeConnections - 1, 0)
    }

    func recordRejected() {
        totalRejected += 1
    }

    func recordFailed(description: String) {
        totalFailed += 1
        let entry = ErrorEntry(timestamp: Date(), description: description)
        recentErrors.insert(entry, at: 0)
        if recentErrors.count > ProxyConfig.maxRecentErrors {
            recentErrors.removeLast()
        }
    }

    func recordSOCKS5Connection() {
        socks5Connections += 1
    }

    func recordUDPPacket() {
        udpPacketsRelayed += 1
    }

    func recordUDPSessionStarted() {
        activeUDPSessions += 1
    }

    func recordUDPSessionEnded() {
        activeUDPSessions = max(activeUDPSessions - 1, 0)
    }
}
