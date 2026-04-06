import Foundation
import UIKit

// MARK: - Device Info

struct DeviceInfo: Codable, Sendable {
    let model: String
    let systemVersion: String
    let appVersion: String

    @MainActor static var current: DeviceInfo {
        DeviceInfo(
            model: UIDevice.current.model,
            systemVersion: UIDevice.current.systemVersion,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        )
    }
}

// MARK: - Diagnostic Report

struct DiagnosticReport: Codable, Sendable {
    let timestamp: Date
    let device: DeviceInfo
    let rttMs: Double
    let packetsSent: UInt64
    let packetsReceived: UInt64
    let packetsLost: UInt64
    let packetLossPercent: Double
    let reconnectCount: Int
    let sessionDurationSeconds: TimeInterval
}

// MARK: - Exporter

enum DiagnosticsExporter {

    static func generateReport(from metrics: SessionMetrics) -> DiagnosticReport {
        DiagnosticReport(
            timestamp: Date(),
            device: .current,
            rttMs: metrics.rttMs,
            packetsSent: metrics.packetsSent,
            packetsReceived: metrics.packetsReceived,
            packetsLost: metrics.packetsLost,
            packetLossPercent: metrics.packetLossPercent,
            reconnectCount: metrics.reconnectCount,
            sessionDurationSeconds: metrics.sessionDuration
        )
    }

    static func exportJSON(from metrics: SessionMetrics) throws -> Data {
        let report = generateReport(from: metrics)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }

    static func exportReadable(from metrics: SessionMetrics) -> String {
        let report = generateReport(from: metrics)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium

        let duration = Int(report.sessionDurationSeconds)
        let minutes = duration / 60
        let seconds = duration % 60

        return """
        BelayTalk Diagnostic Report
        ===========================
        Date: \(formatter.string(from: report.timestamp))
        Device: \(report.device.model) (\(report.device.systemVersion))
        App Version: \(report.device.appVersion)

        Session Duration: \(minutes)m \(seconds)s
        RTT: \(String(format: "%.1f", report.rttMs))ms
        Packets Sent: \(report.packetsSent)
        Packets Received: \(report.packetsReceived)
        Packets Lost: \(report.packetsLost) (\(String(format: "%.1f", report.packetLossPercent))%)
        Reconnect Count: \(report.reconnectCount)
        """
    }
}
