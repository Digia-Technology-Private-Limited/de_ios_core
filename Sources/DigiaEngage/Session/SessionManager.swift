import Foundation
#if canImport(UIKit)
import UIKit
#endif

public final class SessionManager: @unchecked Sendable {
    private static let keySessionId = "session_id"
    private static let keyLastActivityMs = "last_activity_ms"
    /// `touch()` runs on every tracked event; the last-activity time reaches
    /// disk at most this often (and always on background). In-process expiry
    /// reads the in-memory time, so only a cross-launch resume sees the lag.
    private static let persistIntervalMs: Int64 = 10_000

    private let storage: LocalStorage
    private let clock: () -> Int64
    private let timeoutMs: Int64
    private let lock = NSLock()

    private var _sessionId: String
    private var _lastActivityMs: Int64
    private var persistedActivityMs: Int64
    /// Whether construction resumed the persisted session rather than starting
    /// a new one. A resumed session was already reported by an earlier launch.
    let resumedAtStartup: Bool
    private var rotationListeners: [() -> Void] = []
    #if canImport(UIKit)
    private var observers: [NSObjectProtocol] = []
    #endif

    init(
        storage: LocalStorage,
        timeoutMs: Int64 = 30 * 60 * 1000,
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        observeLifecycle: Bool = true
    ) {
        self.storage = storage
        self.timeoutMs = timeoutMs
        self.clock = clock

        let now = clock()
        let savedSessionId = storage.string(forKey: Self.keySessionId)
        let savedLastActivityStr = storage.string(forKey: Self.keyLastActivityMs)
        let savedLastActivity = savedLastActivityStr.flatMap { Int64($0) }

        if let savedSessionId, !savedSessionId.isEmpty,
           let savedLastActivity,
           (now - savedLastActivity) < timeoutMs {
            self._sessionId = savedSessionId
            self._lastActivityMs = now
            self.persistedActivityMs = now
            self.resumedAtStartup = true
            storage.setString(String(now), forKey: Self.keyLastActivityMs)
        } else {
            let newId = UUID().uuidString.lowercased()
            self._sessionId = newId
            self._lastActivityMs = now
            self.persistedActivityMs = now
            self.resumedAtStartup = false
            storage.setString(newId, forKey: Self.keySessionId)
            storage.setString(String(now), forKey: Self.keyLastActivityMs)
        }

        #if canImport(UIKit)
        if observeLifecycle {
            let center = NotificationCenter.default
            let fObs = center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.maybeExpire()
            }
            let bObs = center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.onBackground()
            }
            self.observers = [fObs, bObs]
        }
        #endif
    }

    deinit {
        #if canImport(UIKit)
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        #endif
    }

    public var sessionId: String {
        lock.lock()
        defer { lock.unlock() }
        return _sessionId
    }

    public var lastActivityMs: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return _lastActivityMs
    }

    public func touch() {
        lock.lock()
        let now = clock()
        if (now - _lastActivityMs) >= timeoutMs {
            let listeners = rotateInternal(now: now)
            lock.unlock()
            notifyListeners(listeners)
        } else {
            _lastActivityMs = now
            if now - persistedActivityMs >= Self.persistIntervalMs {
                persistLastActivity(now)
            }
            lock.unlock()
        }
    }

    public func maybeExpire() {
        lock.lock()
        let now = clock()
        if (now - _lastActivityMs) >= timeoutMs {
            let listeners = rotateInternal(now: now)
            lock.unlock()
            notifyListeners(listeners)
        } else {
            lock.unlock()
        }
    }

    public func reset() {
        lock.lock()
        let now = clock()
        let listeners = rotateInternal(now: now)
        lock.unlock()
        notifyListeners(listeners)
    }

    public func addRotationListener(_ listener: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        rotationListeners.append(listener)
    }

    private func onBackground() {
        lock.lock()
        let now = clock()
        _lastActivityMs = now
        persistLastActivity(now)
        lock.unlock()
    }

    /// Caller holds `lock`.
    private func persistLastActivity(_ now: Int64) {
        persistedActivityMs = now
        storage.setString(String(now), forKey: Self.keyLastActivityMs)
    }

    private func rotateInternal(now: Int64) -> [() -> Void] {
        let newId = UUID().uuidString.lowercased()
        _sessionId = newId
        _lastActivityMs = now
        storage.setString(newId, forKey: Self.keySessionId)
        persistLastActivity(now)
        return rotationListeners
    }

    private func notifyListeners(_ listeners: [() -> Void]) {
        for listener in listeners {
            listener()
        }
    }
}
