import SwiftUI

/// Audio route indicator with icon.
struct RouteIndicatorBadge: View {
    let route: RouteState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.caption)
            Text(label)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.1), in: Capsule())
    }

    private var iconName: String {
        switch route {
        case .bluetooth: "headphones"
        case .wired: "cable.connector"
        case .builtIn: "speaker.wave.2"
        case .changing: "arrow.triangle.2.circlepath"
        case .unavailable: "speaker.slash"
        }
    }

    private var label: String {
        switch route {
        case .bluetooth: "Bluetooth"
        case .wired: "Wired"
        case .builtIn: "Speaker"
        case .changing: "Changing…"
        case .unavailable: "No Audio"
        }
    }

    private var color: Color {
        switch route {
        case .bluetooth, .wired: .green
        case .builtIn: .orange
        case .changing: .yellow
        case .unavailable: .red
        }
    }
}
