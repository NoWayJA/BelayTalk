import Foundation
import UIKit

// MARK: - VAD Sensitivity

nonisolated enum VADSensitivity: String, Codable, CaseIterable, Sendable {
    case low
    case normal
    case high

    var label: String {
        switch self {
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        }
    }

    /// RMS energy threshold multiplier (lower = more sensitive)
    var thresholdMultiplier: Float {
        switch self {
        case .low: 1.5
        case .normal: 1.0
        case .high: 0.6
        }
    }
}

// MARK: - Hang Time

nonisolated enum HangTime: Int, Codable, CaseIterable, Sendable {
    case short  = 250
    case medium = 500
    case long   = 1000

    var label: String {
        switch self {
        case .short: "250ms"
        case .medium: "500ms"
        case .long: "1000ms"
        }
    }

    var seconds: TimeInterval {
        TimeInterval(rawValue) / 1000.0
    }
}

// MARK: - Wind Rejection

nonisolated enum WindRejection: String, Codable, CaseIterable, Sendable {
    case off
    case normal
    case strong

    var label: String {
        switch self {
        case .off: "Off"
        case .normal: "Normal"
        case .strong: "Strong"
        }
    }
}

// MARK: - App Settings

/// User-configurable settings persisted to UserDefaults.
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var displayName: String {
        didSet { defaults.set(displayName, forKey: Keys.displayName) }
    }

    var txMode: TXMode {
        didSet { defaults.set(txMode.rawValue, forKey: Keys.txMode) }
    }

    var vadSensitivity: VADSensitivity {
        didSet { defaults.set(vadSensitivity.rawValue, forKey: Keys.vadSensitivity) }
    }

    var hangTime: HangTime {
        didSet { defaults.set(hangTime.rawValue, forKey: Keys.hangTime) }
    }

    var windRejection: WindRejection {
        didSet { defaults.set(windRejection.rawValue, forKey: Keys.windRejection) }
    }

    var autoResume: Bool {
        didSet { defaults.set(autoResume, forKey: Keys.autoResume) }
    }

    var speakerFallback: Bool {
        didSet { defaults.set(speakerFallback, forKey: Keys.speakerFallback) }
    }

    var preventAutoLock: Bool {
        didSet { defaults.set(preventAutoLock, forKey: Keys.preventAutoLock) }
    }

    init() {
        displayName = defaults.string(forKey: Keys.displayName) ?? UIDevice.current.name
        txMode = TXMode(rawValue: defaults.string(forKey: Keys.txMode) ?? "") ?? .voiceTX
        vadSensitivity = VADSensitivity(rawValue: defaults.string(forKey: Keys.vadSensitivity) ?? "") ?? .normal
        hangTime = HangTime(rawValue: defaults.integer(forKey: Keys.hangTime)) ?? .medium
        windRejection = WindRejection(rawValue: defaults.string(forKey: Keys.windRejection) ?? "") ?? .off
        autoResume = defaults.object(forKey: Keys.autoResume) as? Bool ?? true
        speakerFallback = defaults.object(forKey: Keys.speakerFallback) as? Bool ?? true
        preventAutoLock = defaults.object(forKey: Keys.preventAutoLock) as? Bool ?? false
    }

    private enum Keys {
        static let displayName = "displayName"
        static let txMode = "txMode"
        static let vadSensitivity = "vadSensitivity"
        static let hangTime = "hangTime"
        static let windRejection = "windRejection"
        static let autoResume = "autoResume"
        static let speakerFallback = "speakerFallback"
        static let preventAutoLock = "preventAutoLock"
    }
}
