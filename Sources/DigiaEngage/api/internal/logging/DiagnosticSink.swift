/// One destination for emitted records.
///
/// ``DigiaLogger`` builds a record once and walks the registry, so adding a
/// destination — the on-device timeline, a dashboard stream, a health uplink —
/// never touches a call site.
///
/// The split between the two methods is the contract:
///
/// - ``accepts(_:)`` is a **pure, cheap predicate**. It decides; it does not
///   act. It runs for every sink on every emitted record, including on render
///   paths.
/// - ``emit(_:)`` owns the side effects, and is called only after
///   ``accepts(_:)`` said yes.
///
/// **Gates are independent by design.** The console gates on severity; the
/// timeline gates on ``TimelineRecord/stage``. A `debug` gating drop that a
/// release console suppresses still reaches the timeline — that is the feature,
/// not an accident, and it is why a staged call must never be wrapped in a
/// ``DigiaLogger/isEnabled(_:)`` guard.
///
/// Internal only — not part of `DigiaEngage`'s public API. Exporting it later,
/// so a host app can route SDK diagnostics into its own crash reporter, is a
/// purely additive change.
protocol DiagnosticSink: AnyObject, Sendable {
    /// Whether this sink wants `record`. Pure and cheap.
    func accepts(_ record: TimelineRecord) -> Bool

    /// Consumes `record`. Called only when ``accepts(_:)`` returned true.
    func emit(_ record: TimelineRecord)
}
