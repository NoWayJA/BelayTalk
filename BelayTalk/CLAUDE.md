# CLAUDE.md — Project Instructions for Claude Code

## Project Overview

BelayTalk is a production-quality, offline, peer-to-peer voice intercom iOS app for rock climbing. Two iPhones + Bluetooth headsets create a persistent, hands-free audio channel between climber and belayer. **Lives may depend on reliability.**

## Specs

- `specs/overview.md` — Product vision and problem statement
- `specs/Feature_Stories.md` — Full technical specification
- `specs/PLAN.md` — File-by-file implementation plan
- `specs/TODO.md` — Implementation progress checklist
- `specs/CONTINUATION.md` — Quick-start context for resuming work

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

- Audio: 16kHz mono, 20ms frames, PCM Int16 on wire, Float32 for processing
- `MCSessionSendDataMode.unreliable` for audio, `.reliable` for control
- TX muting via `isVoiceProcessingInputMuted` (keeps echo cancellation state)
- Jitter buffer: 60ms default, adaptive 40-120ms
- Handshake: HELLO → HELLO_ACK → CAPS → READY → START
- Recovery: exponential backoff 0.5s → 5s cap, 10 max attempts
- Background audio keep-alive: silence buffers scheduled when jitter buffer is empty — iOS requires continuous audio output to keep app alive during screen lock
- Scene phase monitoring in BelayTalkApp for background/foreground lifecycle handling
- Display name changes take effect immediately (MCPeerID + MCSession recreated)

## Permissions (Info.plist)

- `NSMicrophoneUsageDescription`
- `NSLocalNetworkUsageDescription`
- `UIBackgroundModes` → audio
- `NSBonjourServices` → `_belaytalk._tcp`
