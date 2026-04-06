import OSLog

/// Centralized loggers for each subsystem
nonisolated enum Log {
    private static let subsystem = "com.belaytalk"

    static let session   = Logger(subsystem: subsystem, category: "session")
    static let transport = Logger(subsystem: subsystem, category: "transport")
    static let audio     = Logger(subsystem: subsystem, category: "audio")
    static let vad       = Logger(subsystem: subsystem, category: "vad")
    static let route     = Logger(subsystem: subsystem, category: "route")
    static let remote    = Logger(subsystem: subsystem, category: "remote")
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
}
