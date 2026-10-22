import Foundation
import Testing
@testable import DigiaEngage

@Suite("SQLiteAnalyticsQueue", .serialized)
struct SQLiteAnalyticsQueueTests {

    // MARK: - Helpers

    /// A database path removed (with its companions) when the test ends.
    private final class TempDatabase {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("analytics_\(UUID().uuidString).db").path

        deinit {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }

        func queue(
            maxEvents: Int = 5_000,
            legacyImport: LegacyQueueImport? = nil,
            opener: AnalyticsDatabaseOpener? = nil
        ) -> SQLiteAnalyticsQueue {
            SQLiteAnalyticsQueue(
                opener: opener ?? AnalyticsDatabaseOpener(resolvePath: { [path] in path }),
                maxEvents: maxEvents,
                legacyImport: legacyImport
            )
        }

        /// A second connection to the same file, for setting up conditions.
        func raw() throws -> SQLiteConnection { try SQLiteConnection.open(path: path) }

        /// Makes every insert into the queue fail, as a full disk would.
        func rejectWrites() throws {
            let connection = try raw()
            defer { connection.close() }
            try connection.execute(
                "CREATE TRIGGER reject BEFORE INSERT ON analytics_queue BEGIN SELECT RAISE(ABORT, 'disk full'); END"
            )
        }

        func acceptWrites() throws {
            let connection = try raw()
            defer { connection.close() }
            try connection.execute("DROP TRIGGER reject")
        }
    }

    /// An opener whose open fails the way a locked or unreadable file does.
    private func failingOpener() -> AnalyticsDatabaseOpener {
        AnalyticsDatabaseOpener(resolvePath: { throw SQLiteError(code: 14, message: "unable to open database file") })
    }

    private func entry(_ id: String, at createdAt: TimeInterval = 1_000, _ payload: [String: Any] = [:]) -> QueueEntry {
        var payload = payload
        payload["event_id"] = id
        return QueueEntry(eventId: id, payload: payload, createdAt: createdAt, attempts: 0)
    }

    private func ids(_ queue: any AnalyticsQueueProtocol, _ count: Int = 100) async -> [String] {
        await queue.peek(maxCount: count).map(\.eventId)
    }

    private func legacyStorage(_ entries: [[String: Any]]) -> LocalStorage {
        let storage = UserDefaultsLocalStorage(defaults: UserDefaults(suiteName: "digia.sqlite.test.\(UUID().uuidString)")!)
        let data = try! JSONSerialization.data(withJSONObject: entries)
        storage.set(String(data: data, encoding: .utf8), forKey: "queue")
        return storage
    }

    private func legacyEntry(_ id: String, createdAt: TimeInterval = 1, attempts: Int = 0) -> [String: Any] {
        ["event_id": id, "payload": ["event_id": id], "created_at": createdAt, "attempts": attempts]
    }

    // MARK: - Queue operations

    @Test("starts with length 0 and empty peek")
    func startsEmpty() async {
        let db = TempDatabase()
        let queue = db.queue()
        #expect(await queue.count() == 0)
        #expect(await queue.peek(maxCount: 10).isEmpty)
        await queue.close()
    }

    @Test("persists in FIFO order and survives a restart")
    func persistsAcrossRestart() async {
        let db = TempDatabase()
        let first = db.queue()
        first.append(entry("e1"), maxEvents: 100)
        first.append(entry("e2"), maxEvents: 100)
        #expect(await ids(first) == ["e1", "e2"])
        await first.close()

        let second = db.queue()
        #expect(await second.count() == 2)
        #expect(await ids(second) == ["e1", "e2"])
        await second.close()
    }

    @Test("drops the oldest events beyond the cap")
    func enforcesCap() async {
        let db = TempDatabase()
        let queue = db.queue()
        for i in 1...8 { queue.append(entry("e\(i)"), maxEvents: 5) }
        #expect(queue.size == 5)
        #expect(await ids(queue) == ["e4", "e5", "e6", "e7", "e8"])
        await queue.close()
    }

