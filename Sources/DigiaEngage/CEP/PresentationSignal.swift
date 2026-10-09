/// A mid-flight signal scoped to one presentation, delivered only to the
/// plugin that owns it.
///
/// Dismissal is deliberately **not** a signal: it is the one marking that must
/// never be missed (it unblocks the CEP), so it rides the guaranteed channel —
/// ``CampaignPresentation/outcome`` — instead. Signals are best-effort; a
/// missed click marker is a stats blip, a missed release is an outage.
///
/// platform note: Kotlin and Dart model this as a sealed type with
/// `DisplayedSignal` / `ClickedSignal` arms; Swift's sealed form is an enum,
/// with the same `type` strings.
public enum PresentationSignal: Sendable, Equatable {
    /// The experience became visible. Fires at most once, before any other
    /// signal, and never on a presentation that ends up dropped.
    case displayed

    /// A qualifying interaction with the experience. `elementId` is the
    /// identifier of the element clicked when the campaign artifact authored
    /// one, and nil for an interaction with no authored identifier.
    case clicked(elementId: String?)

    /// Stable discriminator for logs and analytics.
    public var type: String {
        switch self {
        case .displayed: return "displayed"
        case .clicked: return "clicked"
        }
    }
}
