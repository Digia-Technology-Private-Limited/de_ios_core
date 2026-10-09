import Foundation
import XCTest

@testable import DigiaEngage

// Fakes for the session-and-identity scenario tests (ai_docs/session-identity-test-scenarios.md §3).
// Written fresh for these tests; nothing here reads UserDefaults or UIApplication.

/// Asha's phone clock, in milliseconds since the epoch. `at(10, 0)` is 10:00 on a fixed day.
final class TestClock: @unchecked Sendable {
    static let day: Int64 = 1_800_000_000_000 - (1_800_000_000_000 % 86_400_000)

    static func at(_ h: Int64, _ m: Int64, _ s: Int64 = 0, _ ms: Int64 = 0) -> Int64 {
        day + ((h * 60 + m) * 60 + s) * 1000 + ms
    }

    private let lock = NSLock()
    private var value: Int64

    init(_ h: Int64 = 10, _ m: Int64 = 0, _ s: Int64 = 0, _ ms: Int64 = 0) {
        value = Self.at(h, m, s, ms)
    }

    var now: Int64 { lock.withLock { value } }

    func set(_ h: Int64, _ m: Int64, _ s: Int64 = 0, _ ms: Int64 = 0) {
        lock.withLock { value = Self.at(h, m, s, ms) }
    }

    func setRaw(_ ms: Int64) { lock.withLock { value = ms } }

    /// Race tests only (S58): a short real pause on every read. The session reads the clock
    /// inside its lock, just before the expiry check, so without the lock every racing thread
    /// would reach that check together; with it, they queue. Set before the threads start.
    var readPauseMicros: UInt32 = 0

    var closure: () -> Int64 {
        { [self] in
            if readPauseMicros > 0 { usleep(readPauseMicros) }
            return now
        }
    }
}

/// The raw values behind one store, shared by the `LocalStorage` and `MigrationStore` fakes
/// so a migration and the managers that read after it see the same data.
final class StorageBacking: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    subscript(key: String) -> Any? {
        get { lock.withLock { values[key] } }
        set { lock.withLock { values[key] = newValue } }
    }

    var keys: [String] { lock.withLock { Array(values.keys) } }
}

/// In-memory `LocalStorage`. `dropWrites` models a full disk: writes report nothing and keep nothing.
final class InMemoryLocalStorage: LocalStorage, @unchecked Sendable {
    let backing: StorageBacking
    private let lock = NSLock()
    private var _dropWrites = false

    init(_ backing: StorageBacking = StorageBacking()) {
        self.backing = backing
    }

    var dropWrites: Bool {
        get { lock.withLock { _dropWrites } }
        set { lock.withLock { _dropWrites = newValue } }
    }

    private func write(_ value: Any?, _ key: String) {
        guard !dropWrites else { return }
        backing[key] = value
    }

    func string(forKey key: String) -> String? {
        switch backing[key] {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }
    func set(_ value: String?, forKey key: String) { write(value, key) }
    func bool(forKey key: String) -> Bool { (backing[key] as? Bool) ?? false }
    func set(_ value: Bool, forKey key: String) { write(value, key) }
    func integer(forKey key: String) -> Int { (backing[key] as? Int) ?? 0 }
    func set(_ value: Int, forKey key: String) { write(value, key) }
    func double(forKey key: String) -> Double { (backing[key] as? Double) ?? 0 }
    func set(_ value: Double, forKey key: String) { write(value, key) }
    func data(forKey key: String) -> Data? { backing[key] as? Data }
    func set(_ value: Data?, forKey key: String) { write(value, key) }
    func removeObject(forKey key: String) { write(nil, key) }
}

/// In-memory `MigrationStore` with UserDefaults' type rules (plan SR6): `string` returns a number
/// as text, `bool` reads the strings "YES", "true" and "1" as true, `integer` parses text.
final class FakeMigrationStore: MigrationStore {
    let backing: StorageBacking
    /// Keys whose writes don't read back, to model a value that fails to copy.
    var unwritableKeys: Set<String> = []
    private(set) var reads: [String] = []

