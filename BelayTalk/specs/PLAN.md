# BelayTalk — Full Implementation Plan

> **Status: COMPLETE** — All 6 build phases finished. This document is retained as an architecture reference. See `TODO.md` for post-v1 field testing fixes and outstanding items.

## Context

BelayTalk is a production-quality, offline, peer-to-peer voice intercom for rock climbing. Two iPhones with Bluetooth headsets create a persistent, hands-free audio channel between climber and belayer. No internet, no accounts, no servers. Although not a safety device, **lives may depend on its reliability** — so every module must be robust, well-tested, and recoverable.

---

## Pre-Phase: Project Configuration

User must add via Xcode UI (cannot be done programmatically while Xcode is open):
- `NSMicrophoneUsageDescription` — mic permission string
- `NSLocalNetworkUsageDescription` — local network permission string
- Background Modes capability → Audio, AirPlay, and Picture in Picture
- `NSBonjourServices` = `["_belaytalk._tcp"]`

No external dependencies needed — all Apple system frameworks.

---

## Phase 1: Foundation Types, Diagnostics, Persistence

Zero-dependency types every other module imports.

| File | Contents |
|------|----------|
| `Session/SessionTypes.swift` | `SessionState`, `TXState`, `TXMode`, `RouteState`, `ConnectionRole` enums |
| `Session/ProtocolTypes.swift` | `FrameType`, `ControlMessage`, `ControlFrame`, `AudioFrameHeader`, `Capabilities` — wire protocol types |
| `Diagnostics/Log.swift` | `enum Log` with OSLog `Logger` instances per subsystem (session, transport, audio, vad, route, remote, lifecycle) |
| `Diagnostics/Metrics.swift` | `@Observable SessionMetrics` — RTT, packet counts, reconnect count, session duration, thread-safe with `OSAllocatedUnfairLock` |
| `Diagnostics/DiagnosticsExporter.swift` | `DiagnosticReport`, `DeviceInfo`, JSON/readable export |
| `Persistence/Settings.swift` | `@Observable AppSettings` — UserDefaults-backed: txMode, vadSensitivity, hangTime, windRejection, autoResume, speakerFallback, preventAutoLock. Also defines `VADSensitivity`, `HangTime`, `WindRejection` enums |

---

## Phase 2: Audio Infrastructure

Audio capture/playback pipeline + voice activity detection.

| File | Contents |
|------|----------|
| `Audio/AudioConstants.swift` | 16kHz, mono, 20ms frames (320 samples), Int16 wire format, Float32 processing format |
| `Audio/RouteManager.swift` | `protocol RouteManaging` + implementation. Configures `AVAudioSession(.playAndRecord, .voiceChat, .allowBluetooth)`. Observes route changes + interruptions via `AsyncStream<RouteState>` and `AsyncStream<InterruptionEvent>` |
| `Audio/JitterBuffer.swift` | Sequence-keyed buffer (default 60ms / 3 frames, adaptive 40-120ms). Drop late packets, return nil for missing (silence fill) |
| `Audio/AudioFormatConverter.swift` | `AVAudioConverter`-based Float32↔Int16 + sample rate conversion between hardware native and 16kHz wire format |
| `Audio/AudioEngine.swift` | `AVAudioEngine` + `AVAudioPlayerNode`. Input tap captures → delegate callback with `AudioFrameHeader` + `Data`. Receive path: jitter buffer → playback pump (20ms timer). `setVoiceProcessingEnabled(true)` for echo cancellation. Mute via `isVoiceProcessingInputMuted` (keeps pipeline warm). **Silence buffer keep-alive**: schedules zero-filled buffers when jitter buffer is empty to maintain continuous audio output for background execution during screen lock |
| `VAD/RingBuffer.swift` | Fixed-size generic ring buffer for energy history |
| `VAD/VoiceActivityDetector.swift` | `protocol VoiceActivityDetecting` + implementation. RMS energy-based detection, configurable sensitivity/hang time. Wind rejection via high-pass IIR filter + spectral flatness. Outputs `AsyncStream<Bool>` |

Key design decisions:
- `@unchecked Sendable` for audio-thread classes with internal locking (not actors — async overhead unacceptable on RT audio thread)
- Muting via `isVoiceProcessingInputMuted` instead of tap removal (avoids reinstall latency, keeps echo cancellation state)

---

## Phase 3: Transport Layer

MultipeerConnectivity wrapper with protocol framing.

