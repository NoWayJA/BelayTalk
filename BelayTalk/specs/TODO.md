# BelayTalk — Implementation Progress

## Pre-Phase: Project Configuration
- [x] Add `NSMicrophoneUsageDescription` to Info.plist
- [x] Add `NSLocalNetworkUsageDescription` to Info.plist
- [x] Add Background Modes capability → Audio, AirPlay, and Picture in Picture
- [x] Add `NSBonjourServices` with `_belaytalk._tcp`

## Phase 1: Foundation Types, Diagnostics, Persistence
- [x] `Session/SessionTypes.swift` — Core enums
- [x] `Session/ProtocolTypes.swift` — Wire protocol types
- [x] `Diagnostics/Log.swift` — OSLog loggers
- [x] `Diagnostics/Metrics.swift` — SessionMetrics
- [x] `Diagnostics/DiagnosticsExporter.swift` — Report export
- [x] `Persistence/Settings.swift` — AppSettings + setting enums
- [x] Build verification

## Phase 2: Audio Infrastructure
- [x] `Audio/AudioConstants.swift` — Audio format constants
- [x] `Audio/RouteManager.swift` — AVAudioSession + route observation
- [x] `Audio/JitterBuffer.swift` — Packet reorder buffer
- [x] `Audio/AudioFormatConverter.swift` — Format conversion
- [x] `Audio/AudioEngine.swift` — Capture + playback pipeline
- [x] `VAD/RingBuffer.swift` — Ring buffer utility
- [x] `VAD/VoiceActivityDetector.swift` — Voice activity detection
- [x] Build verification

## Phase 3: Transport Layer
- [x] `Transport/FrameSerializer.swift` — Binary/JSON frame encoding
- [x] `Transport/PeerTransport.swift` — MultipeerConnectivity wrapper
- [x] `Transport/HandshakeManager.swift` — Connection handshake
- [x] Build verification

## Phase 4: Remote Control & Recovery
- [x] `RemoteControl/RemoteControlHandler.swift` — Headset buttons
- [x] `Session/RecoverySupervisor.swift` — Auto-reconnect + recovery
- [x] Build verification

## Phase 5: Session Coordinator
- [x] `Session/SessionCoordinator.swift` — Top-level orchestrator
- [x] Build verification

## Phase 6: UI Layer
- [x] `UI/HomeView.swift` — Landing screen
- [x] `UI/SessionView.swift` — Active session screen
- [x] `UI/PeerBrowserView.swift` — Peer discovery list
- [x] `UI/InvitationView.swift` — Connection invitation
- [x] `UI/SettingsView.swift` — Settings form
- [x] `UI/DiagnosticsView.swift` — Metrics + export
- [x] `UI/Components/StatusIndicator.swift` — Status circle
- [x] `UI/Components/TXStateIndicator.swift` — TX state display
- [x] `UI/Components/TXButton.swift` — Manual TX toggle
- [x] `UI/Components/ConnectionStatusBadge.swift` — Connection badge
- [x] `UI/Components/RouteIndicatorBadge.swift` — Route badge
- [x] `UI/Components/MetricRow.swift` — Diagnostics row
- [x] Modify `BelayTalkApp.swift` — DI setup
- [x] Delete `ContentView.swift`
- [x] Build verification

## Final
- [x] Full clean build with zero warnings

## Post-v1: Field Testing Fixes

### Background Audio / Screen Lock Survival
- [x] AudioEngine: silence buffer keep-alive — schedule zero-filled buffers when jitter buffer is empty so iOS never suspends the app during screen lock
- [x] BelayTalkApp: scene phase monitoring — detect background/foreground transitions, re-activate audio session on foreground return if interrupted
- [x] SessionCoordinator: app lifecycle handlers — `handleDidEnterBackground()`, `handleWillEnterForeground()`, `updateIdleTimer()`

### Settings Improvements
- [x] Add `preventAutoLock` setting (default: off) — optionally keeps screen awake during sessions
- [x] Display name live update — changing name in settings now takes effect immediately without app restart (recreates MCPeerID + MCSession)
- [x] PeerTransport: `updateDisplayName(_:)` method — recreates peer identity when not in a session
### Connection Reliability & Latency (Code Review Fixes)
- [x] Audio session deactivation: `RouteManager.deactivateSession()` called in `tearDown()` and `cancelConnecting()` to free AWDL radio for subsequent MC discovery
- [x] Frame chunking: AudioEngine now chunks variable-size hardware buffers into proper 320-sample (20ms) frames with residual buffering between callbacks
- [x] Direct Float32→Int16 conversion: `float32ChunkToInt16Data()` helper avoids AVAudioPCMBuffer allocation on audio thread
- [x] Reduced jitter buffer depth: 3 frames (60ms) → 2 frames (40ms)
- [x] Reduced max scheduled playback buffers: 4 → 2 (40ms max playback queue)
- [x] Audio startup grace period: 3-second window in `beginActiveSession()` where MC disconnects are ignored (BT HFP/AWDL conflict expected)
- [x] Connection status messages: `connectionStatusMessage` observable property on SessionCoordinator, updated at each lifecycle stage
- [x] UI status integration: BelayTalkApp, PeerBrowserView, SessionView all display live connection status
- [x] "Reconnecting" → "Connecting audio" language across all UI surfaces
- [x] VAD reset: `vad.reset()` called in `beginActiveSession()` and `tearDown()`
- [x] MC failure surfacing: `didFailToStartWithError` added to PeerTransportDelegate, fired from advertiser/browser failure callbacks
- [x] Handshake CAPS skip warning: log warning when READY arrives before CAPS

### Outstanding
- [ ] Audio connection retry issue: still takes 5-6 recovery attempts before audio stabilizes (see `specs/AUDIO_CONNECTION_DEBUG.md`)
- [ ] Preview verification on key views