    init(_ backing: StorageBacking = StorageBacking()) {
        self.backing = backing
    }

    var allKeys: [String] { backing.keys }
    func hasValue(forKey key: String) -> Bool { backing[key] != nil }

    func string(forKey key: String) -> String? {
        reads.append(key)
        switch backing[key] {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    func data(forKey key: String) -> Data? {
        reads.append(key)
        return backing[key] as? Data
    }

    func bool(forKey key: String) -> Bool {
        reads.append(key)
        switch backing[key] {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return ["yes", "true", "1"].contains(s.lowercased())
        default: return false
        }
    }

    func integer(forKey key: String) -> Int {
        reads.append(key)
        switch backing[key] {
        case let i as Int: return i
        case let s as String: return Int(s) ?? 0
        default: return 0
        }
    }

    func set(_ value: String, forKey key: String) { store(value, key) }
    func set(_ value: Bool, forKey key: String) { store(value, key) }
    func set(_ value: Int, forKey key: String) { store(value, key) }
    func removeValue(forKey key: String) { backing[key] = nil }

    private func store(_ value: Any, _ key: String) {
        guard !unwritableKeys.contains(key) else { return }
        backing[key] = value
    }
}

/// What one session report looked like on the wire.
struct SentReport: Equatable {
    let sessionId: String
    let userId: String?
    let anonymousId: String
    let occurredAt: String?

    init?(body: Data?) {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let sid = json["session_id"] as? String
        else { return nil }
        sessionId = sid
        userId = json["user_id"] as? String
        anonymousId = json["anonymous_id"] as? String ?? ""
        occurredAt = json["occurred_at"] as? String
    }
}

/// Records every request and answers with a scripted outcome: an HTTP status, or no response.
final class FakeNetworkClient: NetworkClient, @unchecked Sendable {
    enum Answer { case status(Int), noResponse }

    private let lock = NSLock()
    private var _attempts: [SentReport] = []
    private var _answer: (SentReport) -> Answer = { _ in .status(200) }
    private var gate: CheckedContinuation<Void, Never>?
    private var holding = false
    private var released = false
    private var onHold: (() -> Void)?

    /// Every report the client was asked to send, in order, whatever the answer.
    var attempts: [SentReport] { lock.withLock { _attempts } }
    /// The session IDs of every attempt.
    var attemptedSessions: [String] { attempts.map(\.sessionId) }

    func answer(_ rule: @escaping (SentReport) -> Answer) { lock.withLock { _answer = rule } }
    func answerAll(_ answer: Answer) { self.answer { _ in answer } }

    /// The next request waits until `release()`; `started` runs when it arrives.
    func holdNext(started: @escaping () -> Void) {
        lock.withLock { holding = true; released = false; onHold = started }
    }

    func release() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            released = true
            defer { gate = nil }
            return gate
        }
        continuation?.resume()
    }

    func execute(request: NetworkRequest) async throws -> NetworkResponse {
        let report = SentReport(body: request.body)
        let (rule, hold, started): ((SentReport) -> Answer, Bool, (() -> Void)?) = lock.withLock {
            if let report { _attempts.append(report) }
            let h = holding
            holding = false
            return (_answer, h, onHold)
        }
        if hold {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    if released { return true }
                    gate = c
                    return false
                }
                started?()
                if resumeNow { c.resume() }
            }
        }
        switch report.map(rule) ?? .status(200) {
        case let .status(code):
            return NetworkResponse(statusCode: code, headers: [:], body: nil)
        case .noResponse:
            throw URLError(.notConnectedToInternet)
        }
    }

    func executeMultipart(request: MultipartUploadRequest) async throws -> NetworkResponse {
        NetworkResponse(statusCode: 200, headers: [:], body: nil)
    }

    func openSseStream(request: NetworkRequest, handler: any SseStreamHandler) -> any CancellableSubscription {
        NoopSubscription()
    }
}

