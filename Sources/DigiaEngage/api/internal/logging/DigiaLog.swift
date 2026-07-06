import Foundation

/// Central SDK logger — the iOS mirror of Android's `Logger`. A single global
/// level (default `.error`) gates every SDK log line; `configure(_:)` sets it
/// from `DigiaConfig` at init. Named `DigiaLog` rather than `Logger` to avoid
/// colliding with `os.Logger`, which the module already imports elsewhere.
///
/// Deliberately tiny: developer-facing debug output routed through `print`,
/// matching the SDK's existing logging style.
enum DigiaLog {
    private static let defaultTag = "Digia"

    /// The active level. Written once from the main actor at `initialize`, then
    /// read from many contexts — the same "configure early, read-mostly"
    /// contract as Android's `@Volatile var level`.
    nonisolated(unsafe) static var level: DigiaLogLevel = .error

    static func configure(_ logLevel: DigiaLogLevel) {
        level = logLevel
    }

    /// Verbose trace. Shown only at `.verbose`.
    static func verbose(_ message: String) {
        if level == .verbose { print("\(defaultTag) \(message)") }
    }

    /// Verbose trace with an explicit tag. Shown only at `.verbose`.
    static func log(_ message: String, tag: String? = nil) {
        if level == .verbose { print("\(tag ?? defaultTag) \(message)") }
    }

    /// Verbose info with an explicit tag. Shown only at `.verbose`.
    static func info(_ message: String, tag: String? = nil) {
        if level == .verbose { print("\(tag ?? defaultTag) \(message)") }
    }

    /// Warning. Shown at `.error` and `.verbose` (i.e. whenever not `.none`).
    static func warning(_ message: String, tag: String? = nil) {
        if level != .none { print("\(tag ?? defaultTag) \(message)") }
    }

    /// Error. Shown whenever not `.none`. Mirrors Android, where `error` is a
    /// non-fatal, always-surfaced signal (Android routes it through `Log.w`).
    static func error(_ message: String, tag: String? = nil, error: Any? = nil) {
        if level != .none {
            let full = error != nil ? "\(message) — \(error!)" : message
            print("\(tag ?? defaultTag) \(full)")
        }
    }
}
