import Foundation

/// The reason a ``PendingPayloadBuffer`` gives when a payload is held too long.
public enum PendingPayloadReason: String, CaseIterable, DiagnosticReason {
    /// The payload waited longer than the buffer's TTL for Core to become READY.
    case pendingExpired = "pending_expired"

    /// The pinned string form. Never derive this from the case name.
    public var wire: String { rawValue }
}

extension PresentationOutcome {
    /// True for a drop that means Core is not READY yet. A plugin puts such a
    /// payload back in its ``PendingPayloadBuffer`` and does not settle it with the CEP.
    public var isHostNotReady: Bool {
        guard case .dropped(let reason, _) = self else { return false }
        return reason == .notReady || reason == .notInitialized
    }
}

/// Holds CEP payloads in a plugin while Core is not READY.
///
/// Each plugin creates its own instance. Core never reads it. Main-actor
/// confined, so it needs no lock. In memory only.
///
/// - Bound: at most ``capacity`` items. When full, the oldest drops with
///   ``DropReason/superseded``.
/// - TTL: an active timer drops each item older than ``ttl`` with
///   ``PendingPayloadReason/pendingExpired``.
/// - Order: ``drain()`` returns newest first. ``Order/inline(id:)`` returns
///   arrival order with one item per id; a newer item replaces an older one
///   with no drop event.
@MainActor
public final class PendingPayloadBuffer<Item> {

    public enum Order {
        case newestFirst
        case inline(id: (Item) -> String)
    }

    /// Cancels a scheduled timer.
    public typealias Cancel = () -> Void
    /// Runs `work` on the main actor after `delay` seconds.
    public typealias Scheduler = (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Cancel

    public static var defaultCapacity: Int { 20 }
    public static var defaultTTL: TimeInterval { 300 }

    public let capacity: Int
    public let ttl: TimeInterval

    private let order: Order
    private let now: () -> Date
    private let schedule: Scheduler
    private let onDrop: (Item, DiagnosticReason) -> Void

    private var entries: [(item: Item, heldAt: Date)] = []
    private var cancelTimer: Cancel?

    /// - Parameter onDrop: called for each item the buffer drops. The plugin
    ///   logs it and settles it with the CEP.
    public init(
        order: Order = .newestFirst,
        capacity: Int = defaultCapacity,
        ttl: TimeInterval = defaultTTL,
        now: @escaping () -> Date = Date.init,
        schedule: @escaping Scheduler = PendingPayloadBuffer.mainQueueScheduler,
        onDrop: @escaping (Item, DiagnosticReason) -> Void
    ) {
        self.order = order
        self.capacity = capacity
        self.ttl = ttl
        self.now = now
        self.schedule = schedule
        self.onDrop = onDrop
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    /// Whether a held item matches `predicate`.
    public func contains(where predicate: (Item) -> Bool) -> Bool {
        entries.contains { predicate($0.item) }
    }

    /// Holds `item`.
    public func add(_ item: Item) {
        if case .inline(let id) = order {
            let key = id(item)
            entries.removeAll { id($0.item) == key }
        }
        entries.append((item, now()))
        if entries.count > capacity {
            onDrop(entries.removeFirst().item, DropReason.superseded)
        }
        scheduleExpiry()
    }

    /// Removes and returns every item in flush order.
    public func drain() -> [Item] {
        let items = entries.map(\.item)
        clear()
        switch order {
        case .newestFirst: return items.reversed()
        case .inline: return items
        }
    }

    /// Drops every item with `reason`, for example `initialization_failed` or `plugin_detached`.
    public func dropAll(_ reason: DiagnosticReason) {
        let items = entries.map(\.item)
        clear()
        for item in items { onDrop(item, reason) }
    }

    private func clear() {
        entries.removeAll()
        cancelTimer?()
        cancelTimer = nil
    }

    private func scheduleExpiry() {
        cancelTimer?()
        cancelTimer = nil
        guard let oldest = entries.first else { return }
        let delay = max(0, oldest.heldAt.addingTimeInterval(ttl).timeIntervalSince(now()))
        cancelTimer = schedule(delay) { [weak self] in self?.expire() }
    }

    private func expire() {
        let cutoff = now().addingTimeInterval(-ttl)
        let expired = entries.prefix { $0.heldAt <= cutoff }.map(\.item)
        entries.removeFirst(expired.count)
        scheduleExpiry()
        for item in expired { onDrop(item, PendingPayloadReason.pendingExpired) }
    }

    /// The production scheduler: `DispatchQueue.main.asyncAfter`.
    public nonisolated static func mainQueueScheduler(
        _ delay: TimeInterval, _ work: @escaping @MainActor () -> Void
    ) -> Cancel {
        let item = DispatchWorkItem { MainActor.assumeIsolated(work) }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }
}
