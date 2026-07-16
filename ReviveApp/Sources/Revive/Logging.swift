import os

/// Structured logging via os.Logger — visible in Console.app filtered by the
/// "com.edward.revive" subsystem. Preferred over print(): it's leveled
/// (info/error), low-overhead, and privacy-aware in release builds (values are
/// redacted unless explicitly marked `.public`).
extension Logger {
    static let conversion = Logger(subsystem: "com.edward.revive", category: "conversion")
}
