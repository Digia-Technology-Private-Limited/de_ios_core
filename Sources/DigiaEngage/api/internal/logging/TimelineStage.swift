/// Where in the campaign's journey a record was emitted.
///
/// The promotion gate: **a record is PM-visible if and only if it carries a
/// stage.** Free-text developer logging can never leak onto a campaign
/// creator's screen, because promoting a line is a deliberate act — pick a
/// stage, pick a reason from a closed enum.
///
/// The seven are the whole journey, in order, and each is phrased as something
/// a non-developer can hold: the app connected, campaigns came down, one was
/// read, something asked for it, rules decided, we tried to draw it, the user
/// touched it.
enum TimelineStage: String, CaseIterable, Sendable {
    /// The app connected; the SDK is running.
    case session = "session"

    /// Campaigns downloaded from Digia.
    case fetch = "fetch"

    /// A downloaded campaign was accepted or rejected.
    case parse = "parse"

    /// Something asked for this campaign to be shown.
    case trigger = "trigger"

    /// Rules decided whether to show it.
    case gating = "gating"

    /// The SDK tried to put it on screen.
    case render = "render"

    /// The user saw it, tapped it, dismissed it.
    case interaction = "interaction"

    /// The pinned string form. Shared with the Kotlin, Dart and RN cores and
    /// with the dashboard renderer — see ``DiagnosticReason/wire``. Never
    /// derive it from the case name.
    var wire: String { rawValue }
}
