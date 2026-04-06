import Foundation

/// Observable session metrics for UI display and diagnostics export.
///
/// All properties are MainActor-isolated (project default). Background threads
/// update metrics by dispatching to MainActor — acceptable latency for metrics.
@Observable
final class SessionMetrics {
    private(set) var rttMs: Double = 0
    private(set) var packetsSent: UInt64 = 0
    private(set) var packetsReceived: UInt64 = 0
    private(set) var packetsLost: UInt64 = 0
    private(set) var reconnectCount: Int = 0
    private(set) var sessionStartDate: Date?

    var sessionDuration: TimeInterval {
        guard let start = sessionStartDate else { return 0 }
        return Date().timeIntervalSince(start)
    }

    var packetLossPercent: Double {
        let total = packetsSent
        guard total > 0 else { return 0 }
        return Double(packetsLost) / Double(total) * 100
    }

    // MARK: - Mutators

    func updateRTT(_ ms: Double) { rttMs = ms }
    func incrementPacketsSent() { packetsSent += 1 }
    func incrementPacketsReceived() { packetsReceived += 1 }
    func incrementPacketsLost() { packetsLost += 1 }
    func incrementReconnectCount() { reconnectCount += 1 }
    func markSessionStart() { sessionStartDate = Date() }

    func reset() {
        rttMs = 0
        packetsSent = 0
        packetsReceived = 0
        packetsLost = 0
        reconnectCount = 0
        sessionStartDate = nil
    }
}
