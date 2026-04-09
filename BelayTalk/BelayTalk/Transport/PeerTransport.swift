@preconcurrency import MultipeerConnectivity
import OSLog
import os

// MARK: - Delegate Protocol

nonisolated protocol PeerTransportDelegate: AnyObject, Sendable {
    func transport(_ transport: PeerTransport, didReceiveAudio header: AudioFrameHeader, payload: Data)
    func transport(_ transport: PeerTransport, didReceiveControl frame: ControlFrame)
    func transport(_ transport: PeerTransport, peerDidConnect peerID: MCPeerID)
    func transport(_ transport: PeerTransport, peerDidDisconnect peerID: MCPeerID)
    func transport(_ transport: PeerTransport, didFailToStartWithError error: Error)
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

    private(set) var localPeerID: MCPeerID

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

    @MainActor init(displayName: String) {
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
        // Extract MC objects and nil delegates before stopping.
        // This prevents re-entrant lock attempts from synchronous callbacks.
        let (adv, br, sess) = lock.withLock { state -> (MCNearbyServiceAdvertiser?, MCNearbyServiceBrowser?, MCSession?) in
            let a = state.advertiser
            let b = state.browser
            let s = state.session
            state.advertiser = nil
            state.browser = nil
            state.session = nil
            return (a, b, s)
        }
        adv?.delegate = nil
        adv?.stopAdvertisingPeer()
        br?.delegate = nil
        br?.stopBrowsingForPeers()
        sess?.delegate = nil
        sess?.disconnect()
        discoveredPeersContinuation.finish()
        autoAcceptedPeerContinuation.finish()
    }

    /// Update the local peer's display name. Only safe when not connected.
    @MainActor func updateDisplayName(_ name: String) {
        localPeerID = MCPeerID(displayName: name)
        recreateSession()
        Log.transport.info("Display name updated to \(name)")
    }

    // MARK: - Host (Advertise)

    @MainActor func startAdvertising() {
        // Extract old advertiser from lock, nil delegate, stop OUTSIDE lock
        // to prevent re-entrant lock from synchronous MC callbacks.
        let oldAdv = lock.withLock { state -> MCNearbyServiceAdvertiser? in
            let old = state.advertiser
            state.advertiser = nil
            return old
        }
        oldAdv?.delegate = nil
        oldAdv?.stopAdvertisingPeer()

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
        let oldAdv = lock.withLock { state -> MCNearbyServiceAdvertiser? in
            let old = state.advertiser
            state.advertiser = nil
            state.isHosting = false
            return old
        }
        oldAdv?.delegate = nil
        oldAdv?.stopAdvertisingPeer()
    }

    // MARK: - Join (Browse)

    @MainActor func startBrowsing() {
        // Extract old browser from lock, nil delegate, stop OUTSIDE lock
        // to prevent re-entrant lock from synchronous MC callbacks.
        let oldBr = lock.withLock { state -> MCNearbyServiceBrowser? in
            let old = state.browser
            state.browser = nil
            state.discoveredPeers.removeAll()
            return old
        }
        oldBr?.delegate = nil
        oldBr?.stopBrowsingForPeers()
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
        let oldBr = lock.withLock { state -> MCNearbyServiceBrowser? in
            let old = state.browser
            state.browser = nil
            state.discoveredPeers.removeAll()
            state.isBrowsing = false
            return old
        }
        oldBr?.delegate = nil
        oldBr?.stopBrowsingForPeers()
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
        // Extract session, nil delegate, disconnect OUTSIDE lock.
        let oldSession = lock.withLock { state -> MCSession? in
            let old = state.session
            state.connectedPeer = nil
            return old
        }
        oldSession?.delegate = nil
        oldSession?.disconnect()
        Log.transport.info("Disconnected")
    }

    /// Recreate the internal MCSession for clean reconnection.
    /// A disconnected MCSession may be in a terminal state and unable to accept new connections.
    @MainActor func recreateSession() {
        // Extract old session FIRST, then create new one.
        // Nil delegate + disconnect OUTSIDE the lock to prevent re-entrant
        // lock from synchronous MC callbacks (OSAllocatedUnfairLock is non-reentrant).
        let oldSession = lock.withLock { state -> MCSession? in
            let old = state.session
            state.session = nil
            state.connectedPeer = nil
            return old
        }
        oldSession?.delegate = nil
        oldSession?.disconnect()

        let newSession = MCSession(
            peer: localPeerID,
            securityIdentity: nil,
            encryptionPreference: .optional
        )
        newSession.delegate = self
        lock.withLock { $0.session = newSession }
        Log.transport.info("MCSession recreated")
    }

    /// Recreate both MCPeerID and MCSession to clear all stale DTLS state.
    /// The MC daemon maps DTLS participant state to the MCPeerID's internal
    /// identifier. Reusing the same MCPeerID after a failed connection inherits
    /// poisoned DTLS context ("Not in connected state" errors). A fresh MCPeerID
    /// generates a new participant UUID, forcing a clean DTLS handshake.
    @MainActor func recreateSessionWithFreshPeerID() {
        let displayName = localPeerID.displayName
        localPeerID = MCPeerID(displayName: displayName)

        // Extract old session, nil delegate, disconnect OUTSIDE the lock.
        let oldSession = lock.withLock { state -> MCSession? in
            let old = state.session
            state.session = nil
            state.connectedPeer = nil
            return old
        }
        oldSession?.delegate = nil
        oldSession?.disconnect()

        let newSession = MCSession(
            peer: localPeerID,
            securityIdentity: nil,
            encryptionPreference: .optional
        )
        newSession.delegate = self
        lock.withLock { $0.session = newSession }
        Log.transport.info("MCPeerID + MCSession recreated (fresh DTLS identity)")
    }

    var connectedPeerName: String? {
        lock.withLock { $0.connectedPeer?.displayName }
    }

    var isConnected: Bool {
        lock.withLock { $0.connectedPeer != nil }
    }

    /// Snapshot of currently discovered peers (for polling fallback when AsyncStream misses updates).
    var currentDiscoveredPeers: [MCPeerID] {
        lock.withLock { $0.discoveredPeers }
    }
}

// MARK: - MCSessionDelegate

extension PeerTransport: MCSessionDelegate {
    nonisolated func session(
        _ session: MCSession,
        peer peerID: MCPeerID,
        didChange state: MCSessionState
    ) {
        // Guard against callbacks from stale sessions (race window between
        // nilling delegate and MC delivering the callback).
        let isCurrentSession = lock.withLock { $0.session === session }
        guard isCurrentSession else {
            Log.transport.debug("Ignoring callback from stale MCSession (\(state.rawValue))")
            return
        }

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
        // Ignore data from stale sessions
        let isCurrentSession = lock.withLock { $0.session === session }
        guard isCurrentSession else { return }
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
        delegate?.transport(self, didFailToStartWithError: error)
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

        // Auto-invite is persistent (not one-shot) — it stays active until
        // explicitly cleared by setAutoInviteOnDiscover(false). This handles the
        // case where the host recreates its MCPeerID causing a Lost→Found cycle:
        // the first Found may be for a stale peer, but auto-invite stays active
        // to catch the real new MCPeerID when it appears.
        let shouldAutoInvite = lock.withLock { $0.autoInviteOnDiscover }
        if shouldAutoInvite {
            invite(peer: peerID)
            Log.transport.info("Auto-invited peer: \(peerID.displayName)")
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
        delegate?.transport(self, didFailToStartWithError: error)
    }
}
