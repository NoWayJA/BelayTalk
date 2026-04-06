import Foundation

/// Fixed-size generic ring buffer for energy history tracking.
/// Nonisolated so it can be used inside lock closures from any context.
nonisolated struct RingBuffer<Element: Numeric>: Sendable where Element: Sendable {
    private var storage: [Element]
    private var writeIndex = 0
    private var isFull = false

    let capacity: Int

    init(capacity: Int, defaultValue: Element = .zero) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.storage = Array(repeating: defaultValue, count: capacity)
    }

    /// Append a value, overwriting the oldest if full.
    mutating func append(_ value: Element) {
        storage[writeIndex] = value
        writeIndex = (writeIndex + 1) % capacity
        if writeIndex == 0 { isFull = true }
    }

    /// Number of valid elements in the buffer.
    var count: Int {
        isFull ? capacity : writeIndex
    }

    /// All valid elements in order from oldest to newest.
    var elements: [Element] {
        if isFull {
            return Array(storage[writeIndex...]) + Array(storage[..<writeIndex])
        }
        return Array(storage[..<writeIndex])
    }

    mutating func reset(defaultValue: Element = .zero) {
        storage = Array(repeating: defaultValue, count: capacity)
        writeIndex = 0
        isFull = false
    }
}
