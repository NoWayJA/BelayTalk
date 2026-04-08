import SwiftUI

/// Landing screen with Host/Join buttons, Settings and Diagnostics navigation.
struct HomeView: View {
    @Environment(SessionCoordinator.self) private var coordinator

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                // App title
                VStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)
                    Text("BelayTalk")
                        .font(.largeTitle.weight(.bold))
                    Text("Hands-free climbing intercom")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Session buttons
                VStack(spacing: 16) {
                    Button {
                        coordinator.hostSession()
                    } label: {
                        Label("Host Session", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(coordinator.sessionState != .ready)

                    Button {
                        coordinator.joinSession()
                    } label: {
                        Label("Join Session", systemImage: "person.wave.2")
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(coordinator.sessionState != .ready)
                }

                Spacer()

                // Navigation links
                HStack(spacing: 24) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }

                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Diagnostics", systemImage: "waveform.path.ecg")
                    }
                }
                .font(.callout)
            }
            .padding(.horizontal, 24)
            .navigationTitle("")
            .task {
                switch coordinator.sessionState {
                case .idle:
                    _ = await coordinator.requestPermissions()
                case .ended:
                    coordinator.prepareForNewSession()
                default:
                    break
                }
            }
        }
    }
}
