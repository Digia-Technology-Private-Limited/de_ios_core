import Foundation

private let log = DigiaLogger("analytics")

/// The analytics queue's SQL: one row per event, FIFO by insertion sequence.
///
/// Every method is one statement or one transaction and throws on SQLite
/// failure — degrading is ``SQLiteAnalyticsQueue``'s job, not this type's.
/// `created_at` is stored in milliseconds; ``QueueEntry`` carries seconds.
final class SQLiteQueueStore {
    static let table = "analytics_queue"
    /// Event IDs already imported from the legacy UserDefaults queue. See
    /// ``LegacyQueueImport``.
    static let importsTable = "analytics_queue_imports"

    /// Below SQLite's default host-parameter limit.
    private static let chunkSize = 500

    let connection: SQLiteConnection

    private init(connection: SQLiteConnection) {
        self.connection = connection
    }

    /// Creates the schema if needed and returns a store over [connection].
    static func attach(_ connection: SQLiteConnection) throws -> SQLiteQueueStore {
        try connection.execute("""
            CREATE TABLE IF NOT EXISTS \(table) (
                _id INTEGER PRIMARY KEY AUTOINCREMENT,
                event_id TEXT NOT NULL UNIQUE,
                payload TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS \(importsTable) (event_id TEXT PRIMARY KEY);
            """)
        return SQLiteQueueStore(connection: connection)
    }

    /// Inserts one already-encoded event and enforces [maxEvents] in the same
    /// transaction. A duplicate event ID keeps the existing row.
    func append(eventId: String, payloadJSON: String, createdAt: TimeInterval, maxEvents: Int) throws {
        let dropped = try connection.transaction {
            try insert(eventId: eventId, payloadJSON: payloadJSON, createdAt: createdAt, attempts: 0)
            return try prune(maxEvents)
        }
        logDropped(dropped, maxEvents)
    }

    /// Inserts [entries] in order, keeping their IDs, timestamps and attempts.
    func appendAll(_ entries: [QueueEntry], maxEvents: Int) throws {
        guard !entries.isEmpty else { return }
        let dropped = try connection.transaction {
            for entry in entries {
                guard let json = Self.encode(entry.payload) else { continue }
                try insert(eventId: entry.eventId, payloadJSON: json, createdAt: entry.createdAt, attempts: entry.attempts)
            }
            return try prune(maxEvents)
        }
        logDropped(dropped, maxEvents)
    }

    /// Up to [count] oldest entries. Rows whose payload no longer parses can
    /// never be sent, so they are deleted rather than returned.
    func peek(_ count: Int) throws -> [QueueEntry] {
        guard count > 0 else { return [] }
        var entries: [QueueEntry] = []
        var unreadable: [Int64] = []
        try connection.query(
            "SELECT _id, event_id, payload, created_at, attempts FROM \(Self.table) ORDER BY _id ASC LIMIT ?",
            [.int(Int64(count))]
        ) { row in
            if let entry = Self.entry(row, from: 1) {
                entries.append(entry)
            } else {
                unreadable.append(row.int64(0))
            }
        }
        if !unreadable.isEmpty {
            try deleteIn("_id", unreadable.map { .int($0) })
            log.w("Removed \(unreadable.count) unreadable analytics event(s)")
        }
        return entries
    }

    func remove(eventIds: [String]) throws {
        guard !eventIds.isEmpty else { return }
        try connection.transaction { try deleteIn("event_id", eventIds.map { .text($0) }) }
    }

    /// Increments the attempt counter of [eventIds] and returns those rows.
    func incrementAttempt(eventIds: [String]) throws -> [QueueEntry] {
        guard !eventIds.isEmpty else { return [] }
        return try connection.transaction {
            var updated: [QueueEntry] = []
            for chunk in Self.chunks(eventIds) {
                let placeholders = Self.placeholders(chunk.count)
                let arguments = chunk.map { SQLiteValue.text($0) }
                try connection.run(
                    "UPDATE \(Self.table) SET attempts = attempts + 1 WHERE event_id IN (\(placeholders))",
                    arguments
                )
                try connection.query(
                    "SELECT event_id, payload, created_at, attempts FROM \(Self.table) "
                        + "WHERE event_id IN (\(placeholders)) ORDER BY _id ASC",
                    arguments
                ) { row in
                    if let entry = Self.entry(row, from: 0) { updated.append(entry) }
                }
            }
            return updated
        }
    }

    func count() throws -> Int {
        var count = 0
        try connection.query("SELECT COUNT(*) FROM \(Self.table)") { count = Int($0.int64(0)) }
        return count
    }

    func clear() throws {
        try connection.run("DELETE FROM \(Self.table)")
    }

    // MARK: - Shared with the legacy import

    func insert(eventId: String, payloadJSON: String, createdAt: TimeInterval, attempts: Int) throws {
        try connection.run(
            "INSERT OR IGNORE INTO \(Self.table) (event_id, payload, created_at, attempts) VALUES (?, ?, ?, ?)",
            [.text(eventId), .text(payloadJSON), .int(Int64(createdAt * 1000)), .int(Int64(attempts))]
        )
    }

    /// Deletes everything older than the newest [maxEvents] rows, in one
    /// statement. Returns how many were dropped.
    func prune(_ maxEvents: Int) throws -> Int {
        try connection.run(
            "DELETE FROM \(Self.table) WHERE _id IN "
                + "(SELECT _id FROM \(Self.table) ORDER BY _id DESC LIMIT -1 OFFSET ?)",
            [.int(Int64(max(0, maxEvents)))]
        )
    }

    /// JSON for [payload], or nil when it holds a value JSON cannot represent.
    /// Checked first: `JSONSerialization` raises an Objective-C exception,
    /// which Swift cannot catch, on such a value.
    static func encode(_ payload: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Private

    private func deleteIn(_ column: String, _ values: [SQLiteValue]) throws {
        for chunk in Self.chunks(values) {
            try connection.run(
                "DELETE FROM \(Self.table) WHERE \(column) IN (\(Self.placeholders(chunk.count)))",
                chunk
            )
        }
    }

    private func logDropped(_ dropped: Int, _ maxEvents: Int) {
        if dropped > 0 {
            log.w("Queue exceeded its cap — dropping the oldest events (cap=\(maxEvents), dropped=\(dropped))")
        }
    }

    /// Reads event_id, payload, created_at, attempts starting at [first].
    private static func entry(_ row: SQLiteRow, from first: Int32) -> QueueEntry? {
        guard let eventId = row.text(first),
              let json = row.text(first + 1),
              let data = json.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return QueueEntry(
            eventId: eventId,
            payload: payload,
            createdAt: TimeInterval(row.int64(first + 2)) / 1000,
            attempts: Int(row.int64(first + 3))
        )
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    private static func chunks<T>(_ values: [T]) -> [[T]] {
        stride(from: 0, to: values.count, by: chunkSize).map {
            Array(values[$0..<min($0 + chunkSize, values.count)])
        }
    }
}