| File | Contents |
|------|----------|
| `Transport/FrameSerializer.swift` | Binary encoding for audio frames (1B type + 19B header + payload). JSON for control frames. Dispatch by first byte |
| `Transport/PeerTransport.swift` | `MCSession` + `MCNearbyServiceAdvertiser` + `MCNearbyServiceBrowser`. Service type: `"belaytalk"`. Encryption: `.optional`. **Single peer enforced** — rejects third connections. Audio sent `.unreliable`, control sent `.reliable`. Delegate protocol for receive callbacks. `updateDisplayName(_:)` recreates MCPeerID + MCSession for live name changes |
| `Transport/HandshakeManager.swift` | State machine: HELLO → HELLO_ACK → CAPS → READY → START. 5s timeout per step. Version/capability validation in CAPS exchange |

---

## Phase 4: Remote Control & Recovery

| File | Contents |
|------|----------|
| `RemoteControl/RemoteControlHandler.swift` | `protocol RemoteControlHandling` + implementation. `MPRemoteCommandCenter` — togglePlayPause/play/pause mapped to TX toggle. Sets minimal `NowPlayingInfo` (required for commands to work). `AsyncStream<RemoteControlEvent>` output |
| `Session/RecoverySupervisor.swift` | Monitors transport disconnection, route changes, interruptions. Auto-reconnect with exponential backoff (0.5s → 5s cap, 10 max attempts). Route degradation handling (BT→speaker = warn, →unavailable = pause). Interruption pause/resume respecting `shouldResume` |

---

## Phase 5: Session Coordinator

| File | Contents |
|------|----------|
| `Session/SessionCoordinator.swift` | `@Observable @MainActor` — the composition root. Owns all modules. Manages session state machine (Idle→Permissions→Ready→Connecting→Active→Reconnecting→Interrupted→RouteFailed→Ended). TX state management per mode (openMic=holdOpen, voiceTX=VAD-gated, manualTX=user-toggled). Bridges delegate callbacks to MainActor. Exposes all state for UI binding via `@Environment`. App lifecycle handling: `handleDidEnterBackground()`, `handleWillEnterForeground()`, `updateIdleTimer()`. Live display name updates via `updateDisplayName(_:)` |

---

## Phase 6: UI Layer

| File | Contents |
|------|----------|
| `BelayTalkApp.swift` | Modify existing — `@State var coordinator`, inject via `.environment()`. Scene phase monitoring for background/foreground lifecycle. Session state observation for idle timer sync |
| `UI/HomeView.swift` | Host/Join buttons, Settings/Diagnostics nav links, permission request on appear |
| `UI/SessionView.swift` | Peer name, connection status, **large TX state indicator** (central, glanceable), mode picker, manual TX button, route badge, end session |
| `UI/PeerBrowserView.swift` | List of discovered peers with `ContentUnavailableView` for empty state |
| `UI/InvitationView.swift` | Accept/reject incoming connection |
| `UI/SettingsView.swift` | Form: TX mode, VAD sensitivity, hang time, wind rejection, speaker fallback, auto resume, prevent auto-lock. Display name field applies immediately on submit |
| `UI/DiagnosticsView.swift` | Metrics display + ShareLink export |
| `UI/Components/StatusIndicator.swift` | Large colored circle (green=OK, amber=degraded, red=failure) |
| `UI/Components/TXStateIndicator.swift` | Large TX state circle with label (LIVE/OPEN MIC/LISTENING/TX OFF/MUTED) |
| `UI/Components/TXButton.swift` | Large manual TX toggle (mic icon, easy to tap) |
| `UI/Components/ConnectionStatusBadge.swift` | Small connection state badge |
| `UI/Components/RouteIndicatorBadge.swift` | Audio route icon (BT/speaker/wired) |
| `UI/Components/MetricRow.swift` | Label-value row for diagnostics |
| Delete `ContentView.swift` | Replaced by HomeView |

Color system: Green = OK, Amber = degraded/connecting, Red = failure/ended, Gray = idle.

---

## File Count Summary

- **31 new files** + 1 modification (`BelayTalkApp.swift`) + 1 deletion (`ContentView.swift`)
- Project config changes via Xcode UI

---

## Verification Plan

1. **Build after each phase** — `BuildProject` to catch compile errors early
2. **Phase 1**: Verify Codable round-trips, default values, UserDefaults persistence
3. **Phase 2**: Test JitterBuffer ordering, RingBuffer behavior, format conversion fidelity
4. **Phase 3**: Test FrameSerializer encode/decode round-trips
5. **Phase 5**: Full build + verify coordinator compiles with all module wiring
6. **Phase 6**: Preview key views (HomeView, SessionView, SettingsView) to verify UI renders
7. **End-to-end**: Full build — the app should compile cleanly with zero warnings
