# BelayTalk — Continuation Prompt

Use this document to resume implementation in a fresh context. Read this file, then read `specs/PLAN.md` and `specs/TODO.md`, then continue building from wherever TODO.md left off.

---

## What Is BelayTalk

A production-quality, offline, peer-to-peer voice intercom iOS app for rock climbing. Two iPhones + Bluetooth headsets create a persistent, hands-free audio channel between climber and belayer. **Lives may depend on reliability** — this is not a toy.

Read `specs/overview.md` for product vision and `specs/Feature_Stories.md` for the full technical specification.

---

## Project Setup

- **Xcode project**: SwiftUI app, file-system synchronized groups (just create files on disk / via XcodeWrite — Xcode picks them up automatically)
- **Deployment target**: iOS 26.4 (latest)
- **Swift concurrency**: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`
- **No external dependencies** — all Apple system frameworks (AVFAudio, MultipeerConnectivity, MediaPlayer, OSLog)
- **Info.plist**: Auto-generated from build settings + explicit `BelayTalk/Info.plist` for Bonjour/background audio
- **Permissions configured**: Microphone, Local Network, Background Audio, Bonjour `_belaytalk._tcp`

---

## Architecture

9 modules, built bottom-up:

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
2. **`@unchecked Sendable`** with `OSAllocatedUnfairLock` for audio-thread classes (actors too slow for RT audio)
3. **AsyncStream** for event delivery (route changes, VAD, remote control, interruptions)
4. **Binary serialization** for audio frames (1B type + 19B header + PCM payload), JSON for control frames
5. **Audio**: 16kHz mono, 20ms frames (320 samples), PCM Int16 on wire, Float32 for processing
6. **`MCSessionSendDataMode.unreliable`** for audio, `.reliable` for control messages
7. **`isVoiceProcessingInputMuted`** for TX gating (keeps pipeline warm, preserves echo cancellation state)
8. **`setVoiceProcessingEnabled(true)`** on input node for echo cancellation + noise reduction
9. **Jitter buffer**: 60ms default (3 frames), adaptive 40-120ms, drop late packets, silence fill for missing
10. **Session state machine**: Idle → Permissions → Ready → Connecting → Active → Reconnecting → Interrupted → RouteFailed → Ended
11. **TX states**: Disabled, Armed, Live, HoldOpen, Muted
12. **Three TX modes**: Open Mic (continuous), Voice TX (VAD-gated, default), Manual TX (user-toggled)
13. **Handshake**: HELLO → HELLO_ACK → CAPS → READY → START
14. **Recovery**: Exponential backoff reconnect (0.5s → 5s cap, 10 max attempts)
15. **Background audio keep-alive**: AudioEngine schedules silence buffers when jitter buffer is empty — iOS requires continuous audio output to keep background audio apps alive during screen lock
16. **Scene phase monitoring**: BelayTalkApp observes scenePhase to handle background/foreground transitions and re-activate audio session after interruption
17. **Display name updates**: PeerTransport.updateDisplayName() recreates MCPeerID + MCSession — takes effect immediately without app restart (only when not in a session)

---

## Build Order

Phases must be built in order (each depends on the previous):

1. **Phase 1**: Foundation types + diagnostics + persistence (6 files)
2. **Phase 2**: Audio infrastructure — RouteManager, AudioEngine, VAD (7 files)
3. **Phase 3**: Transport — PeerTransport, FrameSerializer, Handshake (3 files)
4. **Phase 4**: Remote control + recovery supervisor (2 files)
5. **Phase 5**: Session coordinator (1 file — the composition root)
6. **Phase 6**: UI layer — all views and components (13 files + modify BelayTalkApp.swift + delete ContentView.swift)

**Build after each phase** to catch errors early.

---

## Code Style

- PascalCase for types, camelCase for properties/methods
- 4-space indentation
- `let` over `var` where possible
- Protocols for testability (`RouteManaging`, `VoiceActivityDetecting`, `RemoteControlHandling`)
- OSLog via `Log.session`, `Log.transport`, `Log.audio`, etc.
- No Combine — use async/await and AsyncStream
- Production quality: defensive error handling, clear logging, graceful degradation

---

## How To Continue

1. Read this file (done)
2. Read `specs/PLAN.md` for detailed file-by-file descriptions
3. Read `specs/TODO.md` to see what's completed and what's next
4. Pick up from the first unchecked item in TODO.md
5. After completing each file, update TODO.md to check it off
6. Build after completing each phase
