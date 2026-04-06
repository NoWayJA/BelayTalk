import Foundation

/// Binary serialization for audio frames and JSON for control frames.
///
/// Wire format:
/// - Audio: `[0x01] [19-byte header] [PCM payload]`
/// - Control: `[0x00] [JSON-encoded ControlFrame]`
nonisolated enum FrameSerializer {

    // MARK: - Audio Frame Encoding

    static func encodeAudioFrame(header: AudioFrameHeader, payload: Data) -> Data {
        var data = Data(capacity: 1 + AudioFrameHeader.size + payload.count)

        // Frame type byte
        data.append(FrameType.audio.rawValue)

        // Header: 19 bytes, little-endian
        var seq = header.sequenceNumber.littleEndian
        data.append(Data(bytes: &seq, count: 4))

        var ts = header.timestamp.littleEndian
        data.append(Data(bytes: &ts, count: 8))

        data.append(header.codec.rawValue)

        var sr = header.sampleRate.littleEndian
        data.append(Data(bytes: &sr, count: 2))

        var dur = header.durationMs.littleEndian
        data.append(Data(bytes: &dur, count: 2))

        data.append(header.txState)
        data.append(header.reserved)

        // Payload
        data.append(payload)

        return data
    }

    // MARK: - Audio Frame Decoding

    static func decodeAudioFrame(_ data: Data) -> (header: AudioFrameHeader, payload: Data)? {
        // Minimum: 1 (type) + 19 (header) + 2 (at least 1 sample)
        guard data.count >= 1 + AudioFrameHeader.size + 2 else { return nil }
        guard data[data.startIndex] == FrameType.audio.rawValue else { return nil }

        let headerStart = data.startIndex + 1

        let seq: UInt32 = data.readLittleEndian(at: headerStart)
        let ts: UInt64 = data.readLittleEndian(at: headerStart + 4)
        let codecByte = data[headerStart + 12]
        let sr: UInt16 = data.readLittleEndian(at: headerStart + 13)
        let dur: UInt16 = data.readLittleEndian(at: headerStart + 15)
        let txState = data[headerStart + 17]
        let reserved = data[headerStart + 18]

        guard let codec = AudioCodec(rawValue: codecByte) else { return nil }

        let header = AudioFrameHeader(
            sequenceNumber: seq,
            timestamp: ts,
            codec: codec,
            sampleRate: sr,
            durationMs: dur,
            txState: txState,
            reserved: reserved
        )

        let payloadStart = headerStart + AudioFrameHeader.size
        let payload = data[payloadStart...]

        return (header, Data(payload))
    }

    // MARK: - Control Frame Encoding

    static func encodeControlFrame(_ frame: ControlFrame) -> Data? {
        guard var json = try? JSONEncoder().encode(frame) else { return nil }
        json.insert(FrameType.control.rawValue, at: 0)
        return json
    }

    // MARK: - Control Frame Decoding

    static func decodeControlFrame(_ data: Data) -> ControlFrame? {
        guard data.count > 1 else { return nil }
        guard data[data.startIndex] == FrameType.control.rawValue else { return nil }
        let json = data[(data.startIndex + 1)...]
        return try? JSONDecoder().decode(ControlFrame.self, from: json)
    }

    // MARK: - Dispatch

    /// Determine frame type from the first byte
    static func frameType(of data: Data) -> FrameType? {
        guard let first = data.first else { return nil }
        return FrameType(rawValue: first)
    }
}

// MARK: - Data Helpers

nonisolated private extension Data {
    func readLittleEndian<T: FixedWidthInteger>(at offset: Index) -> T {
        let size = MemoryLayout<T>.size
        guard offset + size <= endIndex else { return 0 }
        var value: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { dest in
            copyBytes(to: dest, from: offset..<(offset + size))
        }
        return T(littleEndian: value)
    }
}
