import Foundation

/// One emitted diagnostic, before any sink has decided what to do with it.
///
/// ``DigiaLogger`` builds exactly one of these per call and hands the same
/// value to every sink, so the console line, the on-device timeline and (later)
/// the dashboard stream are three projections of one stream rather than three
/// instrumentations that can drift apart.
///
/// Every field but ``severity``, ``tag``, ``message`` and ``timestamp`` is
/// optional, and they are all named — the record grows additively, which
/// matters because a sink written against an older shape must keep working.
///
/// **``message`` is console-only by projection.** A structured sink serialises
/// an explicit field list and never reads it: free text is for a developer
/// reading a console, and the moment a dashboard parses it, rewording a log
/// line becomes a wire break.
///
/// platform note: Dart's twin carries `cause` as the raw `Object?` and a
/// `StackTrace?` beside it. Here it is the exception's description, captured at
/// the call site: the record crosses isolation boundaries into sinks that may
/// run anywhere, a Swift `Error` is not `Sendable` in general, and no sink ever
/// reads anything but the text.
struct TimelineRecord: Sendable {
    /// When it was emitted. Rendered as wall-clock time on the screen; the
    /// console has no timestamp of its own because Console.app and logcat stamp
    /// every line already.
    let timestamp: Date

    /// How loud it is. The console's gate compares this against the configured
    /// ``DigiaLogLevel``; no other sink looks at it.
    let severity: DigiaLogSeverity

    /// The emitting module's prefix — `DIGIA`, `DIGIA-ANALYTICS`, `DIGIA-CT`.
    let tag: String

    /// The developer-facing sentence. Console-only, per the type doc.
    let message: String

    /// The promotion gate. Non-nil means a campaign creator may see this
    /// record; nil means it is developer logging and never leaves the console.
    let stage: TimelineStage?

    /// Why, as a pinned symbol — a ``DropReason``, a ``DismissReason`` or a
    /// `TimelineReason`. Renderers map it to their own copy and show an
    /// unrecognised one raw.
    let reason: DiagnosticReason?

    /// The human-meaningful campaign name the author typed into the dashboard.
    /// A campaign creator reads this, never an id.
    let campaignKey: String?

    /// The core-minted delivery id. Records sharing one group into a single
    /// delivery card; records without one render as flat rows.
    let presentationId: String?

    /// The screen the app was on when this was emitted.
    ///
    /// A field rather than an entry in ``extras``, because the emitter can
    /// stamp it itself. That is the dividing line: ``extras`` carries the
    /// per-reason payload only the call site knows; anything the emitter
    /// already has — the time, the tag, the screen — is a field.
    let screenName: String?

    /// Per-reason payload: which token, which element, which count.
    ///
    /// Bounded and symbol-only — ids, keys, versions, counts. **Never user
    /// attributes and never credentials.** The buffer is readable on a device
    /// by whoever holds it, and it is the thing a support ticket screenshots.
    let extras: [String: String]

    /// The absorbed failure's description, when there was one.
    let cause: String?

    init(
        timestamp: Date,
        severity: DigiaLogSeverity,
        tag: String,
        message: String,
        stage: TimelineStage? = nil,
        reason: DiagnosticReason? = nil,
        campaignKey: String? = nil,
        presentationId: String? = nil,
        screenName: String? = nil,
        extras: [String: String] = [:],
        cause: String? = nil
    ) {
        self.timestamp = timestamp
        self.severity = severity
        self.tag = tag
        self.message = message
        self.stage = stage
        self.reason = reason
        self.campaignKey = campaignKey
        self.presentationId = presentationId
        self.screenName = screenName
        self.extras = extras
        self.cause = cause
    }

    /// The largest number of ``extras`` keys a record keeps.
    static let maxExtras = 8

    /// The longest an ``extras`` value may be before it is truncated.
    static let maxExtraLength = 120

    /// Caps a call site's extras to the documented bounds.
    ///
    /// A diagnostic must never be the reason an app's memory grows: a single
    /// unbounded value — a whole response body, a serialised config — repeated
    /// across a full ring buffer is a leak with a log statement in front of it.
    /// Truncating is always better than dropping; the prefix is usually the
    /// identifying part.
    ///
    /// platform note: Dart keeps the first eight in insertion order. A Swift
    /// dictionary has no order, so the cap takes the eight lowest keys — same
    /// bound, and deterministic rather than arbitrary.
    static func boundExtras(_ extras: [String: String]?) -> [String: String] {
        guard let extras, !extras.isEmpty else { return [:] }
        var bounded: [String: String] = [:]
        for key in extras.keys.sorted().prefix(maxExtras) {
            let value = extras[key] ?? ""
            bounded[key] = value.count <= maxExtraLength
                ? value
                : String(value.prefix(maxExtraLength)) + "…"
        }
        return bounded
    }
}