    @Test("remove and incrementAttempt touch only the named events")
    func removeAndRetry() async {
        let db = TempDatabase()
        let queue = db.queue()
        for i in 1...3 { queue.append(entry("e\(i)"), maxEvents: 100) }

        let updated = await queue.incrementAttempt(eventIds: ["e1", "e3"])
        #expect(updated.map(\.eventId) == ["e1", "e3"])
        #expect(updated.allSatisfy { $0.attempts == 1 })

        await queue.remove(eventIds: ["e2", "missing"])
        let remaining = await queue.peek(maxCount: 10)
        #expect(remaining.map(\.eventId) == ["e1", "e3"])
        #expect(remaining.map(\.attempts) == [1, 1])
        #expect(queue.size == 2)
        await queue.close()
    }

    @Test("clear empties the queue")
    func clearEmpties() async {
        let db = TempDatabase()
        let queue = db.queue()
        queue.append(entry("e1"), maxEvents: 100)
        queue.append(entry("e2"), maxEvents: 100)
        await queue.clear()
        #expect(await queue.count() == 0)
        #expect(await queue.peek(maxCount: 10).isEmpty)
        await queue.close()
    }

    @Test("a duplicate event id keeps the existing row and its retry count")
    func duplicateKeepsRow() async {
        let db = TempDatabase()
        let queue = db.queue()
        queue.append(entry("dup"), maxEvents: 100)
        queue.append(entry("other"), maxEvents: 100)
        await queue.incrementAttempt(eventIds: ["dup"])
        queue.append(entry("dup"), maxEvents: 100)
        #expect(await ids(queue) == ["dup", "other"])
        #expect(await queue.peek(maxCount: 1).first?.attempts == 1)
        #expect(await queue.count() == 2)
        await queue.close()
    }

    @Test("concurrent operations apply in call order")
    func concurrentOperationsInOrder() async {
        let db = TempDatabase()
        let queue = db.queue()
        queue.append(entry("sent-1"), maxEvents: 100)
        queue.append(entry("sent-2"), maxEvents: 100)

        // Issued without waiting in between, as a dispatch removing what it
        // sent races new captures.
        for i in 0..<10 { queue.append(entry("c\(i)"), maxEvents: 100) }
        async let removing: Void = queue.remove(eventIds: ["sent-1", "sent-2"])
        for i in 10..<20 { queue.append(entry("c\(i)"), maxEvents: 100) }
        async let retrying = queue.incrementAttempt(eventIds: ["c0", "c5"])
        _ = await (removing, retrying)

        let all = await queue.peek(maxCount: 50)
        #expect(all.map(\.eventId) == (0..<20).map { "c\($0)" })
        #expect(all.filter { $0.attempts == 1 }.map(\.eventId) == ["c0", "c5"])
        await queue.close()
    }

    @Test("a payload JSON cannot represent is dropped alone")
    func nonJSONPayloadDropped() async {
        let db = TempDatabase()
        let queue = db.queue()
        queue.append(entry("A"), maxEvents: 100)
        queue.append(entry("P", ["when": Date()]), maxEvents: 100)
        queue.append(entry("B"), maxEvents: 100)
        #expect(await ids(queue) == ["A", "B"])
        #expect(await queue.count() == 2)
        await queue.close()
    }

    @Test("peek deletes rows whose payload no longer parses")
    func unreadableRowsDeleted() async throws {
        let db = TempDatabase()
        let queue = db.queue()
        queue.append(entry("valid"), maxEvents: 100)
        _ = await queue.count()
        try db.raw().run(
            "INSERT INTO analytics_queue (event_id, payload, created_at) VALUES ('bad', '{broken', 0)"
        )
        #expect(await ids(queue) == ["valid"])
        #expect(await queue.count() == 1)
        await queue.close()
    }

    // MARK: - Legacy import

    @Test("imports the legacy queue on start and deletes its key")
    func importsLegacyQueue() async {
        let db = TempDatabase()
        let source = legacyStorage([
            legacyEntry("legacy-1", createdAt: 1_000, attempts: 1),
            legacyEntry("legacy-2", createdAt: 2_000, attempts: 2),
        ])
        let queue = db.queue(legacyImport: LegacyQueueImport(source: source))
        let entries = await queue.peek(maxCount: 10)
        #expect(entries.map(\.eventId) == ["legacy-1", "legacy-2"])
        #expect(entries.map(\.attempts) == [1, 2])
        #expect(entries.first?.createdAt == 1_000, "seconds survive the millisecond column")
        #expect(source.string(forKey: "queue") == nil)
        await queue.close()
    }

