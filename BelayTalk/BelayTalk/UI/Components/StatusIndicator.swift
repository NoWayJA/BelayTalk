import SwiftUI

/// Large colored circle indicating overall session health.
/// Green = OK, Amber = degraded/connecting, Red = failure/ended, Gray = idle
struct StatusIndicator: View {
    let state: SessionState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 24, height: 24)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.3), lineWidth: 4)
            )
    }

    private var color: Color {
        switch state {
        case .active:
            .green
        case .connecting, .reconnecting, .interrupted:
            .orange
        case .ended, .ending, .routeFailed:
            .red
        case .idle, .permissions, .ready:
            .gray
        }
    }
}
