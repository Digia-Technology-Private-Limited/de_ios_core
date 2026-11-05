import Foundation
import Testing
@testable import DigiaEngage

/// Answers the userContext call and keeps each body it was sent.
private final class ContextServer: NetworkClient, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [[String: Any]] = []
    private var reply: () throws -> [String: Any] = { [:] }

    var sent: [[String: Any]] { lock.withLock { bodies } }

    func respond(with body: [String: Any]) {
        lock.withLock { reply = { body } }
    }

    func fail() {
        lock.withLock { reply = { throw URLError(.notConnectedToInternet) } }
    }

    func execute(request: NetworkRequest) async throws -> NetworkResponse {
        if let data = request.body, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            lock.withLock { bodies.append(json) }
        }
        let body = try lock.withLock { reply }()
        // The envelope the backend really replies with.
        let data = try JSONSerialization.data(withJSONObject: ["isSuccess": true, "data": ["response": body]])
        return NetworkResponse(statusCode: 200, headers: [:], body: data, isSuccessful: true)
    }

    func executeMultipart(request: MultipartUploadRequest) async throws -> NetworkResponse {
        NetworkResponse(statusCode: 200, headers: [:], body: nil, isSuccessful: true)
    }

    func openSseStream(request: NetworkRequest, handler: SseStreamHandler) -> CancellableSubscription {
        final class EmptySub: CancellableSubscription { func cancel() {} }
        return EmptySub()
    }
}

private final class RecordSink: DiagnosticSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TimelineRecord] = []
    var records: [TimelineRecord] { lock.withLock { stored } }
    func accepts(_ record: TimelineRecord) -> Bool { true }
    func emit(_ record: TimelineRecord) { lock.withLock { stored.append(record) } }
}

private func same(_ a: Any?, _ b: [String: Any]) -> Bool {
    guard let a = a as? [String: Any] else { return false }
    return NSDictionary(dictionary: a).isEqual(to: b)
}

/// Flutter: `test/user_context_manager_test.dart`.
@MainActor
@Suite("UserContextManager", .serialized)
struct DMCUserContextManagerTests {
    private let server = ContextServer()
    private let storage = UserDefaultsLocalStorage(defaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!)

    private func manager(
        reply: [String: Any] = ["campaigns": [String](), "attributes": [String: Any](), "expiresInSeconds": 900],
        restoredUserId: String? = nil
    ) -> UserContextManager {
        server.respond(with: reply)
        let manager = UserContextManager(storage: storage, networkClient: server)
        manager.configure(restoredUserId: restoredUserId)
        return manager
    }

    @Test("attributes merge across calls rather than replacing")
    func attributesMerge() async {
        let manager = manager()
        await manager.onUserIdChanged("u1")

        await manager.setUserAttributes(["plan": "pro"])
        await manager.setUserAttributes(["cart": "3"])

        // A screen sending 'cart' must not clear the 'plan' another screen set.
        #expect(same(manager.attributes, ["plan": "pro", "cart": "3"]))
        #expect(same(server.sent.last?["attributes"], ["plan": "pro", "cart": "3"]))
    }

    @Test("sends the whole map, not a delta, so a failed send self-heals")
    func sendsWholeMap() async {
        let manager = manager()
        await manager.onUserIdChanged("u1")

        await manager.setUserAttributes(["a": "1"])
        await manager.setUserAttributes(["b": "2"])

        #expect(same(server.sent.last?["attributes"], ["a": "1", "b": "2"]))
    }

    @Test("skips the request when nothing changed and the cache is valid")
    func skipsWhenNothingChanged() async {
        let manager = manager()
        await manager.onUserIdChanged("u1")
        let afterIdentify = server.sent.count

        // Same values again: a returning user must not put a write on the app-start path.
        await manager.setUserAttributes(["plan": "pro"])
        let afterFirst = server.sent.count
        await manager.setUserAttributes(["plan": "pro"])

        #expect(afterFirst > afterIdentify)
        #expect(server.sent.count == afterFirst)
    }

