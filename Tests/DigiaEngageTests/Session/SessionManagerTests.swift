import Foundation
import Testing

@testable import DigiaEngage

@Suite("SessionManager unit tests", .serialized)
struct SessionManagerTests {

    private func makeIsolatedStorage() -> (LocalStorage, UserDefaults) {
        let suiteName = "test_session_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let storage = UserDefaultsLocalStorage(defaults: defaults)
        return (storage, defaults)
    }

    @Test("session ID generated on first launch and persisted to disk")
    func sessionIdGeneratedAndPersisted() {
        let (storage, _) = makeIsolatedStorage()
        let currentTime: Int64 = 1_000_000
        let manager = SessionManager(
            storage: storage.scoped("session"),
            timeoutMs: 1_800_000,
            clock: { currentTime },
            observeLifecycle: false
        )

        let sessionId = manager.sessionId
        #expect(!sessionId.isEmpty)
        #expect(storage.scoped("session").string(forKey: "session_id") == sessionId)
        #expect(storage.scoped("session").string(forKey: "last_activity_ms") == String(currentTime))
        #expect(manager.lastActivityMs == currentTime)
    }

    @Test("resumes unexpired session if launched within inactivity timeout")
    func resumesUnexpiredSession() {
        let (storage, _) = makeIsolatedStorage()
        let sessionStore = storage.scoped("session")
        sessionStore.set("session-prev-123", forKey: "session_id")
        sessionStore.set(String(1_000_000), forKey: "last_activity_ms")

        // Relaunch at 1_000_000 + 10 min (600_000 ms)
        let manager = SessionManager(
            storage: storage.scoped("session"),
            timeoutMs: 1_800_000,
            clock: { 1_600_000 },
            observeLifecycle: false
        )

        #expect(manager.sessionId == "session-prev-123")
        #expect(manager.lastActivityMs == 1_600_000)
        #expect(sessionStore.string(forKey: "last_activity_ms") == "1600000")
    }

    @Test("rotates session if relaunched after inactivity timeout")
    func rotatesSessionAfterTimeout() {
        let (storage, _) = makeIsolatedStorage()
        let sessionStore = storage.scoped("session")
        sessionStore.set("session-prev-123", forKey: "session_id")
        sessionStore.set(String(1_000_000), forKey: "last_activity_ms")

        // Relaunch at 1_000_000 + 35 min (2_100_000 ms)
        let manager = SessionManager(
            storage: storage.scoped("session"),
            timeoutMs: 1_800_000,
            clock: { 3_100_000 },
            observeLifecycle: false
        )

        #expect(manager.sessionId != "session-prev-123")
        #expect(!manager.sessionId.isEmpty)
        #expect(sessionStore.string(forKey: "session_id") == manager.sessionId)
        #expect(manager.lastActivityMs == 3_100_000)
    }

    @Test("touch within timeout updates timestamp without rotating")
    func touchWithinTimeout() {
        let (storage, _) = makeIsolatedStorage()
        var currentTime: Int64 = 1_000_000
        let manager = SessionManager(
            storage: storage.scoped("session"),
            timeoutMs: 1_800_000,
            clock: { currentTime },
            observeLifecycle: false
        )

        let initialId = manager.sessionId
        currentTime += 100_000
        manager.touch()

        #expect(manager.sessionId == initialId)
        #expect(manager.lastActivityMs == currentTime)
        #expect(storage.scoped("session").string(forKey: "last_activity_ms") == String(currentTime))
    }

    @Test("touch after timeout rotates session and notifies listener")
    func touchAfterTimeout() {
        let (storage, _) = makeIsolatedStorage()
        var currentTime: Int64 = 1_000_000
        let manager = SessionManager(
            storage: storage.scoped("session"),
            timeoutMs: 1_800_000,
            clock: { currentTime },
            observeLifecycle: false
        )

        let initialId = manager.sessionId
        var rotatedCount = 0
        manager.addRotationListener { rotatedCount += 1 }

        currentTime += 2_000_000 // 33.3 minutes later
        manager.touch()

        #expect(manager.sessionId != initialId)
        #expect(rotatedCount == 1)
        #expect(manager.lastActivityMs == currentTime)
        #expect(storage.scoped("session").string(forKey: "session_id") == manager.sessionId)
    }

    @Test("reset forces new session and notifies listeners")
    func resetForcesNewSession() {
        let (storage, _) = makeIsolatedStorage()
        var currentTime: Int64 = 1_000_000
        let manager = SessionManager(
            storage: storage.scoped("session"),
            timeoutMs: 1_800_000,
            clock: { currentTime },
            observeLifecycle: false
        )

        let initialId = manager.sessionId
        var rotatedCount = 0
        manager.addRotationListener { rotatedCount += 1 }

        currentTime += 50_000
        manager.reset()

        #expect(manager.sessionId != initialId)
        #expect(rotatedCount == 1)
        #expect(manager.lastActivityMs == currentTime)
        #expect(storage.scoped("session").string(forKey: "session_id") == manager.sessionId)
    }

    @Test("maybeExpire rotates only if expired")
    func maybeExpireBehavior() {
        let (storage, _) = makeIsolatedStorage()
        var currentTime: Int64 = 1_000_000
        let manager = SessionManager(
            storage: storage.scoped("session"),
            timeoutMs: 1_800_000,
            clock: { currentTime },
            observeLifecycle: false
        )

        let initialId = manager.sessionId
        currentTime += 500_000
        manager.maybeExpire()
        #expect(manager.sessionId == initialId)

        currentTime += 1_500_000 // total delta 2_000_000 > 1_800_000
        manager.maybeExpire()
        #expect(manager.sessionId != initialId)
    }
}
