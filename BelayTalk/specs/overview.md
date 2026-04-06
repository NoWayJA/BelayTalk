Below is a **“Comprehensive Description: What We’re Building & Why”** section you can prepend to the spec (or include in README / PRD). It’s written to work for:

* engineers (clarity of constraints)
* designers (mental model)
* stakeholders (value)
* QA (intent behind behaviours)

---

# BelayTalk — What We’re Building & Why

---

## 1. The Core Problem

Rock climbing communication is deceptively fragile.

Even when two people are:

* within 40 metres
* in line of sight
* experienced

…communication often fails due to:

* wind
* rope drag noise
* helmets obstructing hearing
* distance distortion
* environmental echo (indoor walls, crags)
* mismatched expectations (“take”, “slack”, “watch me”)

This creates **ambiguity at moments where clarity matters**.

Climbers already mitigate this using:

* predefined verbal commands
* rope signals
* visual checks

But these systems:

* degrade with distance and noise
* are not continuous
* require deliberate signalling
* can be misinterpreted under stress

---

## 2. The Insight

Climbing doesn’t need a *walkie-talkie*.
It needs a **persistent, low-friction shared audio space**.

Something closer to:

* being next to your partner
* hearing tone, hesitation, breath
* speaking naturally without ritual

The goal is not “communication on demand”
→ it is **continuous situational awareness through sound**

---

## 3. The Product Vision

BelayTalk creates a **private, local, always-available audio channel between two climbers**.

It should feel like:

> “we are still connected, even when we are apart”

Not:

* a call you start
* a button you hold
* a device you manage

But:

* a **presence**

---

## 4. Design Philosophy

### 4.1 Invisible Infrastructure

The system should disappear into the activity.

* No setup complexity
* No fiddling mid-climb
* No dependency on signal or cloud
* No cognitive load

If it works perfectly, the user forgets it exists.

---

### 4.2 Hands-Free First

Climbers cannot reliably:

* look at screens
* press buttons
* hold devices

Therefore:

* **voice activation is primary**
* **manual controls are fallback**

---

### 4.3 Always Listening, Selectively Speaking

Key asymmetry:

* **Receive (RX): always on**
* **Transmit (TX): controlled**

Why:

* hearing your partner is always useful
* transmitting constantly is noisy, battery-heavy, and unnecessary

This leads to the core modes:

* Open Mic (simple but noisy)
* Voice TX (default)
* Manual TX (fallback)

---

### 4.4 Resilience Over Features

This is not a feature-rich app.

It is a **high-reliability, single-purpose tool**.

Tradeoffs:

* Fewer features
* More robustness
* Aggressive error handling
* Clear fallback behaviour

---

### 4.5 Local-First by Design

The environment:

* often has no signal
* should not depend on infrastructure

Therefore:

* no servers
* no accounts
* no internet dependency

This is both:

* a technical constraint
* a privacy feature

---

## 5. Why iPhones + Bluetooth Headsets

This is a deliberate constraint, not a limitation.

We are leveraging:

* devices users already own
* familiar interaction patterns
* proven audio hardware
* safe battery and radio systems

Rather than:

* building new hardware
* requiring specialised gear
* increasing friction to adoption

---

## 6. Why Not Walkie-Talkie Behaviour

Traditional walkie-talkies:

* are push-to-talk
* enforce turn-taking
* interrupt flow
* require hands

This is fundamentally incompatible with climbing.

BelayTalk instead aims for:

| Behaviour      | Walkie-Talkie | BelayTalk       |
| -------------- | ------------- | --------------- |
| Transmission   | Manual        | Automatic (VAD) |
| Listening      | Intermittent  | Continuous      |
| Cognitive load | High          | Low             |
| Flow           | Interrupted   | Natural         |

---

## 7. What “Good” Feels Like

A successful session should feel like:

* you hear your partner breathing, reacting, thinking
* you can speak naturally without pressing anything
* you forget distance exists
* you trust what you hear
* the system recovers without intervention

A bad system would:

* drop out silently
* require interaction mid-climb
* introduce latency that breaks timing
* amplify noise instead of filtering it

---

## 8. Core Technical Truths Driving Design

### 8.1 Bluetooth is not peer-to-peer voice

Bluetooth headsets:

* expect a phone
* do not naturally form intercoms

Therefore:

* each user needs a phone
* phones handle audio + routing
* phones connect to each other

---

### 8.2 iOS prioritises stability over flexibility

iOS:

* tightly controls audio routing
* limits background execution
* enforces permission boundaries

So we:

* use official APIs only
* avoid hacks
* design around constraints, not against them

---

### 8.3 Audio is harder than networking

Most failure cases are not:

* “connection failed”

They are:

* route changed unexpectedly
* headset disconnected
* audio engine stopped
* interruption not handled correctly

Therefore:

* audio state management is the most critical subsystem

---

### 8.4 Real-world noise is adversarial

Climbing environments include:

* wind
* fabric noise
* metal gear
* echo

So:

* VAD must be conservative
* false positives are worse than missed speech
* tuning must be field-tested, not simulated

---

## 9. Safety Philosophy

BelayTalk is **non-critical augmentation**, not replacement.

It must:

* never override standard safety practices
* never create dependency
* never imply reliability beyond reality

The correct mental model:

> “If it disappears, climbing still works.”

---

## 10. Success Criteria

We succeed if:

* users forget they are using it
* conversations feel natural
* reconnects are invisible
* no one reaches for their phone mid-climb
* the system behaves predictably under stress

We fail if:

* users hesitate to trust it
* interaction is required at critical moments
* audio behaviour is inconsistent
* setup feels like work

---

## 11. Why This Matters (Beyond Climbing)

This is a prototype of a broader category:

**Local, ephemeral, peer-to-peer presence systems**

Potential future domains:

* skiing
* cycling
* construction teams
* field work
* search & rescue

But climbing is the perfect starting point because:

* constraints are strict
* users are attentive
* failure modes are obvious
* feedback is immediate

---

## 12. Final Summary

We are not building:

* a call app
* a walkie-talkie
* a social product

We are building:

> a **low-latency, offline, hands-free shared audio channel**
> that restores natural communication between two people in a physically separated environment.

---
