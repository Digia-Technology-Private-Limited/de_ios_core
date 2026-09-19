import Foundation

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

/// The single writer of presentation state.
///
/// Every live ``PresentationController`` in the SDK is opened here, indexed
/// here, and forgotten here when it settles. Nothing else keeps a map of them,
/// so "did this presentation settle?" has exactly one answer and exactly one
/// place that can change it — which is what makes G1 a fact rather than a habit.
///
/// It is deliberately ignorant of campaigns. It never looks in the store, never
/// decides what renders, and never touches a surface: routing hands it a
/// verdict and the render surfaces hand it lifecycle events, and it turns those
/// into state transitions. Anything it needed to *know* about a campaign would
/// be a second place the routing rules live.
///
/// ```
///   plugin ── host.deliver ──►  open()  ──► PresentationController (pending)
///                                  │
///        routing verdict ──────────┤
///          dropped ────────────────┼──► settle(dropped) ── hold released
///          accepted ───────────────┴──► accept() ── (+ acceptance watchdog
///                                                    unless inline, + anchor
///                                                    watchdog when one is owed)
///   render surface ── toCep(event) ──► handle() ─────┘
///          impressed ─► markDisplaying    clicked ─► emitClicked
///          dismissed ─► settle(dismissed) ── hold released
/// ```
///
/// platform note: the Dart twin keys its registry by payload *identity*, which
/// Swift cannot do — `CEPTriggerPayload` is a struct. ``open(_:owner:)`` stamps
/// the minted id onto the payload instead and hands that stamped instance to
/// routing, so every surface stores it and hands it back on every event. Same
/// property (two deliveries of one campaign never share a handle), spelled
/// explicitly rather than through object identity.
@MainActor
final class PresentationCoordinator {
    /// Creates the coordinator.
    ///
    /// `idGenerator` mints presentation ids; it is injected because the id is
    /// also the analytics dedup key, so a test needs it deterministic and
    /// production needs it UUID-grade.
    ///
    /// `onCancelSurface` runs the SDK's ordered teardown for a campaign the
    /// plugin cancelled — it must take the experience off the screen. The
    /// controller settles `cancelled` afterwards whatever it does, so a teardown
    /// can never be the thing that wedges a CEP slot.
    init(
        idGenerator: @escaping () -> String,
        onCancelSurface: @escaping (String) -> Void,
        acceptanceTimeout: TimeInterval = PresentationCoordinator.defaultAcceptanceTimeout,
        anchorLayoutTimeout: TimeInterval = PresentationCoordinator.defaultAnchorLayoutTimeout
    ) {
        newId = idGenerator
        self.onCancelSurface = onCancelSurface
        self.acceptanceTimeout = acceptanceTimeout
        self.anchorLayoutTimeout = anchorLayoutTimeout
    }

    /// Spec §3.5 `acceptanceMs`.
    static let defaultAcceptanceTimeout: TimeInterval = 15

    /// Spec §3.5 `anchorLayoutMs`.
    static let defaultAnchorLayoutTimeout: TimeInterval = 5

    /// How long a non-inline presentation may sit `pending` before the watchdog
    /// settles it `dropped('timeout')`.
    ///
    /// The airbag, not the brakes: the explicit terminal transitions are the
    /// fix. This exists so the next missed one degrades a single campaign for a
    /// few seconds instead of killing in-apps for the rest of the session.
    let acceptanceTimeout: TimeInterval

    /// How long an anchored experience may go without its anchor yielding a
    /// layout. Tighter than ``acceptanceTimeout`` because the failure is
    /// specific: the screen is up, the campaign is routed, and the one thing it
    /// is waiting for is an anchor that is not coming.
    let anchorLayoutTimeout: TimeInterval

    private let newId: () -> String
    private let onCancelSurface: (String) -> Void

    private var live: [String: LiveEntry] = [:]

    /// Presentations that have not settled yet. Diagnostics and tests.
    var liveCount: Int { live.count }

