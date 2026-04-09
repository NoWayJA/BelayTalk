import Foundation
import os

/// Reorder buffer for incoming audio frames.
///
/// Buffers frames by sequence number to smooth out network jitter.
/// Default depth: 60ms (3 frames at 20ms). Adaptive range: 40-120ms.
/// Max buffer cap prevents unbounded accumulation.
nonisolated final class JitterBuffer: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    /// Absolute maximum frames in the buffer. Beyond this we skip ahead.
    private static let maxBufferSize = 15  // 300ms — well beyond max jitter depth

    private struct State {
        var buffer: [UInt32: Data] = [:]
        var nextExpectedSeq: UInt32 = 0
        var depthFrames: Int = 2
        var minDepth: Int = 2   // 40ms
        var maxDepth: Int = 6   // 120ms
        var latePackets: UInt64 = 0
        var initialized = false
        var highestInsertedSeq: UInt32 = 0
    }

    /// Insert a frame into the buffer. Returns true if accepted, false if late/duplicate.
    func insert(sequenceNumber: UInt32, payload: Data) -> Bool {
        lock.withLock { state in
            if !state.initialized {
                state.nextExpectedSeq = sequenceNumber
                state.highestInsertedSeq = sequenceNumber
                state.initialized = true
            }

            // Drop late packets using signed distance for UInt32 wrap-around safety
            let distance = Int32(bitPattern: sequenceNumber &- state.nextExpectedSeq)
            if distance < 0 {
                state.latePackets += 1
                return false
            }

            // Drop duplicates
            if state.buffer[sequenceNumber] != nil {
                return false
            }

            state.buffer[sequenceNumber] = payload

            // Track highest inserted sequence for skip-ahead
            let highDist = Int32(bitPattern: sequenceNumber &- state.highestInsertedSeq)
            if highDist > 0 {
                state.highestInsertedSeq = sequenceNumber
            }

            // Cap buffer size: if too many frames accumulated, skip ahead
            if state.buffer.count > Self.maxBufferSize {
                skipAhead(&state)
            }

            return true
        }
    }

    /// Pull the next frame in sequence order. Returns nil if not yet available.
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

    /// Skip ahead to near the latest frame, discarding stale data.
    private func skipAhead(_ state: inout State) {
        // Jump nextExpectedSeq to (highestInserted - depthFrames) so we keep
        // only the most recent frames in the buffer
        let target = state.highestInsertedSeq &- UInt32(state.depthFrames)
        state.nextExpectedSeq = target

        // Remove all frames older than the new expected sequence
        let keysToRemove = state.buffer.keys.filter { key in
            Int32(bitPattern: key &- target) < 0
        }
        for key in keysToRemove {
            state.buffer.removeValue(forKey: key)
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
            state.highestInsertedSeq = 0
            state.depthFrames = 2
            state.latePackets = 0
            state.initialized = false
        }
    }
}
