import Foundation
import os

/// Reorder buffer for incoming audio frames.
///
/// Buffers frames by sequence number to smooth out network jitter.
/// Default depth: 60ms (3 frames at 20ms). Adaptive range: 40-120ms.
nonisolated final class JitterBuffer: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    private struct State {
        var buffer: [UInt32: Data] = [:]
        var nextExpectedSeq: UInt32 = 0
        var depthFrames: Int = 3
        var minDepth: Int = 2   // 40ms
        var maxDepth: Int = 6   // 120ms
        var latePackets: UInt64 = 0
        var initialized = false
    }

    /// Insert a frame into the buffer. Returns true if accepted, false if late/duplicate.
    func insert(sequenceNumber: UInt32, payload: Data) -> Bool {
        lock.withLock { state in
            if !state.initialized {
                state.nextExpectedSeq = sequenceNumber
                state.initialized = true
            }

            // Drop late packets (sequence number < next expected)
            if sequenceNumber < state.nextExpectedSeq {
                state.latePackets += 1
                return false
            }

            // Drop duplicates
            if state.buffer[sequenceNumber] != nil {
                return false
            }

            state.buffer[sequenceNumber] = payload
            return true
        }
    }

    /// Pull the next frame in sequence order. Returns nil if not yet available (silence fill).
    func pull() -> Data? {
        lock.withLock { state in
            guard state.initialized else { return nil }

            // Wait until we have enough buffered frames
            if state.buffer.count < state.depthFrames {
                return nil
            }

            let seq = state.nextExpectedSeq
            state.nextExpectedSeq = seq &+ 1

            if let frame = state.buffer.removeValue(forKey: seq) {
                return frame
            }

            // Missing frame — caller should fill with silence
            return nil
        }
    }

    /// Adapt buffer depth based on observed jitter
    func adaptDepth(jitterMs: Double) {
        lock.withLock { state in
            let frameDuration = Double(AudioConstants.frameDurationMs)
            let idealFrames = max(
                state.minDepth,
                min(state.maxDepth, Int(ceil(jitterMs / frameDuration)))
            )
            state.depthFrames = idealFrames
        }
    }

    var latePacketCount: UInt64 {
        lock.withLock { $0.latePackets }
    }

    var currentDepthFrames: Int {
        lock.withLock { $0.depthFrames }
    }

    func reset() {
        lock.withLock { state in
            state.buffer.removeAll()
            state.nextExpectedSeq = 0
            state.depthFrames = 3
            state.latePackets = 0
            state.initialized = false
        }
    }
}
