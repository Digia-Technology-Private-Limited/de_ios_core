import Foundation
import os

/// Sink #1: the developer's console.
///
/// The format is frozen. It is the entire retrieval story: a developer filters
/// Console.app or the Xcode console for `DIGIA` and pastes the result into a
/// ticket, so rewording the prefix silently breaks every support instruction
/// that has ever been written down.
///
/// ```
/// <badge> [<TAG>] [<LEVEL>]: [<campaignKey>] <Message> (key=value, key=value)
/// ```
///
/// **Transport is `os.Logger`, not `print`.** `print` is untagged at the OS
/// level, so a developer cannot filter it apart from their own app's output.
/// Core's deployment floor is iOS 15, so `os.Logger` is unconditionally
/// available and there is no fallback path.
///
/// Two `os_log` details this depends on:
///
/// - **Interpolated values are redacted by default.** Anything dynamic renders
///   as `<private>` on a real device — which is exactly where the logs matter —
///   unless it is marked `privacy: .public`. Redaction is governed at the call
///   site instead (the diagnostics spec's denylist), so the whole line is
///   marked public here.
/// - **Transport uses `.default` for info/debug/warn** so that log streaming
///   tools (like `npx expo run:ios` and `xcrun simctl log stream`) capture and
///   display permitted logs in the terminal without dropping them. Gating is
///   governed upstream by `DigiaLogger.isSeverityEnabled`.
final class ConsoleSink: DiagnosticSink {
    /// Creates the console sink.
    ///
    /// `isEnabled` is injected rather than read off ``DigiaLogger`` so the two
    /// have no reference cycle and this sink's gate can be driven directly in a
    /// test. It is the *only* gate here: severity, never
    /// ``TimelineRecord/stage``.
    init(_ isEnabled: @escaping @Sendable (DigiaLogSeverity) -> Bool) {
        self.isEnabled = isEnabled
    }

    /// The configured-verbosity predicate.
    private let isEnabled: @Sendable (DigiaLogSeverity) -> Bool

    func accepts(_ record: TimelineRecord) -> Bool { isEnabled(record.severity) }

    func emit(_ record: TimelineRecord) {
        let logger = Self.logger(for: record.tag)
        let level = Self.osLevel(record.severity)
        for line in Self.lines(for: record) {
            logger.log(level: level, "\(line, privacy: .public)")
        }
    }

    /// The exact console lines `record` renders as — one per line of its
    /// message, each carrying the whole prefix.
    ///
    /// Pure, so the frozen format is pinned by a test rather than by reading
    /// `os_log` output. A console filtered on `DIGIA` — Console.app, Xcode —
    /// keeps only the lines that match it, so a multi-line message would
    /// otherwise survive only its first line, and a filter on one campaign
    /// would lose the rest of that campaign's own thread.
    static func lines(for record: TimelineRecord) -> [String] {
        let slot = record.campaignKey.map { " [\($0)]" } ?? ""
        let head = "\(record.severity.badge) [\(record.tag)] [\(record.severity.label)]:\(slot)"
        var body = record.message
        if let cause = record.cause { body += " cause=\(cause)" }
        return body.components(separatedBy: "\n").map { "\(head) \($0)" }
    }

    /// Severity onto `os_log`'s ladder.
    ///
    /// `.error` maps to `OSLogType.error`. All other permitted levels (`.warn`,
    /// `.info`, `.debug`) map to `OSLogType.default` so that CLI runners
    /// (such as Expo CLI's `log stream` or terminal simulators) stream them
    /// without requiring explicit `--level info` or `--level debug` flags.
    /// Gating is performed upstream by `isEnabled(record.severity)`.
    private static func osLevel(_ severity: DigiaLogSeverity) -> OSLogType {
        switch severity {
        case .error: return .error
        case .warn, .info, .debug: return .default
        }
    }

    /// One `os.Logger` per tag, so Console.app's category column is the same
    /// six-value set the printed prefix is. Cached because the tag set is
    /// closed and `emit` runs per line.
    private static func logger(for tag: String) -> os.Logger {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let existing = cache[tag] { return existing }
        let created = os.Logger(subsystem: "tech.digia.engage", category: tag)
        cache[tag] = created
        return created
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: os.Logger] = [:]
}
