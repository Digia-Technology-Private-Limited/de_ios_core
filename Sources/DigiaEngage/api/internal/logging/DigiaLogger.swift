import Foundation

/// The SDK's one logging style, across core and every CEP plugin.
///
/// One instance per module, held as a file-scope `let` so a call site is a
/// method call and nothing more. The tag becomes the console prefix and is the
/// whole retrieval story: a developer filters their console for `DIGIA` and
/// pastes. **Never reword the prefix**; grepping for it is the only way a
/// support ticket carries our logs.
///
/// ```
/// <badge> [<TAG>] [<LEVEL>]: [<campaignKey>] <Message> (key=value, key=value)
///
/// 🔴 [DIGIA] [ERROR]: [canvas_new_nudge] Payload parse failed
/// 🟡 [DIGIA] [WARN]: [canvas_new_nudge] Buffered trigger displaced (by=summer_sale)
/// 🔵 [DIGIA-ME] [INFO]: [canvas_new_nudge] Received (cepId=6aabbf01362b7cb5)
/// ⚪ [DIGIA] [DEBUG]: [summer_sale] Dropped — frequency capped (policy=1/day)
/// ```
///
/// The **campaign slot** is what makes same-campaign lines group vertically
/// like a thread, and `[<key>]` an unambiguous filter — grepping the bare key
/// also hits lines that merely *mention* it (`by=summer_sale`). It is a
/// parameter, never hand-written brackets, so the format cannot rot; it is
/// omitted entirely when there is no campaign (init, fetch, session, queue),
/// never rendered empty; and it is always `campaignKey`, the human-meaningful
/// name the author typed into the dashboard. `cepCampaignId` and
/// `presentationId` stay in the trailing data.
///
/// **There are exactly six tags**, and the set is closed on purpose — nine were
/// tried on Flutter first and read as noise, because the SDK is one thing to
/// the reader and sub-module detail belongs in the message when it matters:
///
/// | Tag | Written as | Covers |
/// |---|---|---|
/// | `DIGIA` | `DigiaLogger()` | everything in core that is not one of the below |
/// | `DIGIA-ANALYTICS` | `DigiaLogger("analytics")` | the first-party analytics pipeline |
/// | `DIGIA-LIVETEST` | `DigiaLogger("liveTest")` | live campaign testing |
/// | `DIGIA-CT` / `-WE` / `-ME` | in the plugin packages | the CEP boundary — the #1 support question |
///
/// Message style, so a reader can scan the left edge: outcome first, sentence
/// case (`Campaign received`, not `received campaign`); never repeat the tag's
/// module in the message; data trails in one parenthesised `key=value` group.
///
/// **One emit, many sinks.** Every call builds exactly one ``TimelineRecord``
/// and walks the sink registry; ``ConsoleSink`` renders the line above, and
/// ``ScreenSink`` records the on-device campaign timeline. Adding a destination
/// never touches a call site.
///
/// The two gates are independent, and that is the point:
///
/// | Sink | Accepts when | Who owns the knob |
/// |---|---|---|
/// | ``ConsoleSink`` | `severity` is at or above the configured ``DigiaLogLevel`` | the host developer |
/// | ``ScreenSink`` | the record carries a `TimelineStage` | us, per call site |
///
/// Each gate reads a **different field with a different owner**, which is what
/// makes escalation fail closed: forgetting one can only narrow the audience,
/// never widen it. There is deliberately no `sendTo:` parameter — per-call-site
/// routing drifts, and one mistyped flag would leak internals to a campaign
/// creator or to a backend.
///
/// So a `debug` gating drop that a release console suppresses still reaches the
/// campaign creator's screen. **Promoting a call is a deliberate act**: pass a
/// `TimelineStage` and a ``DiagnosticReason`` from a closed enum, and free-text
/// developer logging can never leak onto a non-developer's screen. The promoted
/// arguments do not change the console line — what a developer reads is the
/// message and nothing else.
///
/// Three rules the SDK's release chain makes non-negotiable, since a bad line
/// ships inside a customer app for months:
///
/// - **A log call never throws.** It runs on render paths. Every sink call is
///   caught here, so a sink cannot break the app that hosts us.
/// - **A disabled level costs nothing.** Gate an expensive *unstaged* message
///   with ``isEnabled(_:)`` rather than building it and discarding it inside.
/// - **A staged call is never wrapped in ``isEnabled(_:)``.** That guard is for
///   hot unstaged chatter only; around a staged call it silently blinds the
///   timeline in exactly the release build someone opened it to debug.
struct DigiaLogger: Sendable {
    /// Creates a logger for one module.
    ///
    /// Omit `tag` for plain `[DIGIA]` — the right answer for most of core. Pass
    /// one only for the tags in the table above; a new tag is a decision about
    /// what a developer filters for, not a detail of the file you are in.
    init(_ tag: String = "") {
        prefix = tag.isEmpty ? "DIGIA" : "DIGIA-\(tag.uppercased())"
    }

