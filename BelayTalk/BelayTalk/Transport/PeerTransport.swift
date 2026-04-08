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
/// - Encryption: `.optional` (DTLS when possible, graceful fallback)
/// - Audio sent `.unreliable`, control sent `.reliable`
/// - Rejects third connections
nonisolated final class PeerTransport: NSObject, @unchecked Sendable {
    private static let serviceType = "belaytalk"

    let localPeerID: MCPeerID

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())
    private struct State {
        var session: MCSession?
        var advertiser: MCNearbyServiceAdvertiser?
        var browser: MCNearbyServiceBrowser?
        var connectedPeer: MCPeerID?
        var discoveredPeers: [MCPeerID] = []
        var isHosting = false
        var isBrowsing = false
        var autoInviteOnDiscover = false
    }

    weak var delegate: PeerTransportDelegate?

    /// Discovered peers stream for the browser UI
    private let discoveredPeersContinuation: AsyncStream<[MCPeerID]>.Continuation
    let discoveredPeers: AsyncStream<[MCPeerID]>

    /// Notifies when a peer's invitation was auto-accepted (for UI feedback)
    private let autoAcceptedPeerContinuation: AsyncStream<MCPeerID>.Continuation
    let autoAcceptedPeers: AsyncStream<MCPeerID>

    @MainActor override init() {
        let displayName = UIDevice.current.name
        localPeerID = MCPeerID(displayName: displayName)

        var dpC: AsyncStream<[MCPeerID]>.Continuation!
        discoveredPeers = AsyncStream { dpC = $0 }
        discoveredPeersContinuation = dpC

        var aaC: AsyncStream<MCPeerID>.Continuation!
        autoAcceptedPeers = AsyncStream { aaC = $0 }
        autoAcceptedPeerContinuation = aaC

        super.init()

        let newSession = MCSession(
            peer: localPeerID,
            securityIdentity: nil,
            encryptionPreference: .optional
        )
        newSession.delegate = self
        lock.withLock { $0.session = newSession }
    }

    deinit {
        lock.withLock { state in
            state.advertiser?.stopAdvertisingPeer()
            state.browser?.stopBrowsingForPeers()
            state.session?.disconnect()
        }
        discoveredPeersContinuation.finish()
        autoAcceptedPeerContinuation.finish()
    }

    // MARK: - Host (Advertise)

    @MainActor func startAdvertising() {
        // Stop any existing advertiser first
        lock.withLock { state in
            state.advertiser?.stopAdvertisingPeer()
        }

        let adv = MCNearbyServiceAdvertiser(
            peer: localPeerID,
            discoveryInfo: nil,
            serviceType: Self.serviceType
        )
        adv.delegate = self
        adv.startAdvertisingPeer()
        lock.withLock { state in
            state.advertiser = adv
            state.isHosting = true
        }
        Log.transport.info("Started advertising")
    }

    func stopAdvertising() {
        lock.withLock { state in
            state.advertiser?.stopAdvertisingPeer()
            state.advertiser = nil
            state.isHosting = false
        }
    }

    // MARK: - Join (Browse)

    @MainActor func startBrowsing() {
        // Stop any existing browser and clear stale discovered peers.
        // Stale MCPeerID objects carry internal DTLS state from previous
        // sessions — inviting them to a new MCSession causes "Not in
        // connected state" failures.
        lock.withLock { state in
            state.browser?.stopBrowsingForPeers()
            state.discoveredPeers.removeAll()
        }
        discoveredPeersContinuation.yield([])

        let br = MCNearbyServiceBrowser(
            peer: localPeerID,
            serviceType: Self.serviceType
        )
        br.delegate = self
        br.startBrowsingForPeers()
        lock.withLock { state in
            state.browser = br
            state.isBrowsing = true
        }
        Log.transport.info("Started browsing")
    }

    func stopBrowsing() {
        lock.withLock { state in
            state.browser?.stopBrowsingForPeers()
            state.browser = nil
            state.discoveredPeers.removeAll()
            state.isBrowsing = false
        }
        discoveredPeersContinuation.yield([])
    }

    /// Invite a discovered peer to join
    func invite(peer: MCPeerID) {
        lock.withLock { state in
            guard let browser = state.browser, let session = state.session else { return }
            browser.invitePeer(peer, to: session, withContext: nil, timeout: 30)
        }
        Log.transport.info("Invited peer: \(peer.displayName)")
    }

    /// When set, the next discovered peer will be auto-invited (used during reconnection).
    func setAutoInviteOnDiscover(_ enabled: Bool) {
        lock.withLock { $0.autoInviteOnDiscover = enabled }
    }

    // MARK: - Send

    func sendAudio(header: AudioFrameHeader, payload: Data) {
        let (peer, session) = lock.withLock { ($0.connectedPeer, $0.session) }
        guard let peer, let session else { return }
        let data = FrameSerializer.encodeAudioFrame(header: header, payload: payload)
        try? session.send(data, toPeers: [peer], with: .unreliable)
    }

    func sendControl(_ frame: ControlFrame) {
        let (peer, session) = lock.withLock { ($0.connectedPeer, $0.session) }
        guard let peer, let session else { return }
        guard let data = FrameSerializer.encodeControlFrame(frame) else { return }
        do {
            try session.send(data, toPeers: [peer], with: .reliable)
        } catch {
            Log.transport.error("Failed to send control: \(error.localizedDescription)")
        }
    }

    // MARK: - Disconnect

    func disconnect() {
        lock.withLock { state in
            state.session?.disconnect()
            state.connectedPeer = nil
        }
        Log.transport.info("Disconnected")
    }

    /// Recreate the internal MCSession for clean reconnection.
    /// A disconnected MCSession may be in a terminal state and unable to accept new connections.
    @MainActor func recreateSession() {
        lock.withLock { state in
            state.session?.disconnect()
            let newSession = MCSession(
                peer: localPeerID,
                securityIdentity: nil,
                encryptionPreference: .optional
            )
            newSession.delegate = self
            state.session = newSession
            state.connectedPeer = nil
        }
        Log.transport.info("MCSession recreated")
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
            } else {
                Log.transport.warning("Peer connection attempt failed: \(peerID.displayName)")
                // Also notify delegate — a failed connection attempt during .connecting
                // needs to be handled by the coordinator
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
        let (alreadyConnected, session) = lock.withLock { ($0.connectedPeer != nil, $0.session) }

        // Reject if already connected (single peer enforced)
        if alreadyConnected {
            Log.transport.warning("Rejected invitation from \(peerID.displayName) — already connected")
            invitationHandler(false, nil)
            return
        }

        // Auto-accept immediately — the host chose to host a 2-person intercom,
        // so any peer running BelayTalk should be accepted without delay.
        // Routing through async UI caused MC channel negotiation timeouts.
        Log.transport.info("Auto-accepting invitation from \(peerID.displayName)")
        invitationHandler(true, session)
        autoAcceptedPeerContinuation.yield(peerID)
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Log.transport.error("Failed to start advertising: \(error.localizedDescription)")
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension PeerTransport: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        let peers = lock.withLock { state -> [MCPeerID] in
            state.discoveredPeers.append(peerID)
            return state.discoveredPeers
        }
        discoveredPeersContinuation.yield(peers)
        Log.transport.info("Found peer: \(peerID.displayName)")

        let shouldAutoInvite = lock.withLock { state in
            if state.autoInviteOnDiscover {
                state.autoInviteOnDiscover = false
                return true
            }
            return false
        }
        if shouldAutoInvite {
            invite(peer: peerID)
            Log.transport.info("Auto-invited peer for reconnection: \(peerID.displayName)")
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let peers = lock.withLock { state -> [MCPeerID] in
            state.discoveredPeers.removeAll { $0 == peerID }
            return state.discoveredPeers
        }
        discoveredPeersContinuation.yield(peers)
        Log.transport.info("Lost peer: \(peerID.displayName)")
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Log.transport.error("Failed to start browsing: \(error.localizedDescription)")
    }
}
