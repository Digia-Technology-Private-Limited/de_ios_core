/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

/// The **write face** of a presentation: the half only the hosting core holds.
///
/// One presentation, two types — exactly as `CheckedContinuation` and its
/// awaiter do. Core creates, emits and settles here; the plugin gets
/// ``presentation`` and can only read, subscribe and cancel. Without the split
/// a plugin could settle its own presentation, and the exactly-once guarantee
/// would be a convention rather than a fact.
///
/// The guarantees are enforced *below this line*, not by whoever calls in, so a
/// fake host in a test inherits them for free:
///
/// - **G1** ``settle(_:)`` takes effect exactly once; later calls are no-ops.
/// - **G3** ``markDisplaying()`` emits `displayed` at most once, and never
///   after settlement.
/// - **G4** no signal is delivered after settlement. A `clicked` signal between
///   ``releaseHold()`` and ``settle(_:)`` *is* delivered — that window is the
///   non-blocking case.
/// - **G5** ``CampaignPresentation/cancel()`` is idempotent and safe in any
///   state.
/// - **G8** ``CampaignPresentation/holdReleased`` settles exactly once and
///   never after the outcome: ``settle(_:)`` releases the hold first if nothing
///   already did, so a plugin can bind CEP unblock to it unconditionally.
///
/// Everything here is `@MainActor`, which is the whole concurrency story: every
/// entry point — deliver, signals, settlement, plugin callbacks (CEP SDKs call
/// back on arbitrary threads), watchdog timers — hops to the main actor first
/// and only then touches state, so exactly-once is a plain `settled` check with
/// **no locks anywhere**. Settlement always ends in UI work regardless, the
/// volume is campaign-scale, and it reproduces the Dart core's single-threaded
/// semantics exactly — which is what keeps the conformance scenarios valid
/// verbatim across stacks. On Kotlin the same rule is hand-written
/// (`Dispatchers.Main.immediate` plus debug asserts); Swift gets it checked by
/// the compiler.
@MainActor
public final class PresentationController {
    /// Creates a controller for one delivered trigger.
    ///
    /// `onCancel` lets the owner of this presentation run its ordered teardown
    /// (dismiss the overlay, emit final signals, then settle) when the plugin
    /// cancels; it receives this controller, so it never needs to capture one.
    /// When it is omitted — or when it returns without settling — cancelling
    /// falls back to settling with a `cancelled` reason, so the release path
    /// can never itself be the thing that wedges a CEP slot.
    public init(
        id: String,
        trigger: CEPTriggerPayload,
        onCancel: (@MainActor (PresentationController) -> Void)? = nil
    ) {
        backing = PresentationBacking(id: id, trigger: trigger, onCancel: onCancel)
        backing.controller = self
    }

    /// platform note: the Dart twin stores the state on the controller and the
    /// read face forwards to it. Here it is the other way round — the backing
    /// object owns the state and this class forwards to it — because ARC would
    /// otherwise leak both halves of every presentation: the plugin keeps the
    /// read face alive, so a strong reference back to the controller would be
    /// a retain cycle. The backing holds the controller weakly instead, and
    /// the behaviour is identical.
    private let backing: PresentationBacking

    /// The core-minted presentation id. See ``CampaignPresentation/id``.
    public var id: String { backing.id }

    /// The trigger as delivered.
    public var trigger: CEPTriggerPayload { backing.trigger }

    /// The read face, handed to the owning plugin.
    public var presentation: CampaignPresentation { backing }

    /// The current lifecycle phase.
    public var state: PresentationState { backing.state }

    /// Whether the terminal result has already been decided.
    public var isSettled: Bool { backing.state == .settled }

    /// Whether the CEP has already been told it may release its hold.
    public var isHoldReleased: Bool { backing.holdReleased.isSettled }

    /// Moves the presentation to `displaying` and emits the `displayed` signal.
    ///
    /// A no-op once displaying or settled, so a renderer that reports
    /// visibility twice cannot produce two impressions.
    public func markDisplaying() { backing.markDisplaying() }

    /// Emits a `clicked` signal. A no-op once settled.
    public func emitClicked(elementId: String? = nil) {
        backing.emitClicked(elementId: elementId)
    }

    /// Frees the CEP's hold while the experience keeps running.
    ///
    /// For a non-blocking experience — a PIP, a floater — the CEP's slot must
    /// be handed back the moment the experience stops blocking, not when it
    /// finally ends, or every later campaign queues behind something the user
    /// is happily ignoring in a corner. Clicks stay legal until
    /// ``settle(_:)``.
    ///
    /// Idempotent. A modal experience never calls this: ``settle(_:)``
    /// releases the hold on its behalf, so there is exactly one code path for
    /// plugins either way.
    public func releaseHold() { backing.releaseHoldExplicitly() }

