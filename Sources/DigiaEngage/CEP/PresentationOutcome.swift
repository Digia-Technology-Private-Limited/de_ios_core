/// The lifecycle phase of a presentation.
///
/// A synchronous peek for logs and debugging only — control flow must use
/// ``CampaignPresentation/outcome``, never a poll of this.
public enum PresentationState: String, CaseIterable, Sendable {
    /// Delivered; core has not yet confirmed the experience is on screen.
    case pending = "pending"

    /// The experience is visible to the user.
    case displaying = "displaying"

    /// Terminal. The outcome has settled and no further signals will arrive.
    case settled = "settled"

    /// The pinned string form. Shared character-for-character with the Kotlin
    /// and Dart cores — see ``DropReason/value``.
    public var value: String { rawValue }
}

/// Why a presentation ended without ever displaying.
///
/// The `value` strings are a cross-stack contract: they reach the Digia
/// analytics backend from three runtimes (Swift, Kotlin, Dart) and must match
/// character for character. `CEPInterfaceEnumValuesTests.swift` pins them.
///
/// Every raw value below is spelled out in full. Never let one be derived from
/// the case name — the two differ, and a silently derived string is a wire
/// break no test would catch at the call site.
public enum DropReason: String, CaseIterable, Sendable {
    /// SDK not ready and the trigger was not queueable.
    case notInitialized = "not_initialized"

    /// The key is not in the campaign store.
    case unknownCampaignKey = "unknown_campaign_key"

    /// Template unparseable, no steps, or an illegal combination of options.
    case invalidConfig = "invalid_config"

    /// A guide's first anchor is absent from this screen.
    case anchorNotRegistered = "anchor_not_registered"

    /// The frequency gate said no.
    case frequencyCapped = "frequency_capped"

    /// The campaign is scoped to screens the host is not currently on. Nothing
    /// is wrong with it — the user is somewhere else.
    case screenNotTargeted = "screen_not_targeted"

    /// Another experience already occupies the surface this one needs. The
    /// incumbent wins; this trigger is the one turned away. (Contrast
    /// ``superseded``, where a *newer* trigger displaces this one.)
    case surfaceBusy = "surface_busy"

    /// Displaced by a newer trigger before it displayed.
    case superseded = "superseded"

    /// No host was mounted when the render was due.
    case hostNotMounted = "host_not_mounted"

    /// Watchdog: no verdict, or no layout, in time.
    case timeout = "timeout"

    /// The owner called `cancel()` before it displayed.
    case cancelled = "cancelled"

    /// The owning plugin was unregistered.
    case pluginDetached = "plugin_detached"

    /// An unexpected error — specifics in the dropped arm's `detail`.
    case error = "error"

    /// The pinned string form. Never derive this from the case name.
    public var value: String { rawValue }
}

/// How a presentation that *did* display ended.
///
/// See ``DropReason/value`` on why these strings are pinned.
public enum DismissReason: String, CaseIterable, Sendable {
    /// The user tapped the experience's own close affordance.
    case userClose = "user_close"

    /// The user tapped outside the experience.
    case scrimTap = "scrim_tap"

    /// The user dismissed with a system back gesture or button.
    case backGesture = "back_gesture"

    /// A CTA the user tapped ended the experience.
    case ctaAction = "cta_action"

    /// A watchdog or an authored display TTL ended it.
    case autoTimeout = "auto_timeout"

    /// The user left the screen the experience belonged to. The expected end of
    /// a screen-scoped floater, not an error path — `userClose` would report a
    /// close the user never performed.
    case screenExit = "screen_exit"

    /// The engine lost the target it was showing, or was about to show — it moved
    /// off screen, or its anchor left the tree or the registry. The host reported
    /// no screen change; this is not `screenExit`.
    case targetLost = "target_lost"

    /// A newer trigger displaced it while it was on screen. The displaying
    /// counterpart of ``DropReason/superseded``; without it a displaced
    /// experience would have no honest terminal reason at all.
    case superseded = "superseded"

    /// The experience ran to its authored end.
    case completed = "completed"

    /// The owner called `cancel()` while it was displaying.
    case cancelled = "cancelled"

    /// The owning plugin was unregistered while it was displaying.
    case pluginDetached = "plugin_detached"

    /// The pinned string form. Never derive this from the case name.
    public var value: String { rawValue }
}

/// The exactly-once terminal result of a presentation.
///
/// Two arms and only two: it displayed and has now closed (``dismissed``), or
/// it never displayed (``dropped``). In both arms the CEP's hold has already
/// ended — `holdReleased` settles no later than either arm, which is why a
/// plugin binds its unblock there and never to an arm. What binds *here* is
/// final marking and cleanup.
///
/// platform note: Kotlin's twin is a `sealed class` with `Dismissed` /
/// `Dropped` subclasses and Dart's a `sealed class` with
/// `PresentationDismissed` / `PresentationDropped`; Swift's sealed form is an
/// enum, so the arms are cases with the same fields and the same `kind`
/// strings.
public enum PresentationOutcome: Sendable, Equatable {
    /// The experience displayed, and has now left the screen.
    ///
    /// `completed` records whether it reached its authored end before closing.
    /// A field, not an arm: completion does not change who releases the CEP
    /// slot.
    case dismissed(reason: DismissReason, completed: Bool)

    /// The experience never displayed.
    ///
    /// `detail` is debug-only free text — which config line, which error. Log
    /// it, never branch on it.
    case dropped(reason: DropReason, detail: String?)

    /// Stable discriminator for logs and analytics: `dismissed` or `dropped`.
    public var kind: String {
        switch self {
        case .dismissed: return "dismissed"
        case .dropped: return "dropped"
        }
    }

    /// The terminal reason's pinned string value, whichever arm this is.
    public var reasonValue: String {
        switch self {
        case .dismissed(let reason, _): return reason.value
        case .dropped(let reason, _): return reason.value
        }
    }
}

/// The timeline's reasons for a delivery that never displayed.
///
/// Purely additive: ``wire`` is the same pinned string ``DropReason/value``
/// already is. The timeline reuses this enum rather than minting a twin symbol
/// for each of its thirteen values — see ``DiagnosticReason``.
extension DropReason: DiagnosticReason {
    /// The pinned string form, identical to ``value``.
    public var wire: String { rawValue }
}

/// The timeline's reasons for a delivery that displayed and then ended.
///
/// Additive, for the same reason as ``DropReason``'s conformance above.
extension DismissReason: DiagnosticReason {
    /// The pinned string form, identical to ``value``.
    public var wire: String { rawValue }
}
