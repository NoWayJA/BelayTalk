# BelayTalk — iOS Offline Climbing Intercom

**Product & Technical Specification (Markdown)**

---

## 1. Product Definition

### 1.1 Objective

Provide low-latency, offline, two-person voice communication between climber and belayer using iPhones and standard Bluetooth headsets.

### 1.2 Core Setup

* 2 × iPhones
* 2 × Bluetooth headsets (1 per user)
* No internet / mobile signal required
* Range: ~40m line of sight

### 1.3 Safety Disclaimer

> This app is a communication aid only. Standard climbing checks, rope signals, and visual confirmation remain primary.

---

## 2. Scope

### In Scope (v1)

* 2-person sessions only
* Offline peer-to-peer connection
* Bluetooth headset support
* Built-in mic/speaker fallback
* Open Mic mode
* Voice-activated transmit (VAD)
* Manual TX toggle
* Headset button support (best effort)
* Auto reconnect
* Background (audio mode)
* Diagnostics + export

### Out of Scope

* Group calls
* Apple Watch
* Android
* Recording by default
* Mesh networking
* Multiple headsets per phone

---

## 3. Tech Stack

### Language

* Swift

### Frameworks

* SwiftUI
* AVFoundation / AVFAudio
* MultipeerConnectivity
* MediaPlayer
* OSLog / Logger

### Deployment

* iOS 17+

---

## 4. Architecture

### Modules

* App UI
* Session Coordinator
* Peer Transport
* Audio Engine
* Voice Activity Detector
* Remote Control Handler
* Route Manager
* Persistence
* Diagnostics
* Recovery Supervisor

---

## 5. Core Design

### Transport

* Multipeer Connectivity

### Audio Config

```swift
category: .playAndRecord
mode: .voiceChat
```

### Principles

* Deterministic
* Simple
* Recoverable
* No hacks relying on undefined Bluetooth behaviour

---

## 6. Features

### Modes

#### Open Mic

* Continuous TX + RX

#### Voice TX (Default)

* RX always on
* TX gated by VAD

#### Manual TX

* RX always on
* TX toggled manually

---

### Headset Control

* Single tap → toggle TX (if supported)
* Fallback to UI if unsupported

---

### Pairing Flow

1. Host session
2. Join session
3. Select peer
4. Accept
5. Handshake
6. Ready → Active

---

### Reconnect

* Auto retry
* Resume previous state
* Graceful fallback on route loss

---

## 7. Functional Requirements

### Discovery

* Advertise via Multipeer
* Browse nearby sessions
* Max 1 active peer
* Reject third connections

---

### Permissions

* Microphone
* Local Network

---

### Audio Routing

* Bluetooth headset preferred
* Fallback to speaker
* Must detect route changes

---

### Voice Processing

* Enable echo cancellation
* Mono audio
* Voice-optimised processing

---

### VAD Settings

* Sensitivity: Low / Normal / High
* Hang time: 250 / 500 / 1000 ms
* Wind rejection: Off / Normal / Strong

---

### Manual TX

* On-screen toggle
* Headset button (best effort)

---

### Background

* Continue in lock screen
* Requires audio background mode
* Silence buffer keep-alive: AudioEngine schedules zero-filled buffers when no peer audio is available, ensuring iOS keeps the app alive during screen lock
* Scene phase monitoring: app detects background/foreground transitions and re-activates audio session if interrupted while backgrounded

---

### Interruptions

* Pause on interruption
* Resume if possible

---

## 8. Performance Targets

| Metric         | Target                     |
| -------------- | -------------------------- |
| Latency        | <150ms (ideal), <250ms max |
| Range          | 40m LOS                    |
| Reconnect      | <5s                        |
| Route recovery | <3s                        |
| Battery        | 4h (open mic), 6h (VAD)    |

---

## 9. Protocol

### Frame Types

* Control
* Audio

---

### Handshake

```
HELLO → HELLO_ACK → CAPS → READY → START
```

---

### Control Messages

* TX_ON / TX_OFF
* MODE_CHANGE
* ROUTE_CHANGED
* PING / PONG
* RECONNECTING
* END_SESSION

---

### Audio Frame

```
sequenceNumber
timestamp
codec
sampleRate
duration
txState
payload
```

---

## 10. Audio Pipeline

### Recommended

* Mono
* 16 kHz
* 20 ms frames

### Codec

* v1: PCM
* v2: Opus (preferred)

---

### Jitter Buffer

* Default: 60 ms
* Adaptive: 40–120 ms

---

### Packet Loss

* Drop late packets
* Repeat last frame / silence fill

---

## 11. State Machines

### Session States

```
Idle
Permissions
Ready
Connecting
Active
Reconnecting
Interrupted
RouteFailed
Ended
```

---

### TX States

```
Disabled
Armed
Live
HoldOpen
Muted
```

---

### Route States

```
Bluetooth
BuiltIn
Wired
Changing
Unavailable
```

---

## 12. UI

### Home

* Host
* Join
* Settings
* Diagnostics

---

### Session Screen

* Peer name
* Connection status
* TX state (large)
* Mode selector
* TX button
* Route indicator

---

### Colours

* Green = OK
* Amber = degraded
* Red = failure

---

## 13. Diagnostics

### Logging

* lifecycle
* audio
* transport
* VAD
* errors

---

### Metrics

* RTT
* packet loss
* reconnect count
* session duration

---

### Export

* JSON
* readable report

---

## 14. Error Handling

| Error            | Message                |
| ---------------- | ---------------------- |
| Mic denied       | Enable mic in Settings |
| Network denied   | Enable Local Network   |
| Headset lost     | Reconnect headset      |
| Peer lost        | Reconnecting           |
| Version mismatch | Update app             |

---

## 15. Privacy

* No accounts
* No analytics (v1)
* No recording by default
* No location tracking
* Local-only data

---

## 16. Code Structure

```
App/
UI/
Session/
Transport/
Audio/
VAD/
RemoteControl/
Diagnostics/
Persistence/
```

---

## 17. QA Plan

### Devices

* 4+ iPhones
* 5+ headset types

---

### Tests

* Pairing
* Reconnect
* Lock screen
* Interruptions
* Headset disconnect
* VAD in wind
* 2h continuous session

---

### Field Testing

* Indoor gym
* Outdoor crag
* 10m / 20m / 40m
* Obstructed line

---

## 18. Defaults

* Mode: Voice TX
* Sensitivity: Normal
* Hang time: 500ms
* Auto resume: On
* Speaker fallback: Off
* Prevent auto-lock: Off

---

## 19. Risks

### High Risk

* Bluetooth button inconsistency
* Route changes
* VAD in wind
* Multipeer edge cases

### Mitigation

* Compatibility matrix
* Strong logging
* Outdoor testing early
* Voice TX as primary mode

---

## 20. Final Recommendation

Ship a **tight, reliable v1**:

* Swift-native
* Multipeer Connectivity
* Voice TX as default
* Strong route handling
* Excellent diagnostics

---


