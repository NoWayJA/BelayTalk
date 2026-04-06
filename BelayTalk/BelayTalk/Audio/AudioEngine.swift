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

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())
    private struct State {
        var sequenceNumber: UInt32 = 0
        var isRunning = false
        var isMuted = false
        var playbackTimer: DispatchSourceTimer?
    }

    weak var delegate: AudioEngineDelegate?

    // MARK: - Start / Stop

    func start() throws {
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

        lock.withLock { $0.isRunning = true }
        startPlaybackPump()

        Log.audio.info("AudioEngine started (hardware: \(hardwareFormat.sampleRate)Hz)")
    }

    func stop() {
        lock.withLock { state in
            state.isRunning = false
            state.playbackTimer?.cancel()
            state.playbackTimer = nil
        }

        engine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        engine.stop()
        jitterBuffer.reset()

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
            // Rare: hardware already at 16kHz but wrong format
            guard let converted = AudioFormatConverter.convertSampleRate(
                from: buffer,
                to: AudioConstants.processingFormat
            ) else { return }
            processBuffer = converted
        } else {
            processBuffer = buffer
        }

        // Convert Float32 → Int16 wire data
        guard let wireData = AudioFormatConverter.float32ToInt16Data(processBuffer) else { return }

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

        if let wireData = jitterBuffer.pull() {
            // Convert Int16 wire data → Float32 for playback
            if let playBuffer = AudioFormatConverter.int16DataToFloat32(wireData) {
                playerNode.scheduleBuffer(playBuffer)
            }
        } else {
            // Silence fill — schedule silence buffer to keep pipeline running
            if let silence = AudioFormatConverter.silenceBuffer() {
                playerNode.scheduleBuffer(silence)
            }
        }
    }
}
