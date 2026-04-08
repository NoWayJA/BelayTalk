//
//  BelayTalkApp.swift
//  BelayTalk
//
//  Created by Jonathan Anthony on 06/04/2026.
//

import SwiftUI

@main
struct BelayTalkApp: App {
    @State private var coordinator = SessionCoordinator()

    var body: some Scene {
        WindowGroup {
            Group {
                switch coordinator.sessionState {
                case .idle, .permissions, .ready:
                    HomeView()
                case .connecting:
                    if coordinator.role == .guest {
                        NavigationStack {
                            PeerBrowserView()
                        }
                    } else {
                        waitingView
                    }
                case .active, .reconnecting, .interrupted, .routeFailed, .ending:
                    SessionView()
                case .ended:
                    HomeView()
                }
            }
            .environment(coordinator)
            .animation(.default, value: coordinator.sessionState)
        }
    }

    private var waitingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Waiting for connection…")
                .font(.headline)
            Text("Another device can join your session")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Cancel") {
                coordinator.endSession()
            }
            .padding(.top)
        }
    }
}
