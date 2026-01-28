import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ContentView: View {
    @StateObject private var stats = ProxyStats()
    @State private var server: ProxyServer?
    @State private var keepScreenAwake = true

    var body: some View {
        NavigationStack {
            List {
                serverSection
                statisticsSection
                errorsSection
                tipsSection
            }
            .navigationTitle("EasyProxy")
        }
    }

    // MARK: - Server Section

    private var serverSection: some View {
        Section("Server") {
            Toggle("Proxy Server", isOn: Binding(
                get: { stats.isRunning },
                set: { newValue in
                    if newValue {
                        startServer()
                    } else {
                        stopServer()
                    }
                }
            ))

            Toggle("Keep Screen Awake", isOn: $keepScreenAwake)
                .onChange(of: keepScreenAwake) { newValue in
                    setIdleTimerDisabled(newValue && stats.isRunning)
                }

            if stats.isRunning {
                LabeledContent("WiFi IP", value: stats.localIPAddress)
                LabeledContent("Port", value: "\(stats.listeningPort)")

                if stats.localIPAddress != "–" {
                    Text("Proxy: \(stats.localIPAddress):\(stats.listeningPort)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Statistics Section

    private var statisticsSection: some View {
        Section("Statistics") {
            LabeledContent("Active Connections", value: "\(stats.activeConnections)")
            LabeledContent("Total Accepted", value: "\(stats.totalAccepted)")
            LabeledContent("Total Rejected (503)", value: "\(stats.totalRejected)")
            LabeledContent("Total Failed", value: "\(stats.totalFailed)")
            LabeledContent("SOCKS5 Connections", value: "\(stats.socks5Connections)")
            LabeledContent("UDP Packets Relayed", value: "\(stats.udpPacketsRelayed)")
            LabeledContent("Active UDP Sessions", value: "\(stats.activeUDPSessions)")
        }
    }

    // MARK: - Errors Section

    private var errorsSection: some View {
        Section("Recent Errors") {
            if stats.recentErrors.isEmpty {
                Text("No errors")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(stats.recentErrors) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.description)
                            .font(.caption)
                            .foregroundStyle(.red)
                        Text(entry.timestamp, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Tips Section

    private var tipsSection: some View {
        Section("Tips") {
            Text("Keep the app in foreground or split-screen for best performance. Plug in the charger for long sessions.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func startServer() {
        stats.localIPAddress = NetworkUtils.getWiFiIPAddress() ?? "–"
        stats.listeningPort = ProxyConfig.port

        let proxy = ProxyServer()
        server = proxy
        stats.isRunning = true
        if keepScreenAwake {
            setIdleTimerDisabled(true)
        }

        Task {
            do {
                try await proxy.start(stats: stats)
            } catch {
                await MainActor.run {
                    stats.recordFailed(description: "Start failed: \(error)")
                    stats.isRunning = false
                    setIdleTimerDisabled(false)
                }
            }
        }
    }

    private func stopServer() {
        server?.stop()
        server = nil
        stats.isRunning = false
        setIdleTimerDisabled(false)
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }
}
