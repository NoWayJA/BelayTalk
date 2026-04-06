import SwiftUI

/// Active session screen showing TX state, peer info, and session controls.
struct SessionView: View {
    @Environment(SessionCoordinator.self) private var coordinator

    var body: some View {
        VStack(spacing: 24) {
            // Header: peer name + connection status
            VStack(spacing: 8) {
                if let peerName = coordinator.connectedPeerName {
                    Text(peerName)
                        .font(.headline)
                }
                HStack(spacing: 12) {
                    ConnectionStatusBadge(state: coordinator.sessionState)
                    RouteIndicatorBadge(route: coordinator.routeState)
                }
            }

            Spacer()

            // Central TX state indicator
            TXStateIndicator(txState: coordinator.txState)

            Spacer()

            // Mode picker
            @Bindable var coord = coordinator
            Picker("TX Mode", selection: Binding(
                get: { coordinator.settings.txMode },
                set: { coordinator.updateTXMode($0) }
            )) {
                ForEach(TXMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            // TX button (primarily for manual mode, but useful for mute in other modes)
            TXButton(txState: coordinator.txState) {
                coordinator.toggleTX()
            }

            // End session
            Button(role: .destructive) {
                coordinator.endSession()
            } label: {
                Label("End Session", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
    }
}
