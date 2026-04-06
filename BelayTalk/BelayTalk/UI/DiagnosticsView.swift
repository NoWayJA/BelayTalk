import SwiftUI

/// Metrics display with export functionality.
struct DiagnosticsView: View {
    @Environment(SessionCoordinator.self) private var coordinator

    var body: some View {
        let metrics = coordinator.metrics

        List {
            Section("Session") {
                MetricRow(label: "Duration", value: formatDuration(metrics.sessionDuration))
                MetricRow(label: "RTT", value: String(format: "%.1f ms", metrics.rttMs))
            }

            Section("Packets") {
                MetricRow(label: "Sent", value: "\(metrics.packetsSent)")
                MetricRow(label: "Received", value: "\(metrics.packetsReceived)")
                MetricRow(label: "Lost", value: "\(metrics.packetsLost)")
                MetricRow(
                    label: "Loss Rate",
                    value: String(format: "%.1f%%", metrics.packetLossPercent)
                )
            }

            Section("Recovery") {
                MetricRow(label: "Reconnects", value: "\(metrics.reconnectCount)")
            }

            Section {
                ShareLink(item: exportText()) {
                    Label("Export Report", systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle("Diagnostics")
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let minutes = total / 60
        let seconds = total % 60
        return "\(minutes)m \(seconds)s"
    }

    private func exportText() -> String {
        DiagnosticsExporter.exportReadable(from: coordinator.metrics)
    }
}