    /// Settles the presentation with its terminal `outcome`.
    ///
    /// Takes effect exactly once — the first call wins and every later one is a
    /// silent no-op, which is what lets a watchdog and a real terminal path
    /// race without either needing to know about the other. Call this *after*
    /// the overlay has actually left the screen and the last signal was
    /// delivered: signals → overlay gone → outcome.
    public func settle(_ outcome: PresentationOutcome) { backing.settle(outcome) }
}

/// The read face, and the object that actually holds the presentation's state.
///
/// Deliberately private rather than a conformance on ``PresentationController``
/// itself, so a plugin holding one cannot cast its way to `settle(_:)` — the
/// Swift equivalent of the Dart twin's private `_Presentation` forwarder.
private final class PresentationBacking: CampaignPresentation {
    init(
        id: String,
        trigger: CEPTriggerPayload,
        onCancel: (@MainActor (PresentationController) -> Void)?
    ) {
        self.id = id
        self.trigger = trigger
        self.onCancel = onCancel
    }

    let id: String
    let trigger: CEPTriggerPayload
    let outcome = PresentationPromise<PresentationOutcome>()
    let holdReleased = PresentationPromise<Void>()

    /// Weak: core owns the controller, the plugin owns this. A strong link
    /// back would keep both alive for the lifetime of the app.
    weak var controller: PresentationController?

    private let onCancel: (@MainActor (PresentationController) -> Void)?
    private var listeners: [(token: Int, listener: @MainActor (PresentationSignal) -> Void)] = []
    private var nextToken = 0
    private var displayedEmitted = false

    private(set) var state: PresentationState = .pending

    func onSignal(
        _ listener: @escaping @MainActor (PresentationSignal) -> Void
    ) -> @MainActor () -> Void {
        // Subscribing after settlement is legal and yields nothing — a plugin
        // racing a synchronous rejection should not have to check first.
        if state == .settled { return {} }
        nextToken += 1
        let token = nextToken
        listeners.append((token: token, listener: listener))
        return { [weak self] in
            self?.listeners.removeAll { $0.token == token }
        }
    }

    func cancel() {
        guard state != .settled else { return }
        guard let controller, let onCancel else {
            settleCancelled()
            return
        }
        onCancel(controller)
        // Backstop: a teardown that simply forgot must not leave the CEP's
        // slot held.
        //
        // platform note: the Dart twin also try/catches the teardown. Nothing
        // to catch here — the closure cannot throw — but the backstop below is
        // the half that mattered.
        settleCancelled()
    }

    func markDisplaying() {
        guard state == .pending else { return }
        state = .displaying
        displayedEmitted = true
        emit(.displayed)
    }

    func emitClicked(elementId: String?) {
        assert(
            displayedEmitted || state == .settled,
            "clicked emitted before displayed for presentation \(id) — G3 requires "
                + "displayed to precede every other signal"
        )
        guard state != .settled else { return }
        emit(.clicked(elementId: elementId))
    }

    func releaseHoldExplicitly() {
        assert(
            displayedEmitted || state == .settled,
            "releaseHold() before displayed for presentation \(id) — G8 orders "
                + "displayed <= holdReleased <= outcome, and a presentation that never "
                + "displayed releases its hold through settle() instead"
        )
        releaseHold()
    }

    func settle(_ result: PresentationOutcome) {
        guard state != .settled else { return }
        if case .dismissed = result {
            assert(
                displayedEmitted,
                "presentation \(id) settled dismissed(\(result.reasonValue)) without ever "
                    + "displaying — a presentation that never displayed must settle dropped"
            )
        }
        // G8: the hold can never outlive the outcome. A modal experience never
        // called releaseHold(), so this is where its CEP is unblocked.
        releaseHold()
        state = .settled
        listeners.removeAll()
        // The terminal console line is *not* emitted here. It belongs to core's
        // delivery observer, which is the one place that can also name the
        // timeline stage a drop happened on — and putting it here as well would
        // print the same fact twice on every single delivery.
        outcome.settle(result)
    }

    private func settleCancelled() {
        guard state != .settled else { return }
        settle(
            state == .displaying
                ? .dismissed(reason: .cancelled, completed: false)
                : .dropped(reason: .cancelled, detail: nil)
        )
    }

    private func releaseHold() {
        guard !holdReleased.isSettled else { return }
        holdReleased.settle(())
        log.d("CEP hold released (presentationId=\(id))", campaign: trigger.campaignKey)
    }

    private func emit(_ signal: PresentationSignal) {
        guard state != .settled else { return }
        // `listeners` is an array, so the loop iterates a value copy: a
        // listener may unsubscribe itself while being notified.
        //
        // platform note: the Dart twin also try/catches each listener, because
        // a plugin's marking code must never break the emitter. Swift cannot —
        // the listener is non-throwing, and a trap there is a trap either way.
        for entry in listeners { entry.listener(signal) }
    }
}
