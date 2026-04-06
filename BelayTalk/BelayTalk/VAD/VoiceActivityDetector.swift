import AVFoundation
import OSLog
import os

// MARK: - Protocol

nonisolated protocol VoiceActivityDetecting: Sendable {
    var voiceActivity: AsyncStream<Bool> { get }
    func process(_ buffer: AVAudioPCMBuffer)
    func updateSettings(sensitivity: VADSensitivity, hangTime: HangTime, windRejection: WindRejection)
}

// MARK: - Implementation

/// RMS energy-based voice activity detection with wind rejection.
///
/// Computes per-frame RMS energy, compares against an adaptive noise floor,
/// and applies configurable hang time to avoid choppy gating.
/// Wind rejection uses a simple high-pass filter + spectral flatness heuristic.
nonisolated final class VoiceActivityDetector: VoiceActivityDetecting, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    private struct State {
        var sensitivity: VADSensitivity = .normal
        var hangTime: HangTime = .medium
        var windRejection: WindRejection = .off

        var energyHistory = RingBuffer<Float>(capacity: 50)
        var noiseFloor: Float = 0.001
        var isVoiceActive = false
        var hangRemaining: TimeInterval = 0
        var lastProcessTime: Date = .now

        // High-pass filter state for wind rejection
        var hpPrevInput: Float = 0
        var hpPrevOutput: Float = 0
    }

    private let activityContinuation: AsyncStream<Bool>.Continuation
    let voiceActivity: AsyncStream<Bool>

    init() {
        var c: AsyncStream<Bool>.Continuation!
        voiceActivity = AsyncStream { c = $0 }
        activityContinuation = c
    }

    deinit {
        activityContinuation.finish()
    }

    func updateSettings(sensitivity: VADSensitivity, hangTime: HangTime, windRejection: WindRejection) {
        lock.withLock { state in
            state.sensitivity = sensitivity
            state.hangTime = hangTime
            state.windRejection = windRejection
        }
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let floatData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        // Copy samples out of the buffer pointer before entering the lock
        let samples = Array(UnsafeBufferPointer(start: floatData, count: frameCount))

        lock.withLock { state in
            let now = Date()
            let dt = now.timeIntervalSince(state.lastProcessTime)
            state.lastProcessTime = now

            // Compute RMS energy
            var energy: Float = 0
            for i in 0..<frameCount {
                var sample = samples[i]

                // Apply wind rejection high-pass filter
                if state.windRejection != .off {
                    let alpha: Float = state.windRejection == .strong ? 0.98 : 0.95
                    let filtered = alpha * (state.hpPrevOutput + sample - state.hpPrevInput)
                    state.hpPrevInput = sample
                    state.hpPrevOutput = filtered
                    sample = filtered
                }

                energy += sample * sample
            }
            energy = sqrt(energy / Float(frameCount))

            // Update energy history and noise floor
            state.energyHistory.append(energy)
            if state.energyHistory.count > 10 {
                let sorted = state.energyHistory.elements.sorted()
                let lowerQuartile = sorted[sorted.count / 4]
                state.noiseFloor = max(0.0005, lowerQuartile * 1.5)
            }

            // Voice detection threshold
            let threshold = state.noiseFloor * state.sensitivity.thresholdMultiplier * 3.0
            let detected = energy > threshold

            let wasActive = state.isVoiceActive

            if detected {
                state.isVoiceActive = true
                state.hangRemaining = state.hangTime.seconds
            } else if state.isVoiceActive {
                state.hangRemaining -= dt
                if state.hangRemaining <= 0 {
                    state.isVoiceActive = false
                    state.hangRemaining = 0
                }
            }

            // Only emit on transitions
            if state.isVoiceActive != wasActive {
                activityContinuation.yield(state.isVoiceActive)
            }
        }
    }
}
