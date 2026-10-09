/// Lifecycle events emitted by the SDK's render surfaces when an experience
/// transitions state.
///
/// Internal to core: they reach ``PresentationCoordinator``, which turns each
/// into a transition on the presentation that owns the payload. A plugin never
/// sees one — it reads ``PresentationSignal`` and ``PresentationOutcome`` on its
/// own handle.
///
/// This is a separate concern from Digia's rich, campaign-grouped analytics
/// events (``EngageAnalyticsEvent``): step/question/completed signals exist only
/// there and never reach a presentation.
enum DigiaExperienceEvent: Sendable, Equatable {
    /// The experience became visible to the user.
    case impressed

    /// A qualifying interaction: Canvas/nudge primary CTA, classic story open,
    /// carousel container tap, or survey welcome Start.
    case clicked(elementID: String? = nil)

    /// The experience ended — by the user or programmatically.
    ///
    /// This is the event that ends a presentation, so it carries the two fields
    /// ``PresentationOutcome/dismissed(reason:completed:)`` needs. Both default
    /// to the common case (the user closed it, unfinished); a surface that knows
    /// better passes what it knows.
    case dismissed(reason: DismissReason = .userClose, completed: Bool = false)
}
