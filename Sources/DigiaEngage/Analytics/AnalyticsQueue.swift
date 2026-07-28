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
    private let defaults: UserDefaults
    private static let key = "digia_analytics_queue"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var size: Int { load().count }

    func append(_ entry: QueueEntry, maxEvents: Int) {
        var entries = load()
        entries.append(entry)
        if entries.count > maxEvents {
            entries = Array(entries.dropFirst(entries.count - maxEvents))
        }
        save(entries)
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
        defaults.removeObject(forKey: Self.key)
    }

    // MARK: - Persistence

    private func load() -> [QueueEntry] {
        guard
            let data = defaults.data(forKey: Self.key),
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
        if let data = try? JSONSerialization.data(withJSONObject: arr) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