final class NoopSubscription: CancellableSubscription, @unchecked Sendable {
    func cancel() {}
}

/// A `ConnectivityMonitor` the test starts and drives.
final class FakeConnectivityMonitor: ConnectivityMonitor, @unchecked Sendable {
    private let lock = NSLock()
    private var recovery: (@Sendable () -> Void)?

    var started: Bool { lock.withLock { recovery != nil } }

    func start(onRecovered: @escaping @Sendable () -> Void) {
        lock.withLock { recovery = onRecovered }
    }

    func stop() {
        lock.withLock { recovery = nil }
    }

    /// Simulates the network coming back.
    func recover() {
        let callback = lock.withLock { recovery }
        callback?()
    }
}

/// A rotation listener that records each call and the session ID it saw at that moment.
final class RecordingListener: @unchecked Sendable {
    private let lock = NSLock()
    private var _seen: [String] = []

    var calls: Int { lock.withLock { _seen.count } }
    var seenSessionIds: [String] { lock.withLock { _seen } }

    func attach(to manager: SessionManager) {
        manager.addRotationListener { [weak self, weak manager] in
            let sid = manager?.sessionId ?? ""
            self?.lock.withLock { self?._seen.append(sid) }
        }
    }
}

/// A settable session ID for reporter-only tests.
final class SessionIdBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String
    init(_ value: String) { _value = value }
    var value: String {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// The session-and-identity graph as the composition root builds it, over fakes:
/// storage scoped per domain, `SessionManager` with `observeLifecycle: false`, and
/// `SessionIdentityWiring.attach()`.
final class SessionIdentityHarness {
    let storage: InMemoryLocalStorage
    let clock: TestClock
    let network: FakeNetworkClient
    let identity: IdentityManager
    let session: SessionManager
    let reporter: SessionReporter
    let connectivity = FakeConnectivityMonitor()
    let rotations = RecordingListener()

    init(
        storage: InMemoryLocalStorage = InMemoryLocalStorage(),
        clock: TestClock = TestClock(),
        network: FakeNetworkClient = FakeNetworkClient(),
        deviceId: String = "D1",
        attach: Bool = true
    ) {
        self.storage = storage
        self.clock = clock
        self.network = network
        identity = IdentityManager(storage: storage.scoped("identity"), idGenerator: { deviceId })
        session = SessionManager(storage: storage.scoped("session"), clock: clock.closure, observeLifecycle: false)
        let session = session
        let identity = identity
        reporter = SessionReporter(
            sessionId: { [weak session] in session?.sessionId ?? "" },
            anonymousId: { [weak identity] in identity?.deviceId ?? "" },
            userId: { [weak identity] in identity?.userId },
            context: [:],
            networkClient: network,
            storage: storage.scoped("session"),
            connectivityMonitor: connectivity
        )
        rotations.attach(to: session)
        if attach {
            SessionIdentityWiring(identityManager: identity, sessionManager: session, sessionReporter: reporter).attach()
        }
    }

    /// Waits for every report scheduled so far. The reporter runs its work one at a time, in
    /// call order, so a flush queued now finishes after them. Note: the flush itself retries the
    /// pending list.
    func settle() async {
        await reporter.flush().value
    }
}

/// Reads the reporter's pending list back from storage, as session IDs.
func pendingSessionIds(_ storage: LocalStorage) -> [String] {
    guard let raw = storage.string(forKey: "session.\(SessionReporter.keyPendingReport)"),
          let list = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String]
    else { return [] }
    return list.compactMap { SentReport(body: Data($0.utf8))?.sessionId }
}

func makeReporter(
    storage: InMemoryLocalStorage,
    network: FakeNetworkClient,
    session: SessionIdBox,
    userId: String? = nil,
    connectivity: ConnectivityMonitor? = nil
) -> SessionReporter {
    SessionReporter(
        sessionId: { session.value },
        anonymousId: { "D1" },
        userId: { userId },
        context: [:],
        networkClient: network,
        storage: storage.scoped("session"),
        connectivityMonitor: connectivity
    )
}
