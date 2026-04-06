import SwiftUI
import MultipeerConnectivity

/// Accept/reject incoming connection invitation.
struct InvitationView: View {
    let peerName: String
    let onAccept: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text("Connection Request")
                .font(.title2.weight(.semibold))

            Text("\(peerName) wants to connect")
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Button("Reject", role: .destructive) {
                    onReject()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("Accept") {
                    onAccept()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(32)
    }
}
