import Foundation

private let log = DigiaLogger("analytics")

/// The SDK's ``AnalyticsQueueProtocol``: events persist in SQLite, one row each.
///
/// All storage work — encoding, SQL, disk flushes, the legacy import — runs
/// on one serial background queue, in call order, so the main actor never
/// waits on disk. While SQLite cannot be opened or written, events go to a
/// bounded memory buffer and move into SQLite once it is reachable again;
/// reopening is retried at most once per cooldown.
///
/// One instance must own a database file for the life of the process. The
/// SDK keeps it on `SDKInstance`, across re-initialization.
final class SQLiteAnalyticsQueue: AnalyticsQueueProtocol, @unchecked Sendable {
    static let defaultReconnectCooldown: TimeInterval = 30
    /// Events held in memory while SQLite is unavailable.
    static let fallbackLimit = 100

    private let worker = DispatchQueue(label: "tech.digia.engage.analytics-queue", qos: .utility)
    private let opener: AnalyticsDatabaseOpener
    private let reconnectCooldown: TimeInterval
    private let now: () -> Date

    // Worker-only state.
    private var store: SQLiteQueueStore?
    private var fallback = BoundedEntryBuffer(limit: SQLiteAnalyticsQueue.fallbackLimit)
    private var pendingImport: LegacyQueueImport?
    private var cap: Int
    private var retryAt: Date?
    private var closed = false

    // Read from any thread, under [countLock]: stored events, and appends
    // handed to the worker but not yet written.
    private let countLock = NSLock()
    private var storedCount = 0
    private var pendingAppends = 0
    private var latestCap: Int

    /// Starts opening the database and importing [legacyImport] on the
    /// worker; returns at once.
    init(
        opener: AnalyticsDatabaseOpener,
        maxEvents: Int = 5_000,
        legacyImport: LegacyQueueImport? = nil,
        reconnectCooldown: TimeInterval = SQLiteAnalyticsQueue.defaultReconnectCooldown,
        now: @escaping () -> Date = Date.init
    ) {
        self.opener = opener
        self.cap = maxEvents
        self.latestCap = maxEvents
        self.pendingImport = legacyImport
        self.reconnectCooldown = reconnectCooldown
        self.now = now
        worker.async { [self] in
            _ = connectedStore()
            refreshCount()
        }
    }

    /// True while events are held in memory instead of SQLite.
    var isDegraded: Bool {
        get async { await onWorker { [self] in store == nil } }
    }

    var size: Int {
        countLock.withLock { min(storedCount + pendingAppends, latestCap) }
    }

    func append(_ entry: QueueEntry, maxEvents: Int) {
        countLock.withLock {
            pendingAppends += 1
            latestCap = maxEvents
        }
        worker.async { [self] in
            write(entry, maxEvents: maxEvents)
            refreshCount(completingAppend: true)
        }
    }

    func count() async -> Int {
        await onWorker { [self] in
            refreshCount()
            return size
        }
    }

    func peek(maxCount: Int) async -> [QueueEntry] {
        await onWorker { [self] in
            guard maxCount > 0 else { return [] }
            let stored = withStore("peek") { try $0.peek(maxCount) } ?? []
            refreshCount()
            if stored.count >= maxCount { return stored }
            return stored + fallback.prefix(maxCount - stored.count)
        }
    }

    func remove(eventIds: [String]) async {
        await onWorker { [self] in
            guard !eventIds.isEmpty else { return }
            withStore("remove") { try $0.remove(eventIds: eventIds) }
            fallback.remove(eventIds: Set(eventIds))
            refreshCount()
        }
    }

    @discardableResult
    func incrementAttempt(eventIds: [String]) async -> [QueueEntry] {
        await onWorker { [self] in
            guard !eventIds.isEmpty else { return [] }
            let stored = withStore("retry update") { try $0.incrementAttempt(eventIds: eventIds) } ?? []
            return stored + fallback.incrementAttempt(eventIds: Set(eventIds))
        }
    }

    func clear() async {
        await onWorker { [self] in
            withStore("clear") { try $0.clear() }
            fallback.removeAll()
            refreshCount()
        }
    }

