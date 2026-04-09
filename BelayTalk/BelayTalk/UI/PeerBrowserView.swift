import SwiftUI
import MultipeerConnectivity

/// Peer discovery list when joining a session.
struct PeerBrowserView: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @State private var peers: [MCPeerID] = []

    var body: some View {
        Group {
            if peers.isEmpty {
                ContentUnavailableView(
                    "Searching for Sessions",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text(coordinator.connectionStatusMessage.isEmpty
                        ? "Make sure the other device is hosting a session nearby."
                        : coordinator.connectionStatusMessage)
                )
            } else {
                List(peers, id: \.displayName) { peer in
                    Button {
                        coordinator.invitePeer(peer)
                    } label: {
                        HStack {
                            Image(systemName: "iphone")
                                .foregroundStyle(.tint)
                            Text(peer.displayName)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Available Sessions")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    coordinator.cancelConnecting()
                }
            }
        }
        .task {
            for await discovered in coordinator.transport.discoveredPeers {
                peers = discovered
            }
        }
    }
}
