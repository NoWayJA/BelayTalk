# BelayTalk

**Offline, peer-to-peer voice intercom for rock climbing.**

Two iPhones with Bluetooth headsets create a persistent, hands-free audio channel between climber and belayer. No internet, no accounts, no servers.

## The Problem

Rock climbing communication is deceptively fragile. Even within 40 metres and line of sight, communication often fails due to wind, rope drag noise, helmets obstructing hearing, distance distortion, and environmental echo. Miscommunication at the crag can have serious consequences.

## The Solution

BelayTalk turns two iPhones into a dedicated intercom system:

- **Bluetooth headset support** — clip your phone, keep hands free
- **Three TX modes** — Open Mic (continuous), Voice TX (VAD-gated, default), Manual TX (push-to-talk)
- **Headset button control** — toggle transmit without touching your phone
- **Auto reconnect** — recovers from disconnections automatically
- **Background audio** — works with screen locked
- **Zero infrastructure** — uses Apple's MultipeerConnectivity (Bluetooth + WiFi Direct)

## Requirements

- 2 x iPhones running iOS 17+
- Bluetooth headsets recommended (built-in speaker fallback available)
- No internet or cellular signal required

## Technical Highlights

- **Pure Swift / SwiftUI** — no external dependencies
- **16 kHz mono audio** — optimized for voice, minimal bandwidth
- **< 150ms latency** target (ideal), < 250ms max
- **Echo cancellation** via Apple's voice processing
- **VAD with wind rejection** — high-pass filter + spectral analysis
- **Binary protocol** — 1-byte type + 19-byte header + PCM payload
- **Adaptive jitter buffer** — 40-120ms range
- **Full diagnostics** — RTT, packet loss, session metrics with export

## Architecture

```
Session/         — State machine, coordinator, recovery
Diagnostics/     — OSLog, metrics, report export
Persistence/     — UserDefaults-backed settings
Audio/           — AVAudioEngine capture/playback, format conversion, jitter buffer
VAD/             — Voice activity detection with wind rejection
Transport/       — MultipeerConnectivity, binary framing, handshake
RemoteControl/   — MPRemoteCommandCenter headset button handling
UI/              — SwiftUI views and components
```

## Building

Open `BelayTalk.xcodeproj` in Xcode and build. No package dependencies to resolve.

## Safety Disclaimer

> This app is a communication aid only. Standard climbing checks, rope signals, and visual confirmation remain primary. Do not rely on BelayTalk as a safety device.

## License

MIT License — see [LICENSE](LICENSE)
