/// A set-once value a plugin can await, whatever the order of events.
///
/// platform note: Kotlin's twin types these as `Deferred<T>` (settled through
/// `CompletableDeferred`) and Dart's as `Future<T>` (settled through
/// `Completer`). Swift has neither, so the contract ships this instead —
/// deliberately the smallest thing with the two properties that matter:
/// it settles **exactly once**, and **a late awaiter still fires**, because
/// the value is stored rather than broadcast. Everything here is
/// main-actor-confined, so waiter bookkeeping needs no lock.
///
/// Only the hosting core can settle one: `settle(_:)` is `internal`, and the
/// read face hands out a promise that plugins can await and peek at, never
/// complete.
@MainActor
public final class PresentationPromise<Value: Sendable> {
    private var stored: Value?
    private var waiters: [CheckedContinuation<Value, Never>] = []

    init() {}

    /// The settled value, awaiting it if it has not settled yet.
    ///
    /// Awaiting an already-settled promise returns immediately — that is the
    /// synchronous-drop path, where `deliver()` hands back a presentation that
    /// settled before the caller could possibly have awaited anything.
    public var value: Value {
        get async {
            if let stored { return stored }
            return await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    /// A synchronous peek — nil until it settles. For logs and debugging;
    /// control flow awaits ``value``.
    public var settledValue: Value? { stored }

    /// Whether the value has settled.
    public var isSettled: Bool { stored != nil }

    /// Settles the promise. The first call wins; every later one is a no-op.
    func settle(_ value: Value) {
        guard stored == nil else { return }
        stored = value
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume(returning: value) }
    }
}

/// A claim ticket for one delivered trigger, owned exclusively by the plugin
/// that delivered it.
///
/// This is the **read face**. Core creates, emits and settles through the
/// matching write face, ``PresentationController``. Plugins may read
/// ``outcome`` and ``holdReleased``, subscribe to signals, and ``cancel()``;
/// they must never settle — that guarantee is core's, and it is what makes
/// releasing a CEP slot a single line:
///
/// ```swift
/// let presentation = host.deliver(trigger)   // never throws
/// await presentation.holdReleased.value      // never fails, settles once
/// await releaseTheCepSlot()                  // every path reaches here
/// ```
@MainActor
public protocol CampaignPresentation: AnyObject {
    /// Minted by core when the trigger was delivered. UUID-grade: it is also
    /// the first-party analytics dedup key, so it must not collide across
    /// sessions or devices.
    ///
    /// This — not ``CEPTriggerPayload/cepCampaignId`` — is the correlation key
    /// for logs, health reports and analytics. CleverTap sets `cepCampaignId`
    /// to the campaign key itself, so re-triggering one campaign collides on
    /// that field.
    var id: String { get }

    /// The trigger exactly as delivered.
    var trigger: CEPTriggerPayload { get }

    /// A synchronous peek, for logs and debugging. Control flow must use
    /// ``outcome`` — never poll this.
    var state: PresentationState { get }

    /// Settles exactly once with the terminal result, and never with an error.
    ///
    /// The experience has fully ended by the time this settles — final CEP
    /// marking and cleanup bind here. To free the CEP's slot, bind to
    /// ``holdReleased`` instead: it settles at or before this, never after.
    var outcome: PresentationPromise<PresentationOutcome> { get }

    /// "The CEP may release its hold — slot, queue, gate — **now**."
    ///
    /// Settles exactly once, never fails, and never after ``outcome``. For a
    /// modal experience core settles the two together; a non-blocking
    /// experience (PIP, floater) releases this early and keeps running, and a
    /// `clicked` signal stays legal until ``outcome``. Bind CEP unblock here,
    /// unconditionally — no branch on which arm the outcome took, and no check
    /// for whether it displayed.
    ///
    /// **Why a promise and not a ``PresentationSignal``.** A signal is
    /// fire-and-forget: a listener attached after emission misses it, and
    /// `deliver()` can return an *already-settled* presentation — a
    /// synchronous drop, whose hold-release therefore fires before any
    /// listener could possibly exist. That is a designed path here, not a
    /// race. And a missed release wedges the CEP's queue: it is the original
    /// F1 bug. A promise stores its value, so a late awaiter still fires,
    /// exactly once. Making a signal safe would take buffering, at-most-once
    /// delivery, and auto-emit-on-settle — which is a promise, rebuilt by
    /// hand.
    ///
    /// **Keep this rationale here.** Every stack's contract file carries it,
    /// because the tempting simplification is to fold hold-release into
    /// ``PresentationSignal``, and this comment is the only thing standing in
    /// the way.
    var holdReleased: PresentationPromise<Void> { get }

    /// Subscribes to this presentation's signals.
    ///
    /// `displayed` arrives first and at most once; nothing arrives after
    /// ``outcome``. A `clicked` signal *may* arrive after ``holdReleased`` —
    /// that window is the non-blocking case. Returns an unsubscribe closure;
    /// calling it twice is safe.
    func onSignal(_ listener: @escaping @MainActor (PresentationSignal) -> Void) -> @MainActor () -> Void

    /// Owner-initiated termination — the CEP closed its template, the user
    /// logged out. Idempotent, safe in any state, and a no-op once settled.
    func cancel()
}
