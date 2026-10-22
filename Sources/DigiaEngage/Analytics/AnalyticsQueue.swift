import Foundation

private let log = DigiaLogger("analytics")

struct QueueEntry: @unchecked Sendable {
    let eventId: String
    let payload: [String: Any]
    let createdAt: TimeInterval
    /// Persisted so the retry cap survives app restarts — otherwise a user
    /// force-quitting/reopening during a flaky connection would give every
    /// stuck event a fresh set of retries each time.
    var attempts: Int
}

/// FIFO entries in memory, holding at most [limit] (or the caller's smaller
/// cap) by dropping the oldest. Not thread-safe; its owner serializes access.
struct BoundedEntryBuffer {
    let limit: Int
    private(set) var entries: [QueueEntry] = []

    init(limit: Int) {
        self.limit = limit
    }

    var count: Int { entries.count }

    mutating func append(_ entry: QueueEntry, maxEvents: Int) {
        entries.removeAll { $0.eventId == entry.eventId }
        entries.append(entry)
        let overflow = entries.count - min(limit, maxEvents)
        if overflow > 0 {
            entries.removeFirst(overflow)
            log.w("Memory queue exceeded its cap — dropping \(overflow) oldest event(s)")
        }
    }

    func prefix(_ count: Int) -> [QueueEntry] {
        Array(entries.prefix(max(0, count)))
    }

    mutating func remove(eventIds: Set<String>) {
        entries.removeAll { eventIds.contains($0.eventId) }
    }

    mutating func incrementAttempt(eventIds: Set<String>) -> [QueueEntry] {
        var updated: [QueueEntry] = []
        for index in entries.indices where eventIds.contains(entries[index].eventId) {
            entries[index].attempts += 1
            updated.append(entries[index])
        }
        return updated
    }

    mutating func removeAll() {
        entries.removeAll()
    }
}

/// An in-memory ``AnalyticsQueueProtocol``: events last for this process only.
/// For tests, and for a container built without persistent storage.
final class MemoryAnalyticsQueue: AnalyticsQueueProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: BoundedEntryBuffer

    init(limit: Int = .max) {
        buffer = BoundedEntryBuffer(limit: limit)
    }

    var size: Int { lock.withLock { buffer.count } }

    func append(_ entry: QueueEntry, maxEvents: Int) {
        lock.withLock { buffer.append(entry, maxEvents: maxEvents) }
    }

    func count() async -> Int { size }

    func peek(maxCount: Int) async -> [QueueEntry] {
        lock.withLock { buffer.prefix(maxCount) }
    }

    func remove(eventIds: [String]) async {
        lock.withLock { buffer.remove(eventIds: Set(eventIds)) }
    }

    @discardableResult
    func incrementAttempt(eventIds: [String]) async -> [QueueEntry] {
        lock.withLock { buffer.incrementAttempt(eventIds: Set(eventIds)) }
    }

    func clear() async {
        lock.withLock { buffer.removeAll() }
    }
}
