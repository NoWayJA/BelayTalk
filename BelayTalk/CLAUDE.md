# CLAUDE.md — Project Instructions for Claude Code

## Project Overview

BelayTalk is a production-quality, offline, peer-to-peer voice intercom iOS app for rock climbing. Two iPhones + Bluetooth headsets create a persistent, hands-free audio channel between climber and belayer. **Lives may depend on reliability.**

## Specs

- `specs/overview.md` — Product vision and problem statement
- `specs/Feature_Stories.md` — Full technical specification
- `specs/PLAN.md` — Original file-by-file build plan (all phases complete)
- `specs/TODO.md` — Implementation progress checklist
- `specs/CONTINUATION.md` — Quick-start context for resuming work
- `specs/AUDIO_CONNECTION_DEBUG.md` — Debugging guide for the audio connection retry issue

## Build & Run

- **Xcode project** — open `BelayTalk.xcodeproj`
- **Deployment target**: iOS 26.4
- **No external dependencies** — all Apple system frameworks
- Build with Xcode or `BuildProject` MCP command

## Architecture

9 modules, built bottom-up:

```
BelayTalk/BelayTalk/
  Session/         — SessionTypes, ProtocolTypes, SessionCoordinator, RecoverySupervisor
  Diagnostics/     — Log, Metrics, DiagnosticsExporter
  Persistence/     — Settings
  Audio/           — AudioConstants, AudioEngine, AudioFormatConverter, JitterBuffer, RouteManager
  VAD/             — VoiceActivityDetector, RingBuffer
  Transport/       — PeerTransport, FrameSerializer, HandshakeManager
  RemoteControl/   — RemoteControlHandler
  UI/              — HomeView, SessionView, PeerBrowserView, InvitationView, SettingsView, DiagnosticsView
  UI/Components/   — StatusIndicator, TXStateIndicator, TXButton, ConnectionStatusBadge, RouteIndicatorBadge, MetricRow
```

## Code Style

- PascalCase for types, camelCase for properties/methods
- 4-space indentation
- `let` over `var` where possible
- No Combine — use async/await and AsyncStream
- `@Observable` + `@Environment` for UI state
- `@unchecked Sendable` with `OSAllocatedUnfairLock` for audio-thread classes
- `nonisolated` on infrastructure types (non-UI) for cross-isolation access
- OSLog via `Log.session`, `Log.transport`, `Log.audio`, etc.

## Concurrency Model

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — all types are MainActor by default
- `SWIFT_APPROACHABLE_CONCURRENCY = YES`
- Infrastructure types (Audio, Transport, VAD) are marked `nonisolated` to opt out
- UI-bound `@Observable` classes stay on MainActor

## Key Technical Decisions

- Audio: 16kHz mono, 20ms frames (320 samples), PCM Int16 on wire, Float32 for processing
- Frame chunking: hardware delivers variable-size buffers (1024-4096 samples at 48kHz); after rate conversion to 16kHz, AudioEngine chunks into proper 320-sample frames with residual buffering between callbacks
- `MCSessionSendDataMode.unreliable` for audio, `.reliable` for control
- TX muting via `isVoiceProcessingInputMuted` (keeps echo cancellation state)
- Jitter buffer: 40ms default (2 frames), adaptive 40-120ms
- Max scheduled playback buffers: 2 (40ms max playback queue)
- Handshake: HELLO → HELLO_ACK → CAPS → READY → START
- Recovery: exponential backoff 3s → 10s cap, 5 max attempts
- Two-phase audio activation: Phase 1 starts on built-in speaker (no BT HFP → AWDL stays clean). Phase 2 upgrades to BT HFP after 3s MC stability check, with 10s grace period for the A2DP→HFP switch.
- Fresh MCPeerID on connection failure: `recreateSessionWithFreshPeerID()` clears stale DTLS state that causes "Not in connected state" errors
- Asymmetric retry timing: guest retries fast (0.5-1s), host retries slower (2-3s) to break DTLS race conditions
- Audio session deactivation: `tearDown()` deactivates AVAudioSession to free AWDL radio for subsequent MC discovery
- Connection status messages: `connectionStatusMessage` observable property updated at each lifecycle stage for UI feedback
- MC failure surfacing: advertiser/browser failures reported via `didFailToStartWithError` delegate method
- Background audio keep-alive: silence buffers scheduled when jitter buffer is empty — iOS requires continuous audio output to keep app alive during screen lock
- Scene phase monitoring in BelayTalkApp for background/foreground lifecycle handling
- Display name changes take effect immediately (MCPeerID + MCSession recreated)

## Known Issues

- BT HFP negotiation briefly disrupts AWDL radio. Mitigated by two-phase audio activation (speaker first, BT upgrade after MC stabilizes). See `specs/AUDIO_CONNECTION_DEBUG.md` for full analysis.

## Permissions (Info.plist)

- `NSMicrophoneUsageDescription`
- `NSLocalNetworkUsageDescription`
- `UIBackgroundModes` → audio
- `NSBonjourServices` → `_belaytalk._tcp`
