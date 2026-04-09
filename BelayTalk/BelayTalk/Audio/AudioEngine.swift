import AVFoundation
import OSLog
import os

// MARK: - Delegate Protocol

nonisolated protocol AudioEngineDelegate: AnyObject, Sendable {
    func audioEngine(_ engine: AudioEngine, didCapture header: AudioFrameHeader, payload: Data)
}

// MARK: - Audio Engine

/// Manages AVAudioEngine for capture and playback.
///
/// - Capture: Input tap → format convert → delegate callback with header + payload
/// - Playback: Jitter buffer → player node on 20ms timer
/// - Echo cancellation via `setVoiceProcessingEnabled(true)`
/// - TX muting via `isVoiceProcessingInputMuted` (keeps pipeline warm)
nonisolated final class AudioEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let jitterBuffer = JitterBuffer()

    /// Maximum number of buffers queued on the player node to prevent unbounded latency.
    private static let maxScheduledBuffers = 2

    /// Pre-allocated silence buffer for background keep-alive.
    /// iOS suspends background audio apps that stop producing output,
    /// so we schedule this when the jitter buffer is empty.
    private let silenceBuffer: AVAudioPCMBuffer? = {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: AudioConstants.processingFormat,
            frameCapacity: AVAudioFrameCount(AudioConstants.samplesPerFrame)
        ) else { return nil }
        buffer.frameLength = buffer.frameCapacity
        // Buffer is zero-filled by default — silence
        return buffer
    }()

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())
    private struct State {
        var sequenceNumber: UInt32 = 0
        var isRunning = false
        var isMuted = false
        var playbackTimer: DispatchSourceTimer?
        var scheduledBufferCount = 0
        var residualSamples: [Float] = []
    }

    weak var delegate: AudioEngineDelegate?

    // MARK: - Start / Stop

    func start() throws {
        // Guard against double-start
        if lock.withLock({ $0.isRunning }) {
            Log.audio.warning("AudioEngine.start() called while already running — ignoring")
            return
        }

        let inputNode = engine.inputNode

        try inputNode.setVoiceProcessingEnabled(true)
        Log.audio.info("Voice processing enabled (echo cancellation + noise reduction)")

        engine.attach(playerNode)

        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        let processingFormat = AudioConstants.processingFormat

        // Connect player → main mixer for playback
        engine.connect(playerNode, to: engine.mainMixerNode, format: processingFormat)

        // Install tap on input node for capture
        inputNode.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(AudioConstants.samplesPerFrame),
            format: hardwareFormat
        ) { [weak self] buffer, _ in
            self?.handleCapturedAudio(buffer, hardwareFormat: hardwareFormat)
        }

        try engine.start()
        playerNode.play()

        lock.withLock { state in
            state.isRunning = true
            state.scheduledBufferCount = 0
            state.residualSamples.removeAll()
        }
        startPlaybackPump()

        Log.audio.info("AudioEngine started (hardware: \(hardwareFormat.sampleRate)Hz)")
    }

    func stop() {
        let timer: DispatchSourceTimer? = lock.withLock { state in
            guard state.isRunning else { return nil }
            state.isRunning = false
            let t = state.playbackTimer
            state.playbackTimer = nil
            state.scheduledBufferCount = 0
            state.residualSamples.removeAll()
            return t
        }

        // Cancel timer outside the lock, then wait a tick for any in-flight handler
        timer?.cancel()

        engine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        engine.stop()
        jitterBuffer.reset()
        AudioFormatConverter.resetConverter()

        Log.audio.info("AudioEngine stopped")
    }

    var isRunning: Bool {
        lock.withLock { $0.isRunning }
    }

    // MARK: - TX Muting

    func setMuted(_ muted: Bool) {
        lock.withLock { $0.isMuted = muted }
        engine.inputNode.isVoiceProcessingInputMuted = muted
        Log.audio.debug("TX mute: \(muted)")
    }

    // MARK: - Receive Path

    func receiveAudioFrame(sequenceNumber: UInt32, payload: Data) {
        _ = jitterBuffer.insert(sequenceNumber: sequenceNumber, payload: payload)
    }

    // MARK: - Capture Path

    private func handleCapturedAudio(
        _ buffer: AVAudioPCMBuffer,
        hardwareFormat: AVAudioFormat
    ) {
        // Skip if muted (still processing for echo cancellation state)
        if lock.withLock({ $0.isMuted }) { return }

        // Convert from hardware sample rate to 16kHz if needed
        let processBuffer: AVAudioPCMBuffer
        if hardwareFormat.sampleRate != AudioConstants.sampleRate {
            guard let converted = AudioFormatConverter.convertSampleRate(
                from: buffer,
                to: AudioConstants.processingFormat
            ) else { return }
            processBuffer = converted
        } else if hardwareFormat.commonFormat != .pcmFormatFloat32 {
            guard let converted = AudioFormatConverter.convertSampleRate(
                from: buffer,
                to: AudioConstants.processingFormat
            ) else { return }
            processBuffer = converted
        } else {
            processBuffer = buffer
        }

        guard let floatData = processBuffer.floatChannelData?[0] else { return }
        let frameCount = Int(processBuffer.frameLength)
        guard frameCount > 0 else { return }

        // Copy samples out of the buffer pointer
        let newSamples = Array(UnsafeBufferPointer(start: floatData, count: frameCount))

        // Prepend any residual samples from previous callback, then chunk into 320-sample frames
        let allSamples: [Float] = lock.withLock { state in
            let combined = state.residualSamples + newSamples
            state.residualSamples.removeAll()
            return combined
        }

        let chunkSize = AudioConstants.samplesPerFrame  // 320
        var offset = 0

        while offset + chunkSize <= allSamples.count {
            let chunk = Array(allSamples[offset..<(offset + chunkSize)])
            offset += chunkSize

            guard let wireData = float32ChunkToInt16Data(chunk) else { continue }

            let seq = lock.withLock { state -> UInt32 in
                let s = state.sequenceNumber
                state.sequenceNumber = s &+ 1
                return s
            }

            let header = AudioFrameHeader(
                sequenceNumber: seq,
                timestamp: mach_absolute_time(),
                codec: .pcmInt16,
                sampleRate: UInt16(AudioConstants.sampleRate),
                durationMs: UInt16(AudioConstants.frameDurationMs),
                txState: 0,
                reserved: 0
            )

            delegate?.audioEngine(self, didCapture: header, payload: wireData)
        }

        // Store leftover samples for the next callback
        if offset < allSamples.count {
            let residual = Array(allSamples[offset...])
            lock.withLock { $0.residualSamples = residual }
        }
    }

    /// Convert a Float32 sample array directly to Int16 wire data.
    private func float32ChunkToInt16Data(_ samples: [Float]) -> Data? {
        guard !samples.isEmpty else { return nil }
        var data = Data(count: samples.count * AudioConstants.bytesPerSample)
        data.withUnsafeMutableBytes { rawBuffer in
            guard let int16Ptr = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<samples.count {
                let clamped = max(-1.0, min(1.0, samples[i]))
                int16Ptr[i] = Int16(clamped * Float(Int16.max))
            }
        }
        return data
    }

    // MARK: - Playback Pump

    private func startPlaybackPump() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        let intervalMs = AudioConstants.frameDurationMs
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(intervalMs),
            leeway: .milliseconds(2)
        )

        timer.setEventHandler { [weak self] in
            self?.pumpPlayback()
        }

        lock.withLock { $0.playbackTimer = timer }
        timer.resume()
    }

    private func pumpPlayback() {
        guard lock.withLock({ $0.isRunning }) else { return }

        // Don't queue more buffers than the cap — prevents unbounded latency buildup
        let currentCount = lock.withLock { $0.scheduledBufferCount }
        guard currentCount < Self.maxScheduledBuffers else { return }

        let playBuffer: AVAudioPCMBuffer
        if let wireData = jitterBuffer.pull(),
           let decoded = AudioFormatConverter.int16DataToFloat32(wireData) {
            playBuffer = decoded
        } else {
            // Schedule silence to keep the audio pipeline active.
            // iOS requires continuous audio output for background execution —
            // without this, the system suspends the app when the screen locks.
            guard let silence = silenceBuffer else { return }
            playBuffer = silence
        }

        lock.withLock { $0.scheduledBufferCount += 1 }
        playerNode.scheduleBuffer(playBuffer) { [weak self] in
            self?.lock.withLock { $0.scheduledBufferCount -= 1 }
        }
    }
}