    @Test("app-supplied attributes win over imported ones")
    func appAttributesWin() async {
        let manager = manager(reply: [
            "campaigns": [String](),
            "attributes": ["city": "Gurugram", "country": "India"],
            "expiresInSeconds": 900,
        ])
        await manager.onUserIdChanged("u1")
        await manager.setUserAttributes(["city": "Delhi"])

        #expect(manager.resolvedAttributes["city"] == "Delhi")
        #expect(manager.resolvedAttributes["country"] == "India")
    }

    @Test("clearing the user drops the context and the attributes")
    func clearingDropsContext() async {
        let manager = manager(reply: [
            "campaigns": ["c1"], "attributes": ["city": "Gurugram"], "expiresInSeconds": 900,
        ])
        await manager.onUserIdChanged("u1")
        await manager.setUserAttributes(["plan": "pro"])
        #expect(manager.eligibleCampaigns == ["c1"])

        await manager.onUserIdChanged(nil)

        // The anonymous id survives logout, so anything left here would be
        // inherited by whoever logs in next.
        #expect(manager.attributes.isEmpty)
        #expect(manager.resolvedAttributes.isEmpty)
        #expect(manager.eligibleCampaigns.isEmpty)
    }

    @Test("a cached context survives a failed refresh")
    func cachedContextSurvivesFailure() async {
        let manager = manager(reply: [
            "campaigns": ["c1"], "attributes": ["city": "Gurugram"], "expiresInSeconds": 900,
        ])
        await manager.onUserIdChanged("u1")

        server.fail()
        await manager.refresh(force: true)

        #expect(manager.eligibleCampaigns == ["c1"])
        #expect(manager.resolvedAttributes["city"] == "Gurugram")
    }

    @Test("makes no request at all until a user is identified")
    func noRequestWithoutUser() async {
        let manager = manager()

        await manager.setUserAttributes(["plan": "pro"])

        #expect(server.sent.isEmpty)
    }

    @Test("an expired cache is refreshed even when nothing else changed")
    func expiredCacheRefreshes() async {
        var now: Int64 = 1_000_000
        server.respond(with: ["campaigns": ["c1"], "attributes": [String: Any](), "expiresInSeconds": 900])
        let manager = UserContextManager(storage: storage, networkClient: server, nowMs: { now })
        manager.configure(restoredUserId: nil)
        await manager.onUserIdChanged("u1")
        #expect(manager.contextState == "fresh")
        let first = server.sent.count

        await manager.refresh()
        #expect(server.sent.count == first)

        now += 901_000
        #expect(manager.contextState == "stale")
        #expect(manager.needsRefresh)
        await manager.refresh()
        #expect(server.sent.count == first + 1)
    }

    @Test("a change of user is not answered with the previous user's context")
    func previousUserDroppedAtOnce() async {
        let manager = manager(reply: ["campaigns": ["c1"], "attributes": ["plan": "pro"], "expiresInSeconds": 900])
        await manager.onUserIdChanged("u1")
        #expect(manager.eligibleCampaigns == ["c1"])

        manager.dropPreviousUser("u2")

        #expect(manager.eligibleCampaigns.isEmpty)
        #expect(manager.resolvedValues.isEmpty)
    }

    @Suite("typed attributes")
    @MainActor
    struct Typed {
        private let server = ContextServer()
        private let storage = UserDefaultsLocalStorage(defaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!)

