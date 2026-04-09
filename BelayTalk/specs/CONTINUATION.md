# BelayTalk — Continuation Prompt

Use this document to resume work in a fresh context.

---

## What Is BelayTalk

A production-quality, offline, peer-to-peer voice intercom iOS app for rock climbing. Two iPhones + Bluetooth headsets create a persistent, hands-free audio channel between climber and belayer. **Lives may depend on reliability.**

Read `specs/overview.md` for product vision and `specs/Feature_Stories.md` for the full technical specification.

---

## Current State

The app is **fully built and functional**. All 6 build phases are complete (31 files). It connects, handshakes, and streams audio between two iPhones with Bluetooth headsets. Background audio works during screen lock.

### Recent Improvements (April 2025)
- **Audio session deactivation** — `RouteManager.deactivateSession()` frees AWDL radio between sessions
- **Frame chunking** — Variable hardware buffers chunked into proper 320-sample (20ms) frames
- **Reduced buffering** — Jitter depth 3→2 frames (40ms), playback cap 4→2 buffers
- **Audio startup grace period** — 3s window where MC disconnects are ignored during BT HFP negotiation
- **Connection status UI** — `connectionStatusMessage` shows live status at every lifecycle stage
- **"Connecting audio"** language — User-friendly status during audio reconnection
- **MC failure surfacing** — Advertiser/browser failures reported via delegate
- **VAD reset** — Cleared on session start and teardown

### Known Issue
Audio still takes **5-6 recovery attempts** to stabilize after initial MC connection. This is due to the BT HFP/AWDL radio conflict. See `specs/AUDIO_CONNECTION_DEBUG.md` for full analysis, hypotheses, and the recommended fix approach.

---

## Architecture

9 modules:

```
BelayTalk/BelayTalk/
  Session/         — SessionTypes, ProtocolTypes, SessionCoordinator, RecoverySupervisor
  Diagnostics/     — Log (OSLog), Metrics, DiagnosticsExporter
  Persistence/     — Settings (UserDefaults-backed)
  Audio/           — AudioConstants, AudioEngine, AudioFormatConverter, JitterBuffer, RouteManager
  VAD/             — VoiceActivityDetector, RingBuffer
  Transport/       — PeerTransport (MultipeerConnectivity), FrameSerializer, HandshakeManager
  RemoteControl/   — RemoteControlHandler (headset buttons via MPRemoteCommandCenter)
  UI/              — HomeView, SessionView, PeerBrowserView, InvitationView, SettingsView, DiagnosticsView
  UI/Components/   — StatusIndicator, TXStateIndicator, TXButton, ConnectionStatusBadge, RouteIndicatorBadge, MetricRow
```

---

## Key Technical Decisions

1. **`@Observable` + `@Environment`** for UI state (not Combine, not `@Published`)
2. **`@unchecked Sendable`** with `OSAllocatedUnfairLock` for audio-thread classes
3. **AsyncStream** for event delivery (route changes, VAD, remote control, interruptions)
4. **Audio**: 16kHz mono, 20ms frames (320 samples), PCM Int16 on wire, Float32 for processing
5. **Frame chunking**: Hardware delivers variable buffers; AudioEngine chunks to 320-sample frames with residual carry
6. **`MCSessionSendDataMode.unreliable`** for audio, `.reliable` for control
7. **Jitter buffer**: 40ms default (2 frames), adaptive 40-120ms
8. **Handshake**: HELLO → HELLO_ACK → CAPS → READY → START
9. **Recovery**: Exponential backoff 0.5s → 5s cap, 10 max attempts
10. **Audio startup grace**: 3s window ignoring MC disconnects during BT HFP negotiation
11. **Audio session deactivation**: `tearDown()` deactivates AVAudioSession to free AWDL radio
12. **Connection status**: `connectionStatusMessage` observable property updated at each lifecycle stage

---

## Build & Run

- **Xcode project**: `BelayTalk.xcodeproj`
- **Deployment target**: iOS 26.4
- **No external dependencies** — all Apple system frameworks
- **Concurrency**: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`

---

## How To Continue

1. Read this file (done)
2. Read `CLAUDE.md` for code style and conventions
3. Check `specs/TODO.md` for outstanding items
4. For the audio connection retry issue, read `specs/AUDIO_CONNECTION_DEBUG.md`
5. Read the relevant source files before making changes