    /// Opens a presentation for a trigger `owner` just delivered.
    ///
    /// The returned controller is `pending` and not yet accepted — routing has
    /// not run. Its ``PresentationController/trigger`` is the *stamped* payload
    /// and is what must be handed on to routing. Call ``accept(_:kind:awaitsAnchorLayout:)``
    /// or settle it.
    func open(_ trigger: CEPTriggerPayload, owner: String) -> PresentationController {
        let id = newId()
        let controller = PresentationController(
            id: id,
            trigger: trigger.stamped(presentationId: id),
            onCancel: { [weak self] c in self?.onCancelSurface(c.trigger.cepCampaignId) }
        )
        live[id] = LiveEntry(owner: owner, controller: controller)
        // Cleanup binds to the outcome rather than to each settling path, so a
        // settle the coordinator never saw — the plugin's own `cancel()`, the
        // controller's cancelled backstop — still releases the index and the
        // watchdogs.
        Task { @MainActor [weak self] in
            _ = await controller.presentation.outcome.value
            self?.forget(id)
        }
        return controller
    }

    /// Records what kind of surface took an accepted presentation, and arms the
    /// acceptance watchdog if its `kind` owes an appearance.
    ///
    /// platform note: the Kotlin twin also takes the routed payload here,
    /// because it indexes by that instance's identity. Swift has the id on the
    /// payload already, so there is nothing to index.
    func accept(_ controller: PresentationController, kind: PresentationKind) {
        guard !controller.isSettled, let entry = live[controller.id] else { return }
        entry.kind = kind
        guard kind.armsAcceptanceWatchdog else { return }
        entry.acceptance = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: nanoseconds(self.acceptanceTimeout))
            guard !Task.isCancelled, !controller.isSettled else { return }
            log.e(
                "Dropped — acceptance watchdog fired, still pending; releasing the CEP hold "
                    + "(presentationId=\(controller.id), "
                    + "timeout=\(Int(self.acceptanceTimeout * 1000))ms)",
                campaign: controller.trigger.campaignKey
            )
            controller.settle(
                .dropped(
                    reason: .timeout,
                    detail: "never displayed within the acceptance window"
                )
            )
        }
    }

    /// Arms the anchor watchdog for an experience that cannot appear until a
    /// named anchor resolves — a non-anchorless guide. ``anchorResolved(_:)``
    /// disarms it, and so does an impression.
    func awaitAnchor(_ payload: CEPTriggerPayload) {
        guard let id = payload.presentationId, let entry = live[id] else { return }
        let controller = entry.controller
        guard !controller.isSettled else { return }
        entry.disarmAnchor()
        entry.anchor = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: nanoseconds(self.anchorLayoutTimeout))
            guard !Task.isCancelled, !controller.isSettled else { return }
            let displaying = controller.state == .displaying
            log.e(
                "Ended — anchor watchdog fired, no layout in "
                    + "\(Int(self.anchorLayoutTimeout * 1000))ms "
                    + "(presentationId=\(controller.id), displaying=\(displaying))",
                campaign: payload.campaignKey
            )
            // Settle first, tear the surface down second. The teardown emits its
            // own `dismissed`, and settling after it would record whatever the
            // surface said — `user_close` for a close the user never performed —
            // instead of the watchdog's reason. G7 names that reason, so it has
            // to be the one that wins.
            //
            // platform note: the Kotlin twin runs these two in the opposite
            // order, and its settle is a backstop rather than the decision. The
            // Dart core has no anchor watchdog at all yet.
            controller.settle(
                displaying
                    ? .dismissed(reason: .autoTimeout, completed: false)
                    // It never displayed, so it cannot settle `dismissed` — and
                    // the honest reason is the one the enum already has for
                    // exactly this: the anchor it was pinned to never showed up.
                    : .dropped(
                        reason: .anchorNotRegistered,
                        detail: "the anchor did not yield a layout within "
                            + "\(Int(self.anchorLayoutTimeout * 1000))ms"
                    )
            )
            self.onCancelSurface(payload.cepCampaignId)
        }
    }

    /// The anchor produced a layout — disarms the watchdog ``awaitAnchor(_:)`` armed.
    func anchorResolved(_ payload: CEPTriggerPayload) {
        guard let id = payload.presentationId else { return }
        live[id]?.disarmAnchor()
    }

    /// The presentation that owns `payload`, or nil once it has settled.
    func ownerOf(_ payload: CEPTriggerPayload) -> PresentationController? {
        guard let id = payload.presentationId else { return nil }
        return live[id]?.controller
    }

    /// Turns one coarse lifecycle event into a state transition on its owner.
    ///
    /// Total, and deliberately silent about payloads it does not know: a live
    /// test's events, a surface still emitting after its presentation settled,
    /// and anything rendered before a plugin ever attached all arrive here and
    /// all mean "nothing to transition".
    func handle(_ event: DigiaExperienceEvent, payload: CEPTriggerPayload) {
        guard let id = payload.presentationId, let entry = live[id] else { return }
        let controller = entry.controller
        switch event {
        case .impressed:
            entry.disarm()
            controller.markDisplaying()
            // A non-blocking experience hands the CEP's slot back the moment it
            // appears, not when it finally ends. Doing it here rather than at
            // each surface is what keeps the rule in one place.
            if entry.kind.releasesHoldOnDisplay { controller.releaseHold() }
        case .clicked(let elementID):
            // A tap is proof the experience is on screen, so a click that beats
            // its own impression here promotes the presentation rather than
            // breaking G3's ordering. The surfaces are not all equally careful
            // about reporting visibility, and normalising is this class's job.
            // Asserting instead would raise from a gesture handler, on the host
            // app's frame.
            entry.disarm()
            controller.markDisplaying()
            controller.emitClicked(elementId: elementID)
        case .dismissed(let reason, let completed):
            controller.settle(
                controller.state == .displaying
                    ? .dismissed(reason: reason, completed: completed)
                    // It ended without ever being seen, which is a drop however
                    // the surface phrased it. `dismissed` would tell the CEP an
                    // impression happened that never did.
                    : .dropped(
                        reason: reason == .superseded ? .superseded : .cancelled,
                        detail: "ended before it displayed (\(reason.value))"
                    )
            )
        }
    }

    /// Settles the presentation that owns `payload` as a drop.
    ///
    /// For a failure a lifecycle event has no vocabulary for — a guide whose
    /// anchor or artwork never produced a frame. ``DigiaExperienceEvent`` can
    /// only say "dismissed", which on a presentation that never displayed
    /// collapses to `cancelled`; the real reason is worth more to whoever reads
    /// the drop, and this is the one path that still has it in scope.
    func drop(_ payload: CEPTriggerPayload, reason: DropReason, detail: String?) {
        guard let id = payload.presentationId, let entry = live[id] else { return }
        entry.controller.settle(.dropped(reason: reason, detail: detail))
    }

    /// G6 — settles every presentation `owner` holds. Runs *before* the plugin's
    /// `detach()`, so the plugin's outcome handlers still fire and release its
    /// slot while its bridge is alive.
    func detach(owner: String) {
        for controller in live.values.filter({ $0.owner == owner }).map(\.controller) {
            controller.settle(
                controller.state == .displaying
                    ? .dismissed(reason: .pluginDetached, completed: false)
                    : .dropped(reason: .pluginDetached, detail: nil)
            )
        }
    }

    /// Settles every live presentation and clears the registry. Test teardown
    /// only — in production a presentation ends through its surface.
    func resetForTesting() {
        for controller in live.values.map(\.controller) {
            controller.settle(.dropped(reason: .cancelled, detail: "SDK reset"))
        }
        for entry in live.values { entry.disarm() }
        live.removeAll()
    }

    private func forget(_ id: String) {
        live.removeValue(forKey: id)?.disarm()
    }

    private func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }
}

/// Coordinator-side bookkeeping for one live presentation.
@MainActor
private final class LiveEntry {
    init(owner: String, controller: PresentationController) {
        self.owner = owner
        self.controller = controller
    }

    /// `DigiaCEPPlugin.id` of the plugin that delivered it.
    let owner: String

    /// Strong: this registry *is* core's ownership of the write face. The read
    /// face the plugin holds keeps only a weak link back, so nothing else would
    /// keep the controller alive. ``PresentationCoordinator/forget(_:)`` — bound
    /// to the outcome — is what releases it.
    let controller: PresentationController

    /// What kind of surface took it. `modal` until routing says otherwise, which
    /// is the conservative default: hold the CEP until the outcome.
    var kind: PresentationKind = .modal

    var acceptance: Task<Void, Never>?
    var anchor: Task<Void, Never>?

    func disarm() {
        acceptance?.cancel()
        acceptance = nil
        disarmAnchor()
    }

    func disarmAnchor() {
        anchor?.cancel()
        anchor = nil
    }
}