    /// Closes the database. Further operations use memory only.
    func close() async {
        await onWorker { [self] in
            closed = true
            disconnect()
            fallback.removeAll()
            refreshCount()
        }
    }

    // MARK: - Worker

    private func onWorker<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            worker.async { continuation.resume(returning: body()) }
        }
    }

    private func write(_ entry: QueueEntry, maxEvents: Int) {
        cap = maxEvents
        // Encode before choosing a store. A payload JSON cannot represent can
        // never be sent; buffering it would fail every batch it joins.
        guard let json = SQLiteQueueStore.encode(entry.payload) else {
            log.e("Dropping event with a non-JSON payload (eventId=\(entry.eventId))")
            return
        }
        let stored: Bool? = withStore("append") {
            try $0.append(eventId: entry.eventId, payloadJSON: json, createdAt: entry.createdAt, maxEvents: maxEvents)
            return true
        }
        if stored != true {
            fallback.append(entry, maxEvents: maxEvents)
        }
    }

    /// Runs [op] on SQLite. Nil when SQLite is unavailable or [op] failed;
    /// the caller then uses the memory buffer.
    @discardableResult
    private func withStore<T>(_ what: String, _ op: (SQLiteQueueStore) throws -> T) -> T? {
        guard let store = connectedStore() else { return nil }
        do {
            return try op(store)
        } catch {
            log.w("Analytics \(what) failed on SQLite — using memory: \(error)")
            if (error as? SQLiteError)?.isCorruption == true {
                // The rows are unrecoverable. Recreate the file on the next
                // operation so events persist again.
                log.w("Analytics database corrupt — recreating it")
                disconnect()
                opener.wipe()
            }
            return nil
        }
    }

    /// The SQLite store, opening it when needed; nil while degraded.
    private func connectedStore() -> SQLiteQueueStore? {
        if closed { return nil }
        if store == nil {
            if let retryAt, now() < retryAt { return nil }
            connect()
        }
        guard let store else { return nil }
        drainFallback(into: store)
        return store
    }

    private func connect() {
        let connection: SQLiteConnection
        do {
            connection = try opener.open()
        } catch {
            markUnavailable(error)
            return
        }
        do {
            store = try SQLiteQueueStore.attach(connection)
            retryAt = nil
        } catch {
            connection.close()
            markUnavailable(error)
            return
        }
        runPendingImport()
    }

    private func markUnavailable(_ error: Error) {
        log.w("Analytics database unavailable — queueing in memory: \(error)")
        // Corruption surfacing after open (at schema setup) heals like at open.
        if (error as? SQLiteError)?.isCorruption == true { opener.wipe() }
        retryAt = now().addingTimeInterval(reconnectCooldown)
    }

    /// A failed import leaves the legacy source intact for the next launch;
    /// new events meanwhile go to SQLite and merge by timestamp later.
    private func runPendingImport() {
        guard let pending = pendingImport, let store else { return }
        pendingImport = nil
        do {
            try pending.run(on: store, maxEvents: cap)
        } catch {
            log.w("Legacy analytics queue import deferred: \(error)")
        }
    }

    private func drainFallback(into store: SQLiteQueueStore) {
        guard fallback.count > 0 else { return }
        let pending = fallback.entries
        do {
            try store.appendAll(pending, maxEvents: cap)
            fallback.remove(eventIds: Set(pending.map(\.eventId)))
            log.d("Moved \(pending.count) buffered event(s) into SQLite")
        } catch {
            log.d("Buffered events stay in memory for now: \(error)")
        }
    }

    private func disconnect() {
        store?.connection.close()
        store = nil
    }

    /// Re-reads the stored count. A completed append leaves [pendingAppends]
    /// in the same step, so [size] never counts it twice or not at all.
    private func refreshCount(completingAppend: Bool = false) {
        let stored = ((try? store?.count()) ?? 0) + fallback.count
        countLock.withLock {
            storedCount = stored
            if completingAppend { pendingAppends -= 1 }
        }
    }
}
