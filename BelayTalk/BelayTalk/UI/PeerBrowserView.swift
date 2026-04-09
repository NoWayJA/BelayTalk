import SwiftUI
import MultipeerConnectivity

/// Peer discovery list when joining a session.
struct PeerBrowserView: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @State private var peers: [MCPeerID] = []
    @State private var hasInvited = false

    var body: some View {
        Group {
            if hasInvited {
                // Connection in progress — show progress overlay
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text(coordinator.connectionStatusMessage.isEmpty
                         ? "Connecting…"
                         : coordinator.connectionStatusMessage)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text("This may take a few seconds")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Cancel") {
                        coordinator.cancelConnecting()
                    }
                    .padding(.top)
                }
            } else if peers.isEmpty {
                ContentUnavailableView {
                    Label("Searching for Sessions", systemImage: "antenna.radiowaves.left.and.right")
                } description: {
                    Text(coordinator.connectionStatusMessage.isEmpty
                        ? "Make sure the other device is hosting a session nearby."
                        : coordinator.connectionStatusMessage)
                } actions: {
                    Button("Retry Search") {
                        coordinator.restartBrowsing()
                    }
                }
            } else {
                List(peers, id: \.displayName) { peer in
                    Button {
                        coordinator.invitePeer(peer)
                        hasInvited = true
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
            // Subscribe to real-time peer discovery updates
            for await discovered in coordinator.transport.discoveredPeers {
                peers = discovered
            }
        }
        .task {
            // Fallback: periodically restart browsing if no peers found.
            // After a failed connection, MC's Bonjour layer may cache stale
            // discovery state and not fire foundPeer for known hosts.
            // Also handles AsyncStream single-consumer edge cases where
            // a recreated view's iterator may miss yields.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, !hasInvited,
                      coordinator.sessionState == .connecting else { continue }
                // Sync from current state in case AsyncStream missed updates
                let current = coordinator.transport.currentDiscoveredPeers
                if !current.isEmpty && peers.isEmpty {
                    peers = current
                }
                // If still empty, restart browsing to force fresh Bonjour discovery
                if peers.isEmpty {
                    coordinator.restartBrowsing()
                }
            }
        }
    }
}