    @Test("orders older legacy events before newer stored ones")
    func legacyOrderedByTime() async throws {
        let db = TempDatabase()
        let queue = db.queue()
        queue.append(entry("new", at: 5_000), maxEvents: 100)
        _ = await queue.count()
        await queue.close()

        let raw = try db.raw()
        try LegacyQueueImport(source: legacyStorage([legacyEntry("old", createdAt: 1_000)]))
            .run(on: SQLiteQueueStore.attach(raw), maxEvents: 100)
        raw.close()

        let reopened = db.queue()
        #expect(await ids(reopened) == ["old", "new"])
        await reopened.close()
    }

    @Test("an existing duplicate keeps its retry state and receipts stop replays")
    func importIsIdempotent() async throws {
        let db = TempDatabase()
        let raw = try db.raw()
        defer { raw.close() }
        let store = try SQLiteQueueStore.attach(raw)
        try store.append(eventId: "dup", payloadJSON: #"{"event_id":"dup"}"#, createdAt: 1, maxEvents: 100)
        _ = try store.incrementAttempt(eventIds: ["dup"])

        // A source whose cleanup never lands: the key is never removed.
        let sticky = InMemoryLocalStorage()
        let data = try JSONSerialization.data(withJSONObject: [legacyEntry("dup"), legacyEntry("gone")])
        sticky.set(String(data: data, encoding: .utf8), forKey: "queue")
        sticky.dropWrites = true
        let legacyImport = LegacyQueueImport(source: sticky)

        try legacyImport.run(on: store, maxEvents: 100)
        #expect(try store.peek(10).map(\.attempts) == [1, 0])

        try store.remove(eventIds: ["gone"])
        try legacyImport.run(on: store, maxEvents: 100)
        #expect(try store.peek(10).map(\.eventId) == ["dup"], "a delivered import never reappears")
    }

    @Test("the cap keeps newer rows and evicted imports do not replay")
    func evictedImportsDoNotReplay() throws {
        let db = TempDatabase()
        let raw = try db.raw()
        defer { raw.close() }
        let store = try SQLiteQueueStore.attach(raw)
        try store.append(eventId: "new", payloadJSON: #"{"event_id":"new"}"#, createdAt: 5_000, maxEvents: 1)

        // A source whose cleanup never lands, as if interrupted each time.
        let sticky = InMemoryLocalStorage()
        let data = try JSONSerialization.data(withJSONObject: [legacyEntry("old", createdAt: 1_000)])
        sticky.set(String(data: data, encoding: .utf8), forKey: "queue")
        sticky.dropWrites = true
        let legacyImport = LegacyQueueImport(source: sticky)

        try legacyImport.run(on: store, maxEvents: 1)
        #expect(try store.peek(10).map(\.eventId) == ["new"])

        try store.remove(eventIds: ["new"])
        try legacyImport.run(on: store, maxEvents: 1)
        #expect(try store.peek(10).isEmpty, "an evicted import never reappears")
    }

    @Test("a failed import rolls back and keeps the source")
    func failedImportKeepsSource() throws {
        let db = TempDatabase()
        let raw = try db.raw()
        defer { raw.close() }
        let store = try SQLiteQueueStore.attach(raw)
        try raw.execute(
            "CREATE TRIGGER reject BEFORE INSERT ON analytics_queue BEGIN SELECT RAISE(ABORT, 'disk full'); END"
        )
        let source = legacyStorage([legacyEntry("old")])

        #expect(throws: SQLiteError.self) {
            try LegacyQueueImport(source: source).run(on: store, maxEvents: 100)
        }
        #expect(source.string(forKey: "queue") != nil)
        #expect(try store.count() == 0)

        try raw.execute("DROP TRIGGER reject")
        try LegacyQueueImport(source: source).run(on: store, maxEvents: 100)
        #expect(try store.peek(10).map(\.eventId) == ["old"])
        #expect(source.string(forKey: "queue") == nil)
    }

    @Test("unreadable legacy sources are kept intact")
    func unreadableSourcesKept() throws {
        let db = TempDatabase()
        let raw = try db.raw()
        defer { raw.close() }
        let store = try SQLiteQueueStore.attach(raw)
        for value in ["{not json", #"{"a":1}"#, #"[{"bad":true}]"#] {
            let source = UserDefaultsLocalStorage(defaults: UserDefaults(suiteName: "digia.keep.\(UUID().uuidString)")!)
            source.set(value, forKey: "queue")
            try LegacyQueueImport(source: source).run(on: store, maxEvents: 100)
            #expect(source.string(forKey: "queue") == value)
        }
    }

    @Test("receipts are cleared once a later launch finds the old key gone")
    func receiptsClearedAfterKeyGone() throws {
        let db = TempDatabase()
        let raw = try db.raw()
        defer { raw.close() }
        let store = try SQLiteQueueStore.attach(raw)
        let source = legacyStorage([legacyEntry("old")])

        try LegacyQueueImport(source: source).run(on: store, maxEvents: 100)
        #expect(source.string(forKey: "queue") == nil)
        #expect(try receipts(raw) == 1, "kept until the deletion is proven")

        try LegacyQueueImport(source: source).run(on: store, maxEvents: 100)  // next launch
        #expect(try receipts(raw) == 0)
        #expect(try store.peek(10).map(\.eventId) == ["old"])
    }

    // MARK: - Degradation

    @Test("degrades to memory while the database cannot open")
    func degradesWhileUnopenable() async {
        let queue = SQLiteAnalyticsQueue(opener: failingOpener())
        queue.append(entry("mem"), maxEvents: 100)
        #expect(await queue.isDegraded)
        #expect(await ids(queue) == ["mem"])
        #expect(queue.size == 1)
    }

    @Test("a failing open leaves the file untouched")
    func failingOpenKeepsFile() async {
        let db = TempDatabase()
        let first = db.queue()
        first.append(entry("kept"), maxEvents: 100)
        await first.close()

        let failing = db.queue(opener: failingOpener())
        failing.append(entry("mem"), maxEvents: 100)
        #expect(await failing.isDegraded)
        await failing.close()

        let reopened = db.queue()
        #expect(await ids(reopened) == ["kept"], "the stored event survived the failed open")
        await reopened.close()
    }

    @Test("recreates a corrupt database file")
    func recreatesCorruptFile() async throws {
        let db = TempDatabase()
        try Data([0x00, 0x11, 0x22, 0x33, 0xAA, 0xFF] + Array(repeating: 0x42, count: 4096))
            .write(to: URL(fileURLWithPath: db.path))
        let queue = db.queue()
        queue.append(entry("healed"), maxEvents: 100)
        #expect(await queue.isDegraded == false)
        #expect(await ids(queue) == ["healed"])
        await queue.close()
    }

    @Test("buffers in memory while SQLite rejects writes")
    func buffersWhileWritesFail() async throws {
        let db = TempDatabase()
        let queue = db.queue()
        queue.append(entry("stored"), maxEvents: 100)
        _ = await queue.count()
        try db.rejectWrites()
        queue.append(entry("mem"), maxEvents: 100)
        #expect(await ids(queue) == ["stored", "mem"])
        #expect(queue.size == 2)
        await queue.close()
    }

    @Test("moves buffered events into SQLite once it accepts writes again")
    func movesBufferedEvents() async throws {
        let db = TempDatabase()
        let queue = db.queue()
        queue.append(entry("stored"), maxEvents: 100)
        _ = await queue.count()
        try db.rejectWrites()
        queue.append(entry("mem-1"), maxEvents: 100)
        queue.append(entry("mem-2"), maxEvents: 100)
        _ = await queue.count()

        try db.acceptWrites()
        #expect(await ids(queue) == ["stored", "mem-1", "mem-2"])
        await queue.close()
        let reopened = db.queue()
        #expect(await reopened.count() == 3, "all three were written to disk")
        await reopened.close()
    }

    @Test("moving buffered events obeys the cap")
    func movingBufferedObeysCap() async throws {
        let db = TempDatabase()
        let queue = db.queue()
        queue.append(entry("seed"), maxEvents: 3)
        _ = await queue.count()
        try db.rejectWrites()
        for i in 0..<5 { queue.append(entry("cap-\(i)"), maxEvents: 3) }
        _ = await queue.count()

        try db.acceptWrites()
        #expect(await ids(queue) == ["cap-2", "cap-3", "cap-4"])
        await queue.close()
    }

    @Test("reopens after the cooldown and moves buffered events into SQLite")
    func reconnectsAfterCooldown() async {
        struct Locked: Error {}
        let db = TempDatabase()
        nonisolated(unsafe) var available = false
        nonisolated(unsafe) var now = Date(timeIntervalSince1970: 0)
        let queue = SQLiteAnalyticsQueue(
            opener: AnalyticsDatabaseOpener(resolvePath: { [path = db.path] in
                guard available else { throw Locked() }
                return path
            }),
            reconnectCooldown: 30,
            now: { now }
        )
        queue.append(entry("buffered-1"), maxEvents: 100)
        #expect(await queue.isDegraded)

        available = true
        queue.append(entry("buffered-2"), maxEvents: 100)
        #expect(await queue.isDegraded, "still inside the cooldown")

        now = now.addingTimeInterval(30)
        queue.append(entry("stored-3"), maxEvents: 100)
        #expect(await queue.isDegraded == false)
        #expect(await ids(queue) == ["buffered-1", "buffered-2", "stored-3"])
        await queue.close()

        let reopened = db.queue()
        #expect(await reopened.count() == 3, "all three were written to disk")
        await reopened.close()
    }

    // MARK: - Database setup

    @Test("the opened database uses WAL with synchronous FULL")
    func walWithFullSync() throws {
        let db = TempDatabase()
        let connection = try AnalyticsDatabaseOpener(resolvePath: { [path = db.path] in path }).open()
        defer { connection.close() }
        var sync = -1
        var journal = ""
        try connection.query("PRAGMA synchronous") { sync = Int($0.int64(0)) }
        try connection.query("PRAGMA journal_mode") { journal = $0.text(0) ?? "" }
        #expect(sync == 2, "2 = FULL")
        #expect(journal.lowercased() == "wal")
    }

    @Test("the schema version is recorded as user_version 1")
    func schemaVersionRecorded() throws {
        let db = TempDatabase()
        let raw = try db.raw()
        defer { raw.close() }
        _ = try SQLiteQueueStore.attach(raw)
        var version = 0
        try raw.query("PRAGMA user_version") { version = Int($0.int64(0)) }
        #expect(version == SQLiteQueueStore.schemaVersion)
        #expect(version == 1)
    }

    private func receipts(_ connection: SQLiteConnection) throws -> Int {
        var count = 0
        try connection.query("SELECT COUNT(*) FROM analytics_queue_imports") { count = Int($0.int64(0)) }
        return count
    }

    @Test("corruption is recognised from SQLite's own result code")
    func corruptionCodes() {
        #expect(SQLiteError(code: 11, message: "").isCorruption)
        #expect(SQLiteError(code: 26, message: "").isCorruption)
        #expect(SQLiteError(code: 11 | (1 << 8), message: "").isCorruption, "extended codes")
        #expect(SQLiteError(code: 13, message: "database or disk is full").isCorruption == false)
        #expect(SQLiteError(code: 5, message: "the payload said corrupt").isCorruption == false)
    }

    // MARK: - Memory queue

    @Test("memory queue drops the oldest events at its own limit")
    func memoryQueueLimit() async {
        let queue = MemoryAnalyticsQueue(limit: 3)
        for i in 1...5 { queue.append(entry("m\(i)"), maxEvents: 100) }
        #expect(await ids(queue) == ["m3", "m4", "m5"])
        #expect(await queue.incrementAttempt(eventIds: ["m4"]).map(\.attempts) == [1])
        await queue.remove(eventIds: ["m3"])
        #expect(queue.size == 2)
    }

    @Test("memory queue loses and resurrects nothing under concurrent appends and a remove")
    func memoryQueueConcurrency() async {
        let queue = MemoryAnalyticsQueue()
        let seeded = (0..<20).map { "seed-\($0)" }
        for id in seeded { queue.append(entry(id), maxEvents: 10_000) }

        let threads = 8
        let perThread = 50
        await withTaskGroup(of: Void.self) { group in
            for t in 0..<threads {
                group.addTask {
                    for i in 0..<perThread { queue.append(self.entry("t\(t)-\(i)"), maxEvents: 10_000) }
                }
            }
            group.addTask {
                await queue.remove(eventIds: seeded)
                for i in 0..<perThread { await queue.incrementAttempt(eventIds: ["t0-\(i)"]) }
            }
        }

        let ids = await queue.peek(maxCount: .max).map(\.eventId)
        #expect(ids.count == threads * perThread)
        #expect(Set(ids).count == ids.count)
        #expect(ids.filter { $0.hasPrefix("seed-") }.isEmpty)
    }
}
