import Foundation

/// The reason a ``PendingPayloadBuffer`` gives when a payload is held too long.
public enum PendingPayloadReason: String, CaseIterable, DiagnosticReason {
    /// The payload waited longer than the buffer's TTL for Core to become READY.
    case pendingExpired = "pending_expired"

    /// The pinned string form. Never derive this from the case name.
    public var wire: String { rawValue }
}

/// Holds a plugin's CEP triggers while Core is not READY.
///
/// Each plugin owns one instance and flushes it from
/// ``DigiaCEPPlugin/onHostReady()``. Core never reads it. A newer trigger
/// replaces a held one with the same `cepCampaignId`, with no drop. A full
/// buffer drops the oldest as ``DropReason/superseded``; a timer drops a
/// trigger held longer than 5 minutes as ``PendingPayloadReason/pendingExpired``.
/// Main-actor confined, so no lock.
@MainActor
public final class PendingPayloadBuffer {
    private static let capacity = 20
    private static let ttl: TimeInterval = 5 * 60

    private let onDrop: (CEPTriggerPayload, DiagnosticReason) -> Void
    private let arrivalOrder: Bool
    private let now: () -> Date
    private let createTimer: (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void

    // Arrival order, oldest first.
    private var entries: [(trigger: CEPTriggerPayload, heldAt: Date)] = []
    private var cancelTimer: (() -> Void)?

    /// Creates a buffer. `onDrop` settles a removed trigger with the CEP.
    ///
    /// `arrivalOrder` flushes oldest first, for known-inline triggers.
    public convenience init(
        onDrop: @escaping (CEPTriggerPayload, DiagnosticReason) -> Void,
        arrivalOrder: Bool = false
    ) {
        self.init(onDrop: onDrop, arrivalOrder: arrivalOrder, now: Date.init, createTimer: mainQueueTimer)
    }

    /// `now` and `createTimer` replace the clock in tests.
    init(
        onDrop: @escaping (CEPTriggerPayload, DiagnosticReason) -> Void,
        arrivalOrder: Bool,
        now: @escaping () -> Date,
        createTimer: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void
    ) {
        self.onDrop = onDrop
        self.arrivalOrder = arrivalOrder
        self.now = now
        self.createTimer = createTimer
    }

    /// The number of held triggers.
    public var length: Int { entries.count }

    /// Holds `trigger`. A replaced copy keeps its first hold time, so a re-pull
    /// does not extend the 5 minutes.
    public func add(_ trigger: CEPTriggerPayload) {
        var heldAt = now()
        if let index = entries.firstIndex(where: { $0.trigger.cepCampaignId == trigger.cepCampaignId }) {
            heldAt = entries.remove(at: index).heldAt
        }
        if entries.count >= Self.capacity {
            onDrop(entries.removeFirst().trigger, DropReason.superseded)
        }
        entries.append((trigger, heldAt))
        schedule()
    }

    /// Removes and returns every held trigger in flush order: newest first, so
    /// the freshest modal takes the surface; inline triggers keep arrival order.
    public func takeAll() -> [CEPTriggerPayload] {
        let triggers = entries.map(\.trigger)
        entries.removeAll()
        schedule()
        return arrivalOrder ? triggers : triggers.reversed()
    }

    /// Removes every held trigger with `reason`.
    public func dropAll(_ reason: DiagnosticReason) {
        for trigger in takeAll() {
            onDrop(trigger, reason)
        }
    }

    private func schedule() {
        cancelTimer?()
        cancelTimer = nil
        guard let oldest = entries.map(\.heldAt).min() else { return }
        let due = oldest.addingTimeInterval(Self.ttl).timeIntervalSince(now())
        cancelTimer = createTimer(max(0, due)) { [weak self] in self?.expire() }
    }

    private func expire() {
        let cutoff = now().addingTimeInterval(-Self.ttl)
        let expired = entries.filter { $0.heldAt <= cutoff }.map(\.trigger)
        entries.removeAll { $0.heldAt <= cutoff }
        schedule()
        for trigger in expired {
            onDrop(trigger, PendingPayloadReason.pendingExpired)
        }
    }
}

/// Runs `work` on the main queue after `delay` seconds and returns its cancel.
private func mainQueueTimer(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
    let item = DispatchWorkItem { MainActor.assumeIsolated(work) }
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    return { item.cancel() }
}
