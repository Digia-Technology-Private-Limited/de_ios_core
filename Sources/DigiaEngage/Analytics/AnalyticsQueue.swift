import Foundation

struct QueueEntry: @unchecked Sendable {
    let eventId: String
    let payload: [String: Any]
    let createdAt: TimeInterval
    /// Persisted so the retry cap survives app restarts — otherwise a user
    /// force-quitting/reopening during a flaky connection would give every
    /// stuck event a fresh set of retries each time.
    var attempts: Int
}

final class AnalyticsQueue {
    private let storage: LocalStorage
    private let key: String

    /// Each queue owns one storage key, so the app-event queue and the
    /// experience queue can share a scoped storage without sharing entries.
    init(storage: LocalStorage, key: String = "queue") {
        self.storage = storage
        self.key = key
    }

    var size: Int { load().count }

    /// Appends `entry`, dropping the oldest beyond `maxEvents`, and returns how
    /// many older entries the cap evicted.
    @discardableResult
    func append(_ entry: QueueEntry, maxEvents: Int) -> Int {
        var entries = load()
        entries.append(entry)
        let evicted = max(0, entries.count - maxEvents)
        if evicted > 0 { entries = Array(entries.dropFirst(evicted)) }
        save(entries)
        return evicted
    }

    func peek(maxCount: Int) -> [QueueEntry] {
        Array(load().prefix(maxCount))
    }

    func remove(eventIds: [String]) {
        let ids = Set(eventIds)
        save(load().filter { !ids.contains($0.eventId) })
    }

    /// Increments the attempt counter on the matching entries and returns their
    /// post-increment state, so the caller can decide whether any of them have
    /// now exceeded the retry cap.
    @discardableResult
    func incrementAttempt(eventIds: [String]) -> [QueueEntry] {
        let ids = Set(eventIds)
        var updated: [QueueEntry] = []
        let entries = load().map { entry -> QueueEntry in
            guard ids.contains(entry.eventId) else { return entry }
            var e = entry
            e.attempts += 1
            updated.append(e)
            return e
        }
        save(entries)
        return updated
    }

    func clear() {
        storage.removeObject(forKey: key)
    }

    // MARK: - Persistence

    private func load() -> [QueueEntry] {
        guard
            let str = storage.string(forKey: key),
            let data = str.data(using: .utf8),
            let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return arr.compactMap { dict in
            guard
                let eventId = dict["event_id"] as? String,
                let payload = dict["payload"] as? [String: Any],
                let createdAt = dict["created_at"] as? TimeInterval
            else { return nil }
            return QueueEntry(
                eventId: eventId,
                payload: payload,
                createdAt: createdAt,
                attempts: dict["attempts"] as? Int ?? 0
            )
        }
    }

    private func save(_ entries: [QueueEntry]) {
        let arr: [[String: Any]] = entries.map { e in
            ["event_id": e.eventId, "payload": e.payload, "created_at": e.createdAt, "attempts": e.attempts]
        }
        if let data = try? JSONSerialization.data(withJSONObject: arr),
           let str = String(data: data, encoding: .utf8) {
            storage.set(str, forKey: key)
        }
    }
}