    /// The bracketed prefix: `DIGIA`, or `DIGIA-<TAG>` uppercased.
    ///
    /// Uppercased at construction rather than trusted from the call site, so a
    /// tag written in Swift's usual lowerCamelCase still renders in the
    /// fixed-width shape the column alignment depends on.
    private let prefix: String

    // MARK: - Configuration

    /// The active threshold.
    ///
    /// Static because the level is one SDK-wide setting and the CEP plugins are
    /// separate modules in the same process — they read what the host app
    /// configured on core without any wiring of their own.
    ///
    /// `nonisolated(unsafe)` carries over the "configure early, read-mostly"
    /// contract the SDK's logger has always had: written once from the main
    /// actor at `initialize`, read from every context afterwards. Until then
    /// ``DigiaLogLevel/auto`` is in force, so logs emitted during startup are
    /// not silently lost.
    nonisolated(unsafe) private static var activeLevel: DigiaLogLevel = .auto

    /// Applies the host app's configured verbosity. Called once from
    /// `Digia.initialize()`.
    static func configure(_ level: DigiaLogLevel) {
        activeLevel = level
    }

    /// The threshold currently in force.
    static var level: DigiaLogLevel { activeLevel }

    /// Where records go. These two are always present: the console decides per
    /// record whether the configured level admits it, and the timeline records
    /// regardless — see the gate table on this type.
    ///
    /// Same "configure early, read-mostly" contract as ``activeLevel``: a sink
    /// that cannot be always-on joins through ``registerSink(_:)`` during init,
    /// long before the app is doing anything interesting.
    nonisolated(unsafe) private static var sinks: [DiagnosticSink] = [
        ConsoleSink(DigiaLogger.isSeverityEnabled),
        ScreenSink.shared,
    ]

    /// Adds a sink to the registry. Idempotent, so a repeated init cannot end
    /// up emitting a record twice into the same destination.
    static func registerSink(_ sink: DiagnosticSink) {
        guard !sinks.contains(where: { $0 === sink }) else { return }
        sinks.append(sink)
    }

    /// Removes a sink. A no-op if it was never registered.
    static func unregisterSink(_ sink: DiagnosticSink) {
        sinks.removeAll { $0 === sink }
    }

    /// The screen the app is currently on, so staged records can be stamped
    /// with it without every call site passing one.
    ///
    /// Written by `Digia.setCurrentScreen()` — the SDK's single source of truth
    /// for screen scoping — and nil until the host names one.
    ///
    /// platform note: Dart holds a *closure* here and calls it per record.
    /// That is not available to us: the current screen lives on the main-actor
    /// `SDKInstance`, and records are emitted from URLSession callbacks and
    /// watchdog tasks too. Pushing the value on change instead keeps the read
    /// free and the isolation honest — same "write rarely, read often" contract
    /// as ``level``.
    nonisolated(unsafe) static var currentScreenName: String?

    /// Whether the configured level admits `severity`. The console's gate, and
    /// nothing else's.
    @Sendable
    static func isSeverityEnabled(_ severity: DigiaLogSeverity) -> Bool {
        severity.rank <= rank(of: activeLevel)
    }

    /// Whether a `severity` line would be emitted right now.
    ///
    /// Guard hot and render-path call sites with this so a release build pays
    /// nothing for a message it will not print — and never guard a *staged*
    /// call with it.
    func isEnabled(_ severity: DigiaLogSeverity) -> Bool {
        Self.isSeverityEnabled(severity)
    }

    // MARK: - Severity methods

    /// The SDK could not do the thing. Visible at every level but
    /// ``DigiaLogLevel/none``.
    ///
    /// `stage` and `reason` promote the line onto the campaign timeline; see
    /// the gate table on this type before adding them.
    func e(
        _ message: String,
        campaign: String? = nil,
        error: Any? = nil,
        stage: TimelineStage? = nil,
        reason: DiagnosticReason? = nil,
        presentationId: String? = nil,
        extras: [String: String]? = nil
    ) {
        emit(.error, message, campaign, error, stage, reason, presentationId, extras)
    }

