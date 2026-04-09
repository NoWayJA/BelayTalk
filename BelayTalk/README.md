# BelayTalk

**Offline, peer-to-peer voice intercom for rock climbing.**

Two iPhones + Bluetooth headsets = a persistent, hands-free audio channel between climber and belayer. No internet, no accounts, no servers.

> **Status: Proof of Concept.** BelayTalk is a working prototype that demonstrates the core idea. Connection reliability with Bluetooth headsets still needs significant work. See [Known Limitations](#known-limitations) below.

---

## The Problem

Rock climbing communication is deceptively fragile. Even within 40 metres and line of sight, communication regularly fails:

- **Wind** drowns out voices
- **Rope drag** creates constant background noise
- **Helmets** obstruct hearing
- **Distance** distorts speech beyond recognition
- **Echo** off walls and crags garbles commands

Climbers mitigate this with predefined commands, rope signals, and visual checks. But these systems degrade with distance and noise, are not continuous, and can be misinterpreted under stress.

**Miscommunication at the crag has real consequences.**

## The Insight

Climbing doesn't need a walkie-talkie. It needs a **persistent, low-friction shared audio space** -- something closer to standing next to your partner. Hearing tone, hesitation, breath. Speaking naturally without ritual.

The goal is not "communication on demand." It is **continuous situational awareness through sound**.

| | Walkie-Talkie | BelayTalk |
|---|---|---|
| Transmission | Manual (push-to-talk) | Automatic (voice-activated) |
| Listening | Intermittent | Continuous |
| Cognitive load | High | Low |
| Flow | Interrupted | Natural |

## How It Works

1. **One phone hosts, one joins** -- tap a button, devices find each other automatically
2. **Audio starts immediately** -- hands-free via Bluetooth headset
3. **Three TX modes** adapt to conditions:
   - **Open Mic** -- continuous transmission, simplest
   - **Voice TX** -- VAD-gated (default), transmits only when you speak
   - **Manual TX** -- push-to-talk fallback for noisy environments
4. **Headset button** toggles transmit without touching the phone
5. **Works with screen locked** -- clip your phone, forget about it

Connection and audio recovery happen automatically. If it works perfectly, you forget it exists.

## Features

- **Bluetooth headset support** with automatic route detection and speaker fallback
- **Voice Activity Detection** with configurable sensitivity, hang time, and wind rejection
- **Echo cancellation** via Apple's voice processing pipeline
- **Auto-reconnect** with exponential backoff recovery
- **Background audio** -- works with screen locked via audio background mode
- **Two-phase audio startup** -- begins on speaker, upgrades to Bluetooth after connection stabilizes (avoids radio conflicts)
- **Real-time diagnostics** -- RTT, packet loss, session metrics with JSON export
- **Zero infrastructure** -- Apple MultipeerConnectivity over Bluetooth + WiFi Direct (AWDL)
- **No external dependencies** -- pure Swift/SwiftUI, Apple frameworks only

## Requirements

- 2 x iPhones running iOS 17+
- Bluetooth headsets recommended (built-in speaker/mic works as fallback)
- No internet or cellular signal required
- Xcode 16+ to build

## Building

```bash
git clone https://github.com/your-username/BelayTalk.git
cd BelayTalk
open BelayTalk.xcodeproj
```

Build and run on two physical iPhones. **MultipeerConnectivity requires real devices** -- the Simulator cannot discover peers.

No package dependencies to resolve. No CocoaPods, no SPM packages, nothing to configure.

## Architecture

BelayTalk is built as 9 modules, layered bottom-up with clear separation of concerns:

```
BelayTalk/
  Session/         -- State machine, coordinator, recovery supervisor
  Diagnostics/     -- OSLog subsystems, session metrics, diagnostic export
  Persistence/     -- UserDefaults-backed settings
  Audio/           -- AVAudioEngine capture/playback, format conversion, jitter buffer
  VAD/             -- Voice activity detection with wind rejection
  Transport/       -- MultipeerConnectivity wrapper, binary framing, handshake protocol
  RemoteControl/   -- MPRemoteCommandCenter for headset button control
  UI/              -- SwiftUI views (Home, Session, PeerBrowser, Settings, Diagnostics)
  UI/Components/   -- Reusable indicators, badges, and controls
```

### Key Technical Decisions

| Decision | Rationale |
|---|---|
| 16 kHz mono, 20ms frames | Optimized for voice. Minimal bandwidth while retaining clarity. |
| PCM Int16 on wire, Float32 for processing | Halves bandwidth vs Float32. Lossless for voice frequencies. |
| `MCSession.unreliable` for audio | UDP-like delivery. Dropped frames > delayed frames for real-time voice. |
| Adaptive jitter buffer (40-120ms) | Absorbs network jitter without adding unnecessary latency. |
| `@Observable` + async/await | No Combine. Modern Swift concurrency throughout. |
| `nonisolated` audio/transport types | Audio callbacks can't wait for MainActor. Lock-based isolation with `OSAllocatedUnfairLock`. |
| Two-phase Bluetooth activation | Avoids AWDL/HFP radio conflict that kills MultipeerConnectivity. |

### Connection Protocol

```
Host advertises  <-->  Guest browses
         Guest sends invitation
         Host auto-accepts
         MC establishes DTLS connection

HELLO --> HELLO_ACK --> CAPS --> READY --> START

Audio flows bidirectionally
```

Recovery on disconnect: audio session deactivated (frees AWDL radio), exponential backoff reconnection, fresh DTLS identity on each attempt.

## Known Limitations

> **This is a proof of concept.** It works, but connection reliability needs significant further development before it can be considered production-ready.

### Bluetooth + MultipeerConnectivity Radio Conflict

The core technical challenge: Apple's MultipeerConnectivity uses the **AWDL radio** (Apple Wireless Direct Link), which shares spectrum with **Bluetooth HFP** (the profile used for headset audio). When a Bluetooth headset negotiates HFP mode, it can disrupt AWDL, causing MultipeerConnectivity to drop.

BelayTalk mitigates this with:
- **Two-phase audio startup** -- start on built-in speaker first, upgrade to Bluetooth after MC stabilizes
- **Grace period** -- ignore brief MC disconnects during Bluetooth negotiation
- **Audio deactivation during recovery** -- free the AWDL radio for reconnection
- **Fresh DTLS identity on retry** -- avoid poisoned connection state

These mitigations help significantly, but **initial connection can still take multiple attempts** depending on headset model and radio conditions. This is the primary area needing further work.

### Other Limitations

- **Range**: ~40m line of sight (MultipeerConnectivity limitation, not app limitation)
- **Two devices only**: Designed as a 1:1 intercom, not a group call
- **iOS only**: Uses Apple-specific frameworks (MultipeerConnectivity, AVAudioEngine)
- **No encryption beyond DTLS**: MC provides transport-level encryption when available
- **Battery**: ~4h open mic, ~6h VAD mode (estimate -- not rigorously tested)

## Project Structure

```
BelayTalk/
  BelayTalk/
    BelayTalkApp.swift          -- App entry point, scene lifecycle
    Session/
      SessionCoordinator.swift  -- Central orchestrator (~800 lines, the heart of the app)
      SessionTypes.swift        -- State machine, enums, capabilities
      ProtocolTypes.swift       -- Wire protocol types (audio header, control frames)
      RecoverySupervisor.swift  -- Exponential backoff recovery state machine
    Audio/
      AudioEngine.swift         -- AVAudioEngine capture + playback
      AudioConstants.swift      -- Sample rate, frame size, buffer config
      AudioFormatConverter.swift -- Float32 <-> Int16 conversion
      JitterBuffer.swift        -- Adaptive jitter buffer with silence fill
      RouteManager.swift        -- AVAudioSession configuration + route monitoring
    VAD/
      VoiceActivityDetector.swift -- Energy + zero-crossing + wind rejection
      RingBuffer.swift          -- Lock-free circular buffer for audio samples
    Transport/
      PeerTransport.swift       -- MultipeerConnectivity wrapper
      FrameSerializer.swift     -- Binary frame encoding/decoding
      HandshakeManager.swift    -- Connection handshake state machine
    RemoteControl/
      RemoteControlHandler.swift -- Headset button -> TX toggle
    Diagnostics/
      Log.swift                 -- OSLog subsystem definitions
      Metrics.swift             -- Packet counts, RTT, session duration
      DiagnosticsExporter.swift -- JSON + readable report generation
    Persistence/
      Settings.swift            -- UserDefaults-backed app settings
    UI/
      HomeView.swift            -- Host/Join entry point
      SessionView.swift         -- Active session interface
      PeerBrowserView.swift     -- Peer discovery list
      SettingsView.swift        -- Configuration
      DiagnosticsView.swift     -- Real-time metrics display
    UI/Components/
      StatusIndicator.swift     -- Connection state visualization
      TXButton.swift            -- Transmit toggle button
      TXStateIndicator.swift    -- Large TX state feedback
      ConnectionStatusBadge.swift
      RouteIndicatorBadge.swift
      MetricRow.swift
  specs/
    overview.md                 -- Product vision and design philosophy
    Feature_Stories.md          -- Technical specification
    PLAN.md                     -- Build plan (all phases complete)
    TODO.md                     -- Implementation checklist
    CONTINUATION.md             -- Developer context for resuming work
    AUDIO_CONNECTION_DEBUG.md   -- BT/AWDL conflict analysis and debugging guide
```

## Contributing

BelayTalk is open source and contributions are welcome, especially in these areas:

1. **Connection reliability** -- the AWDL/HFP radio conflict is the biggest challenge. If you have experience with MultipeerConnectivity internals or AWDL, your insight would be invaluable.
2. **Field testing** -- try it at your local crag and file issues with logs (the app has built-in diagnostics export).
3. **Audio quality** -- jitter buffer tuning, VAD sensitivity, wind rejection improvements.
4. **UI/UX** -- the interface is functional but could be more polished.

### Getting Started

1. Read `specs/overview.md` for the product vision
2. Read `specs/Feature_Stories.md` for the technical specification
3. Read `specs/AUDIO_CONNECTION_DEBUG.md` for the core technical challenge
4. Build and test on two physical iPhones with Bluetooth headsets

## Design Philosophy

**Invisible infrastructure.** If it works perfectly, you forget it exists.

**Hands-free first.** Climbers can't reliably look at screens, press buttons, or hold devices. Voice activation is primary; manual controls are fallback.

**Resilience over features.** This is not a feature-rich app. It is a high-reliability, single-purpose tool. Fewer features, more robustness.

**Local-first.** No servers, no accounts, no internet dependency. This is both a technical constraint and a privacy feature.

## Safety Disclaimer

> **BelayTalk is a communication aid only.** It is non-critical augmentation, not replacement. Standard climbing safety practices -- verbal commands, rope signals, visual confirmation -- remain primary. Do not rely on BelayTalk as a safety device. If it disappears, climbing still works.

## Beyond Climbing

This is a prototype of a broader category: **local, ephemeral, peer-to-peer presence systems**. The same architecture could serve skiing, cycling, construction teams, field work, or search and rescue. Climbing is the ideal starting point because constraints are strict, users are attentive, failure modes are obvious, and feedback is immediate.

## License

MIT License -- see [LICENSE](LICENSE)
