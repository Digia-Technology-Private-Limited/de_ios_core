/// How loud one log line is.
///
/// Separate from ``DigiaLogLevel``, which is the *threshold* a host app
/// configures. A line is emitted when its severity is at or above the
/// configured level — see ``DigiaLogger``.
///
/// The four names are a cross-stack contract: Kotlin's `Logger`, Dart's
/// `DigiaLogger` and the RN console sink expose the same ladder, and the
/// diagnostics spec makes it the `severity` field of the structured record.
/// Renaming one here renames it in four places.
enum DigiaLogSeverity: Sendable {
    /// The SDK could not do the thing: a campaign dropped, an action failed, an
    /// invariant violated. Visible at every level except ``DigiaLogLevel/none``.
    case error

    /// Degraded but recovered: a field fell back to a default, a retry
    /// succeeded.
    case warn

    /// Lifecycle milestones: init complete, N campaigns loaded, trigger
    /// received.
    case info

    /// Per-node, per-frame, per-request detail.
    case debug

    /// Verbosity rank — higher is chattier. Compared against the configured
    /// level's rank, never against a raw enum ordinal.
    var rank: Int {
        switch self {
        case .error: return 0
        case .warn: return 1
        case .info: return 2
        case .debug: return 3
        }
    }

    /// The uppercase word in the line's `[<LEVEL>]` bracket. Spelled out rather
    /// than derived, because it is part of the frozen console prefix.
    var label: String {
        switch self {
        case .error: return "ERROR"
        case .warn: return "WARN"
        case .info: return "INFO"
        case .debug: return "DEBUG"
        }
    }

    /// The glyph every line of this severity leads with, so severity reads as a
    /// traffic light before it reads as a word.
    ///
    /// Coloured circles rather than semantic glyphs (❌ / ⚠️ / ℹ️ / 🔍)
    /// deliberately: these four are uniform-width, so the tag column stays
    /// aligned down a page of output, and ⚠️ / ℹ️ carry Unicode variant
    /// selectors that some terminals render as narrow monochrome text — which
    /// loses both the colour cue and the alignment.
    ///
    /// Display only: filtering and grep key on `DIGIA` and `[<LEVEL>]`, never
    /// on this. It is part of the frozen prefix all the same — keep the glyphs
    /// stable once shipped.
    var badge: String {
        switch self {
        case .error: return "🔴"
        case .warn: return "🟡"
        case .info: return "🔵"
        case .debug: return "⚪"
        }
    }
}
