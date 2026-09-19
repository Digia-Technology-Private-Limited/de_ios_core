/// What routing decided about one delivered trigger.
///
/// Replaces the boolean `route` used to answer. The boolean was the v1 lie in
/// miniature: a dozen distinct outcomes flattened into accepted/not, so a plugin
/// holding a CEP slot learned only that something went wrong and never what —
/// and could not tell a campaign that will render later from one that will never
/// render at all.
///
/// platform note: the Dart twin is a `sealed class` with `RoutingAccepted` /
/// `RoutingDropped`; Swift's sealed form is an enum, with the same fields.
enum RoutingVerdict {
    /// The campaign was handed to a renderer or parked in a slot.
    ///
    /// `payload` is the payload as it reached the surface — every later
    /// lifecycle event carries this instance, and it is what the coordinator
    /// resolves back to a presentation.
    case accepted(payload: CEPTriggerPayload, kind: PresentationKind)

    /// The campaign will never display, and the CEP's hold can go back now.
    ///
    /// `detail` is debug-only free text. Log it, never branch on it.
    case dropped(reason: DropReason, detail: String?)

    var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

/// How a routed campaign occupies the screen.
///
/// Two independent questions have the same three answers, so they are one enum
/// rather than two booleans that can contradict each other: does this
/// presentation owe us an appearance on a deadline, and does the CEP get its
/// hold back when it appears or when it ends?
enum PresentationKind {
    /// Blocks the surface until it closes — a nudge, a survey, a guide.
    ///
    /// The CEP's hold lasts as long as the experience does, which is the whole
    /// reason the CEP had a lock in the first place.
    case modal

    /// Floats over the app without blocking it — a PiP, a story floater.
    ///
    /// The hold ends at the impression: the user is free to ignore a floater for
    /// as long as they like, and every later campaign would otherwise queue
    /// behind something sitting quietly in a corner.
    case floating

    /// Parked in a persistent slot, shown when the user reaches it.
    ///
    /// No acceptance watchdog: an inline campaign is legitimately `pending`
    /// until the user scrolls to its slot — possibly never — so a timeout would
    /// settle a perfectly healthy campaign. Nothing is at risk in waiting,
    /// because no CEP holds a lock on an inline campaign: CleverTap's Native
    /// Display never occupies the in-app slot, and WebEngage inline opens its
    /// gate at the impression.
    case inline

    /// Whether a presentation of this kind must appear within the acceptance
    /// window or be settled `dropped('timeout')`.
    var armsAcceptanceWatchdog: Bool { self != .inline }

    /// Whether the CEP's hold ends at the impression rather than the outcome.
    var releasesHoldOnDisplay: Bool { self != .modal }
}
