import SwiftUI

/// Large manual TX toggle button — easy to tap with gloves.
struct TXButton: View {
    let txState: TXState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: iconName)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .controlSize(.large)
    }

    private var label: String {
        switch txState {
        case .live, .holdOpen: "Stop Transmitting"
        case .muted: "Unmute"
        default: "Start Transmitting"
        }
    }

    private var iconName: String {
        switch txState {
        case .live, .holdOpen: "mic.slash"
        case .muted: "mic"
        default: "mic.fill"
        }
    }

    private var tint: Color {
        switch txState {
        case .live, .holdOpen: .red
        case .muted: .orange
        default: .green
        }
    }
}