        @Test("keep their type on the wire, in storage and for rules")
        func keepType() async {
            server.respond(with: ["campaigns": [String](), "attributes": ["score": 7, "vip": true], "expiresInSeconds": 900])
            let manager = UserContextManager(storage: storage, networkClient: server)
            manager.configure(restoredUserId: nil)
            await manager.onUserIdChanged("u1")

            await manager.setUserAttributes([
                "plan": "gold", "cart_total": 520.5, "orders": 3, "beta": false, "tags": ["a", "b"] as [Any],
            ])

            let typed: [String: Any] = [
                "plan": "gold", "cart_total": 520.5, "orders": 3, "beta": false, "tags": ["a", "b"],
            ]
            #expect(same(server.sent.last?["attributes"], typed))
            #expect(same(manager.resolvedValues, typed.merging(["score": 7, "vip": true]) { a, _ in a }))
            #expect(manager.resolvedAttributes["orders"] == "3")

            manager.configure(restoredUserId: "u1")
            #expect(same(manager.attributes, typed))
        }

        @Test("drop other values with a log line each")
        func dropOthers() async {
            server.respond(with: ["campaigns": [String](), "attributes": [String: Any](), "expiresInSeconds": 900])
            let sink = RecordSink()
            DigiaLogger.registerSink(sink)
            defer { DigiaLogger.unregisterSink(sink) }
            let manager = UserContextManager(storage: storage, networkClient: server)
            manager.configure(restoredUserId: nil)
            await manager.onUserIdChanged("u1")

            await manager.setUserAttributes([
                "ok": "yes",
                "map": ["a": 1],
                "mixed": ["a", 1] as [Any],
                "nan": Double.nan,
                "when": Date(timeIntervalSince1970: 0),
            ])

            #expect(same(manager.attributes, ["ok": "yes"]))
            #expect(same(server.sent.last?["attributes"], ["ok": "yes"]))
            let dropped = sink.records.filter { $0.message.contains("dropped") }
            #expect(dropped.count == 4)
        }
    }

    @Suite("userHash")
    @MainActor
    struct Hash {
        private let server = ContextServer()
        private let storage = UserDefaultsLocalStorage(defaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!)

        private func make(verified: Bool? = nil) -> UserContextManager {
            var reply: [String: Any] = ["campaigns": [String](), "attributes": [String: Any](), "expiresInSeconds": 900]
            if let verified { reply["verified"] = verified }
            server.respond(with: reply)
            let manager = UserContextManager(storage: storage, networkClient: server)
            manager.configure(restoredUserId: nil)
            return manager
        }

        @Test("is sent with the user and restored by configure")
        func sentAndRestored() async {
            let manager = make()
            await manager.onUserIdChanged("u1", userHash: "abc")
            #expect(server.sent.last?["userHash"] as? String == "abc")

            manager.configure(restoredUserId: "u1", restoredUserHash: "abc")
            await manager.refresh(force: true)
            #expect(server.sent.last?["userHash"] as? String == "abc")
        }

        @Test("is not sent after a switch to a user without one")
        func notSentAfterSwitch() async {
            let manager = make()
            await manager.onUserIdChanged("u1", userHash: "abc")
            await manager.onUserIdChanged("u2")

            #expect(server.sent.last?["userId"] as? String == "u2")
            #expect(server.sent.last?["userHash"] == nil)
        }

        @Test("verified false reports one health event and one line per session")
        func unverifiedReportedOnce() async {
            let sink = RecordSink()
            DigiaLogger.registerSink(sink)
            defer { DigiaLogger.unregisterSink(sink) }
            let manager = make(verified: false)

            await manager.onUserIdChanged("u1", userHash: "bad")
            await manager.refresh(force: true)

            let unverified = sink.records.filter { $0.reason?.wire == "user_hash_unverified" }
            #expect(unverified.count == 1)
            let leaked = sink.records.filter { $0.message.contains("verified=") }
            #expect(leaked.isEmpty)
        }

        @Test("verified false without a hash reports nothing")
        func unverifiedWithoutHash() async {
            let sink = RecordSink()
            DigiaLogger.registerSink(sink)
            defer { DigiaLogger.unregisterSink(sink) }
            let manager = make(verified: false)

            await manager.onUserIdChanged("u1")

            let unverified = sink.records.filter { $0.reason?.wire == "user_hash_unverified" }
            #expect(unverified.isEmpty)
        }
    }
}
