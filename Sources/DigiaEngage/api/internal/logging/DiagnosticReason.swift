/// One pinned `snake_case` symbol naming *why* something happened.
///
/// Three enums implement it — ``DropReason``, ``DismissReason`` and the
/// internal `TimelineReason` — and a record carries whichever one fits. That is
/// the point: a delivery's reasons are the v2 contract's own enums, already
/// pinned and already sent to analytics from three runtimes, so the timeline
/// reuses them rather than minting twins. `TimelineReason` covers only what the
/// delivery enums do not.
///
/// **Used in conjunction, never converted.** Nothing maps a ``DropReason`` onto
/// a timeline symbol or back; the protocol exists so one field can hold any of
/// the three and one renderer can read ``wire`` off all of them.
///
/// No exhaustive `switch` is expected across the three: the set grows additively
/// as features land, and both renderers must show an unrecognised symbol as its
/// raw ``wire`` string rather than dropping or erroring. That rule is what keeps
/// a default branch correct instead of lossy — a new SDK reason ships months
/// before a dashboard can know about it.
///
/// platform note: Kotlin's twin is `interface DiagnosticReason { val wire: String }`
/// and Dart's an `abstract interface class` with a `wire` getter.
public protocol DiagnosticReason: Sendable {
    /// The pinned string form, `snake_case`. A wire contract between four SDKs
    /// and two renderers: never derive it from a Swift case name, and never
    /// reword one that has shipped.
    var wire: String { get }
}
