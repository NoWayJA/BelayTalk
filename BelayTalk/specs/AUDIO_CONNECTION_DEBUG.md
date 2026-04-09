# BelayTalk — Audio Connection Debugging (Continuation Prompt)

## Start Here

Read this file first, then read the source files referenced below. The goal is to **diagnose and fix why it takes 5-6 recovery attempts before audio connects stably** after the initial MultipeerConnectivity (MC) handshake succeeds.

---

## What's Happening

1. User taps Host/Join → MC discovers peer → MC connects → handshake (HELLO→START) succeeds
2. `beginActiveSession()` activates the AVAudioSession in `.voiceChat` mode and starts AudioEngine
3. The `.voiceChat` mode triggers Bluetooth HFP negotiation, which disrupts the AWDL radio that MC uses
4. MC connection drops → `peerDidDisconnect` fires
5. Currently, a 3-second "grace period" absorbs one disconnect during startup (ignores it)
6. But the grace period expires, finds the peer still disconnected, and triggers `RecoverySupervisor`
7. Recovery goes through 5-6 exponential-backoff reconnect cycles before audio finally stabilizes

The user sees **"Connecting audio (attempt 1)…(attempt 2)…"** etc. for about 5-6 cycles.

---

## The Core Conflict

**AVAudioSession `.voiceChat` mode** and **MultipeerConnectivity** both need Bluetooth/AWDL resources. Activating voice processing forces iOS to switch from Bluetooth A2DP to HFP profile, which takes several seconds and disrupts the network radio. This is a well-known iOS limitation.

The 3-second grace period we added is **not long enough** and only absorbs the first disconnect. After grace expires, recovery starts, but each recovery attempt also calls `beginActiveSession()` → `routeManager.configureSession()` → same conflict again.

---

## Key Files to Read (in this order)

1. **`Session/SessionCoordinator.swift`** — The composition root. Focus on:
   - `beginActiveSession()` (~line 330): Grace period + audio session config
   - `handleRecoveryAction(.reconnect)` (~line 451): What happens on each recovery cycle
   - `peerDidConnect` delegate (~line 590): What happens when MC reconnects
   - `peerDidDisconnect` delegate (~line 610): Grace period check + recovery trigger
   - `handleHandshakeResult` (~line 308): Grace-period re-handshake logic

2. **`Audio/RouteManager.swift`** — `configureSession()` sets `.voiceChat` mode. `deactivateSession()` tears it down.

3. **`Session/RecoverySupervisor.swift`** — Exponential backoff: 0.5s, 1s, 2s, 4s, 5s (cap). Max 10 attempts. Each triggers `.reconnect(attempt:)` action.

4. **`Transport/PeerTransport.swift`** — MC wrapper. `recreateSession()` makes a new MCSession. `startAdvertising()`/`startBrowsing()` restart discovery. `isConnected` checks if peer is present.

5. **`Transport/HandshakeManager.swift`** — HELLO → HELLO_ACK → CAPS → READY → START, 5-second timeout per step.

---

## What We Already Tried

- **Audio session deactivation between sessions** — `routeManager.deactivateSession()` in `tearDown()`. Helps with initial connection but doesn't fix the recovery loop.
- **3-second grace period in `beginActiveSession()`** — Absorbs the initial MC disconnect during audio startup. But 3 seconds isn't always enough for BT HFP negotiation to complete.
- **Frame chunking** — Fixed latency (variable-size frames → proper 20ms/320-sample chunks). Not related to connection issue.
- **Reduced buffering** — Jitter depth 3→2, max scheduled buffers 4→2. Not related to connection issue.

---

## Hypotheses to Investigate

### Hypothesis A: Grace period is too short
The BT A2DP→HFP switch can take 3-7 seconds depending on the headset. If the grace period is 3 seconds but the switch takes 5, the grace expires and recovery starts. Each recovery cycle recreates MC + re-configures audio, restarting the BT negotiation timer.

**Test**: Increase grace period to 8 seconds and test. If it consistently connects in one attempt, this is the answer.

### Hypothesis B: Recovery restarts the BT negotiation each time
`handleRecoveryAction(.reconnect)` calls `transport.recreateSession()` + re-advertise/browse. When MC reconnects, `peerDidConnect` → `startHandshake()` → `handleHandshakeResult(.success)` → if session not active, calls `beginActiveSession()` → `routeManager.configureSession()` again. This **restarts** the BT HFP negotiation, resetting the clock.

**Test**: During recovery, skip `routeManager.configureSession()` if the audio session is already configured. Keep the AudioEngine running across reconnection attempts instead of stopping/restarting it.

### Hypothesis C: AudioEngine stop/start cycle causes the instability
In `peerDidDisconnect` (non-grace case), `audioEngine.stop()` is called. When recovery reconnects, `beginActiveSession()` calls `audioEngine.start()` again. Each stop/start cycle reconfigures the audio hardware, which triggers another BT route change.

**Test**: During recovery reconnection, don't stop the AudioEngine. Let it keep running with silence. Only stop it if the user gives up or the session ends cleanly.

### Hypothesis D: MC disconnect during recovery triggers more recovery
When recovery reconnects and the MC connection drops again (due to ongoing BT negotiation), `peerDidDisconnect` fires. If `sessionState` is `.reconnecting`, the current code at line ~650 just logs "Peer disconnected during reconnection." But the reconnect timeout task at line ~477 will schedule another attempt, creating a cascading retry loop.

**Test**: Track whether the recovery is triggered by the timeout (10s) or by additional disconnect events. Add more detailed logging.

---

## Recommended Approach

The most promising fix is a **combination of B and C**: keep the AudioEngine and AVAudioSession alive across recovery attempts. Only call `routeManager.configureSession()` and `audioEngine.start()` once (on the first `beginActiveSession()`). On reconnection, just re-handshake on the existing audio pipeline.

This means:
1. `peerDidDisconnect` in `.active` state should NOT stop the audio (even outside grace)
2. Recovery should only recreate the MC session, not the audio session
3. When MC reconnects after recovery → handshake → success → detect that audio is already running → skip `beginActiveSession()` (this logic already exists from the grace period change)
4. The grace period concept expands to cover the entire recovery process, not just the first 3 seconds

The key insight: **MC and audio are independent subsystems**. MC dropping doesn't mean audio needs to restart. Keep audio alive, just reconnect the MC transport and re-handshake.

---

## How to Verify

1. Build and deploy to two iPhones with Bluetooth headsets
2. Host on one, Join on the other
3. After initial MC handshake, observe the Console logs (filter by `com.belaytalk`)
4. Count how many recovery attempts happen before audio stabilizes
5. Target: 0 recovery attempts (grace period absorbs the BT negotiation, MC reconnects within grace, audio never stopped)

---

## Important Context

- The UI shows "Connecting audio (attempt N)…" during recovery (was "Reconnecting", changed to friendlier language)
- `SessionState.reconnecting` is the state during recovery
- `ConnectionStatusBadge` shows "Connecting Audio…" for `.reconnecting` state
- All types are MainActor by default (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`)
- Audio-thread classes use `@unchecked Sendable` + `OSAllocatedUnfairLock`
- No Combine — use async/await and AsyncStream
