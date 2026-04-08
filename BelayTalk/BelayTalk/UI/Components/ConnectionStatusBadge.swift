import SwiftUI

/// Small connection state badge shown in the session header.
struct ConnectionStatusBadge: View {
    let state: SessionState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var label: String {
        switch state {
        case .idle: "Idle"
        case .permissions: "Permissions"
        case .ready: "Ready"
        case .connecting: "Connecting…"
        case .active: "Connected"
        case .reconnecting: "Reconnecting…"
        case .interrupted: "Interrupted"
        case .routeFailed: "Route Failed"
        case .ending: "Ending…"
        case .ended: "Ended"
        }
    }

    private var color: Color {
        switch state {
        case .active: .green
        case .connecting, .reconnecting, .interrupted: .orange
        case .ended, .routeFailed: .red
        default: .gray
        }
    }
}
