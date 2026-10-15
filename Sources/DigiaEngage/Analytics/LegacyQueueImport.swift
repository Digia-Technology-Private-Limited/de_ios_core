import Foundation

private let log = DigiaLogger("analytics")

/// Moves the pre-SQLite queue — one JSON array under [key] in [source] —
/// into SQLite, once.
///
/// Restart-safe: rows and import receipts commit in one transaction, and the
/// source key is deleted only after that commit succeeds. A receipt stops an
/// event from being imported twice even if the deletion never happens.
struct LegacyQueueImport {
    let source: LocalStorage
    var key = "queue"

    private struct Row {
        let eventId: String
        let payloadJSON: String
        let createdAtMs: Int64
        let attempts: Int64
    }

    /// Imports into [store], keeping at most [maxEvents] rows.
    ///
    /// Returns normally once the source is settled: imported, absent, or
    /// unreadable (then kept intact, never deleted). Throws when SQLite
    /// fails; the source is untouched and the import can run again later.
    func run(on store: SQLiteQueueStore, maxEvents: Int) throws {
        guard let raw = source.string(forKey: key) else { return }
        let rows: [Row]
        switch Self.parse(raw) {
        case .unreadable(let reason):
            log.w("Legacy analytics queue \(reason) — kept intact")
            return
        case .empty:
            source.removeObject(forKey: key)
            return
        case .rows(let parsed):
            rows = parsed
        }

        let connection = store.connection
        try connection.transaction {
            var imported = Set<String>()
            try connection.query("SELECT event_id FROM \(SQLiteQueueStore.importsTable)") { row in
                if let id = row.text(0) { imported.insert(id) }
            }
            let pending = rows.filter { !imported.contains($0.eventId) }
            guard !pending.isEmpty else { return }

            // Rebuild once, merging by timestamp. Existing rows win duplicates
            // so a replay cannot reset their attempts or payloads.
            var existing: [Row] = []
            try connection.query(
                "SELECT event_id, payload, created_at, attempts FROM \(SQLiteQueueStore.table) ORDER BY _id ASC"
            ) { row in
                if let id = row.text(0), let payload = row.text(1) {
                    existing.append(Row(eventId: id, payloadJSON: payload, createdAtMs: row.int64(2), attempts: row.int64(3)))
                }
            }
            var merged = existing
            var seen = Set(existing.map(\.eventId))
            for row in pending where seen.insert(row.eventId).inserted {
                merged.append(row)
            }
            // A stable sort keeps FIFO order for equal timestamps.
            let ordered = merged.enumerated()
                .sorted { ($0.element.createdAtMs, $0.offset) < ($1.element.createdAtMs, $1.offset) }
                .map(\.element)

            try connection.run("DELETE FROM \(SQLiteQueueStore.table)")
            for row in ordered.suffix(max(0, maxEvents)) {
                try connection.run(
                    "INSERT INTO \(SQLiteQueueStore.table) (event_id, payload, created_at, attempts) VALUES (?, ?, ?, ?)",
                    [.text(row.eventId), .text(row.payloadJSON), .int(row.createdAtMs), .int(row.attempts)]
                )
            }
            // Record even imports evicted by the cap; they must not reappear.
            for row in pending {
                try connection.run(
                    "INSERT OR IGNORE INTO \(SQLiteQueueStore.importsTable) (event_id) VALUES (?)",
                    [.text(row.eventId)]
                )
            }
        }
        // Reached only after a successful COMMIT.
        source.removeObject(forKey: key)
    }

    private enum Parsed {
        case unreadable(String)
        case empty
        case rows([Row])
    }

    private static func parse(_ raw: String) -> Parsed {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
        else { return .unreadable("is not valid JSON") }
        guard let items = json as? [Any] else { return .unreadable("is not a list") }
        if items.isEmpty { return .empty }

        var rows: [Row] = []
        for case let item as [String: Any] in items {
            guard let eventId = item["event_id"] as? String, !eventId.isEmpty,
                  let payload = item["payload"] as? [String: Any],
                  let payloadJSON = SQLiteQueueStore.encode(payload),
                  let createdAt = (item["created_at"] as? NSNumber)?.doubleValue
            else { continue }
            // The legacy queue stored seconds; tolerate milliseconds as well.
            let seconds = createdAt > 100_000_000_000 ? createdAt / 1000 : createdAt
            rows.append(Row(
                eventId: eventId,
                payloadJSON: payloadJSON,
                createdAtMs: Int64(seconds * 1000),
                attempts: Int64((item["attempts"] as? NSNumber)?.intValue ?? 0)
            ))
        }
        return rows.isEmpty ? .unreadable("has no valid entries") : .rows(rows)
    }
}