    /// Degraded, but recovered.
    func w(
        _ message: String,
        campaign: String? = nil,
        error: Any? = nil,
        stage: TimelineStage? = nil,
        reason: DiagnosticReason? = nil,
        presentationId: String? = nil,
        extras: [String: String]? = nil
    ) {
        emit(.warn, message, campaign, error, stage, reason, presentationId, extras)
    }

    /// A lifecycle milestone.
    func i(
        _ message: String,
        campaign: String? = nil,
        stage: TimelineStage? = nil,
        reason: DiagnosticReason? = nil,
        presentationId: String? = nil,
        extras: [String: String]? = nil
    ) {
        emit(.info, message, campaign, nil, stage, reason, presentationId, extras)
    }

    /// Per-node, per-frame, per-request detail.
    func d(
        _ message: String,
        campaign: String? = nil,
        stage: TimelineStage? = nil,
        reason: DiagnosticReason? = nil,
        presentationId: String? = nil,
        extras: [String: String]? = nil
    ) {
        emit(.debug, message, campaign, nil, stage, reason, presentationId, extras)
    }

    // swiftlint:disable:next function_parameter_count
    private func emit(
        _ severity: DigiaLogSeverity,
        _ message: String,
        _ campaign: String?,
        _ error: Any?,
        _ stage: TimelineStage?,
        _ reason: DiagnosticReason?,
        _ presentationId: String?,
        _ extras: [String: String]?
    ) {
        // The one shortcut worth keeping, and the reason it is safe: a record
        // with no stage, no reason and a severity below the console threshold
        // is a record *no* sink can accept, so returning here is not a third
        // gate — it is the registry's gates, read early. Every sink's `accepts`
        // must therefore need a stage, a reason, or the console threshold; one
        // that needs none of the three would have to be checked here too.
        //
        // `reason` earns its place here because a future health sink keys off
        // it alone. Every call site that passes one passes a stage as well
        // today, so this arm changes nothing in practice — it is here so that
        // the day one doesn't, the uplink is not silently blinded in release
        // builds.
        if stage == nil, reason == nil, !Self.isSeverityEnabled(severity) { return }
        let record = TimelineRecord(
            timestamp: Date(),
            severity: severity,
            tag: prefix,
            message: message,
            stage: stage,
            reason: reason,
            // Empty is absent: the slot is omitted entirely rather than
            // rendered as an empty `[]`, and a renderer must not group records
            // under "".
            campaignKey: (campaign?.isEmpty ?? true) ? nil : campaign,
            presentationId: presentationId,
            // Stamped only when it can be read — an unstaged record has no
            // consumer for it, and this runs on every console line.
            screenName: stage == nil ? nil : Self.currentScreenName,
            extras: TimelineRecord.boundExtras(extras),
            cause: error.map { String(describing: $0) }
        )
        for sink in Self.sinks {
            // A sink can never break the app that hosts us. Nothing is logged
            // about the failure: this runs on render paths, and reporting a
            // sink failure through the logger would re-enter the very loop that
            // just failed.
            //
            // platform note: Dart try/catches each sink here. Swift's sink
            // methods cannot throw, so the equivalent protection is the
            // protocol itself — `accepts` is pure and `emit` is documented as
            // never-throwing, and the two implementations honour it.
            if sink.accepts(record) { sink.emit(record) }
        }
    }

    /// Verbosity rank of a configured threshold — higher admits more.
    ///
    /// A `switch`, never a raw enum ordinal: ``DigiaLogLevel`` is public API
    /// that grows additively, so new values land wherever back-compat allows
    /// rather than in severity order.
    static func rank(of level: DigiaLogLevel) -> Int {
        switch level {
        case .none: return -1
        case .error: return DigiaLogSeverity.error.rank
        case .warn: return DigiaLogSeverity.warn.rank
        case .info: return DigiaLogSeverity.info.rank
        case .debug: return DigiaLogSeverity.debug.rank
        // The original name for "everything", kept forever: a shipped host app
        // may pass it for months after `debug` exists.
        case .verbose: return DigiaLogSeverity.debug.rank
        // `DigiaConfig` resolves the sentinel before it can reach here. This
        // arm covers the window before `configure(_:)` runs, where `auto` is
        // what is in force.
        case .auto: return rank(of: .resolvedAuto)
        }
    }
}
