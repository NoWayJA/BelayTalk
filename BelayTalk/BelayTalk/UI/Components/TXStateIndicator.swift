import SwiftUI

/// Large TX state display — the central, most glanceable element on the session screen.
struct TXStateIndicator: View {
    let txState: TXState

    var body: some View {
        VStack(spacing: 12) {
            Circle()
                .fill(color.gradient)
                .frame(width: 140, height: 140)
                .overlay(
                    Image(systemName: iconName)
                        .font(.system(size: 48, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .shadow(color: color.opacity(0.4), radius: 20, y: 4)

            Text(label)
                .font(.title2.weight(.semibold))
                .foregroundStyle(color)
        }
    }

    private var label: String {
        switch txState {
        case .disabled: "TX OFF"
        case .armed: "LISTENING"
        case .live: "LIVE"
        case .holdOpen: "OPEN MIC"
        case .muted: "MUTED"
        }
    }

    private var iconName: String {
        switch txState {
        case .disabled: "mic.slash"
        case .armed: "ear"
        case .live: "mic.fill"
        case .holdOpen: "mic.fill"
        case .muted: "mic.slash.fill"
        }
    }

    private var color: Color {
        switch txState {
        case .disabled: .gray
        case .armed: .blue
        case .live: .green
        case .holdOpen: .green
        case .muted: .orange
        }
    }
}
