@preconcurrency import MultipeerConnectivity
import OSLog
import os

// MARK: - Delegate Protocol

nonisolated protocol PeerTransportDelegate: AnyObject, Sendable {
    func transport(_ transport: PeerTransport, didReceiveAudio header: AudioFrameHeader, payload: Data)
    func transport(_ transport: PeerTransport, didReceiveControl frame: ControlFrame)
    func transport(_ transport: PeerTransport, peerDidConnect peerID: MCPeerID)
    func transport(_ transport: PeerTransport, peerDidDisconnect peerID: MCPeerID)
}

// MARK: - Peer Transport

/// MultipeerConnectivity wrapper enforcing single-peer sessions.
///
/// - Service type: `"belaytalk"`
/// - Encryption: `.required`
/// - Audio sent `.unreliable`, control sent `.reliable`
/// - Rejects third connections
nonisolated final class PeerTransport: NSObject, @unchecked Sendable {
    private static let serviceType = "belaytalk"

    let localPeerID: MCPeerID
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())
    private struct State {
        var connectedPeer: MCPeerID?
        var isHosting = false
        var isBrowsing = false
    }

    weak var delegate: PeerTransportDelegate?

    /// Discovered peers stream for the browser UI
    private let discoveredPeersContinuation: AsyncStream<[MCPeerID]>.Continuation
    let discoveredPeers: AsyncStream<[MCPeerID]>
    private var _discoveredPeers: [MCPeerID] = []

    /// Invitation handler for incoming connections
    private let invitationContinuation: AsyncStream<(MCPeerID, @Sendable (Bool) -> Void)>.Continuation
    let incomingInvitations: AsyncStream<(MCPeerID, @Sendable (Bool) -> Void)>

    @MainActor override init() {
        let displayName = UIDevice.current.name
        localPeerID = MCPeerID(displayName: displayName)

        var dpC: AsyncStream<[MCPeerID]>.Continuation!
        discoveredPeers = AsyncStream { dpC = $0 }
        discoveredPeersContinuation = dpC

        var invC: AsyncStream<(MCPeerID, @Sendable (Bool) -> Void)>.Continuation!
        incomingInvitations = AsyncStream { invC = $0 }
        invitationContinuation = invC

        super.init()

        session = MCSession(
            peer: localPeerID,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        session.delegate = self
    }

    deinit {
        stopAdvertising()
        stopBrowsing()
        session.disconnect()
        discoveredPeersContinuation.finish()
        invitationContinuation.finish()
    }

    // MARK: - Host (Advertise)

    @MainActor func startAdvertising() {
        let adv = MCNearbyServiceAdvertiser(
            peer: localPeerID,
            discoveryInfo: nil,
            serviceType: Self.serviceType
        )
        adv.delegate = self
        adv.startAdvertisingPeer()
        advertiser = adv
        lock.withLock { $0.isHosting = true }
        Log.transport.info("Started advertising")
    }

    func stopAdvertising() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        lock.withLock { $0.isHosting = false }
    }

    // MARK: - Join (Browse)

    @MainActor func startBrowsing() {
        let br = MCNearbyServiceBrowser(
            peer: localPeerID,
            serviceType: Self.serviceType
        )
        br.delegate = self
        br.startBrowsingForPeers()
        browser = br
        lock.withLock { $0.isBrowsing = true }
        Log.transport.info("Started browsing")
    }

    func stopBrowsing() {
        browser?.stopBrowsingForPeers()
        browser = nil
        _discoveredPeers.removeAll()
        lock.withLock { $0.isBrowsing = false }
    }

    /// Invite a discovered peer to join
    func invite(peer: MCPeerID) {
        browser?.invitePeer(peer, to: session, withContext: nil, timeout: 30)
        Log.transport.info("Invited peer: \(peer.displayName)")
    }

    // MARK: - Send

    func sendAudio(header: AudioFrameHeader, payload: Data) {
        guard let peer = lock.withLock({ $0.connectedPeer }) else { return }
        let data = FrameSerializer.encodeAudioFrame(header: header, payload: payload)
        try? session.send(data, toPeers: [peer], with: .unreliable)
    }

    func sendControl(_ frame: ControlFrame) {
        guard let peer = lock.withLock({ $0.connectedPeer }) else { return }
        guard let data = FrameSerializer.encodeControlFrame(frame) else { return }
        do {
            try session.send(data, toPeers: [peer], with: .reliable)
        } catch {
            Log.transport.error("Failed to send control: \(error.localizedDescription)")
        }
    }

    // MARK: - Disconnect

    func disconnect() {
        session.disconnect()
        lock.withLock { $0.connectedPeer = nil }
        Log.transport.info("Disconnected")
    }

    var connectedPeerName: String? {
        lock.withLock { $0.connectedPeer?.displayName }
    }

    var isConnected: Bool {
        lock.withLock { $0.connectedPeer != nil }
    }
}

// MARK: - MCSessionDelegate

extension PeerTransport: MCSessionDelegate {
    nonisolated func session(
        _ session: MCSession,
        peer peerID: MCPeerID,
        didChange state: MCSessionState
    ) {
        switch state {
        case .connected:
            lock.withLock { $0.connectedPeer = peerID }
            Log.transport.info("Peer connected: \(peerID.displayName)")
            delegate?.transport(self, peerDidConnect: peerID)

        case .notConnected:
            let wasConnected = lock.withLock { state in
                let was = state.connectedPeer == peerID
                if was { state.connectedPeer = nil }
                return was
            }
            if wasConnected {
                Log.transport.warning("Peer disconnected: \(peerID.displayName)")
                delegate?.transport(self, peerDidDisconnect: peerID)
            }

        case .connecting:
            Log.transport.debug("Peer connecting: \(peerID.displayName)")

        @unknown default:
            break
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let type = FrameSerializer.frameType(of: data) else { return }

        switch type {
        case .audio:
            if let (header, payload) = FrameSerializer.decodeAudioFrame(data) {
                delegate?.transport(self, didReceiveAudio: header, payload: payload)
            }
        case .control:
            if let frame = FrameSerializer.decodeControlFrame(data) {
                delegate?.transport(self, didReceiveControl: frame)
            }
        }
    }

    // Unused but required delegate methods
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName: String, fromPeer: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName: String, fromPeer: MCPeerID, with: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName: String, fromPeer: MCPeerID, at: URL?, withError: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension PeerTransport: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        // Reject if already connected (single peer enforced)
        if lock.withLock({ $0.connectedPeer }) != nil {
            Log.transport.warning("Rejected invitation from \(peerID.displayName) — already connected")
            invitationHandler(false, nil)
            return
        }

        let session = self.session!
        let handler: @Sendable (Bool) -> Void = { accept in
            invitationHandler(accept, accept ? session : nil)
        }
        invitationContinuation.yield((peerID, handler))
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension PeerTransport: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        _discoveredPeers.append(peerID)
        discoveredPeersContinuation.yield(_discoveredPeers)
        Log.transport.info("Found peer: \(peerID.displayName)")
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        _discoveredPeers.removeAll { $0 == peerID }
        discoveredPeersContinuation.yield(_discoveredPeers)
        Log.transport.info("Lost peer: \(peerID.displayName)")
    }
}
