import Foundation
#if canImport(UIKit)
import UIKit
#endif

public final class SessionManager: @unchecked Sendable {
    private static let keySessionId = "session_id"
    private static let keyLastActivityMs = "last_activity_ms"

    private let storage: LocalStorage
    private let clock: () -> Int64
    private let timeoutMs: Int64
    private let lock = NSLock()

    private var _sessionId: String
    private var _lastActivityMs: Int64
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
        let scopedStorage = storage.scoped("session")
        self.storage = scopedStorage
        self.timeoutMs = timeoutMs
        self.clock = clock

        let now = clock()
        let savedSessionId = scopedStorage.string(forKey: Self.keySessionId)
        let savedLastActivityStr = scopedStorage.string(forKey: Self.keyLastActivityMs)
        let savedLastActivity = savedLastActivityStr.flatMap { Int64($0) }

        if let savedSessionId, !savedSessionId.isEmpty,
           let savedLastActivity,
           (now - savedLastActivity) < timeoutMs {
            self._sessionId = savedSessionId
            self._lastActivityMs = now
            scopedStorage.setString(String(now), forKey: Self.keyLastActivityMs)
        } else {
            let newId = UUID().uuidString.lowercased()
            self._sessionId = newId
            self._lastActivityMs = now
            scopedStorage.setString(newId, forKey: Self.keySessionId)
            scopedStorage.setString(String(now), forKey: Self.keyLastActivityMs)
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
            storage.setString(String(now), forKey: Self.keyLastActivityMs)
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
        storage.setString(String(now), forKey: Self.keyLastActivityMs)
        lock.unlock()
    }

    private func rotateInternal(now: Int64) -> [() -> Void] {
        let newId = UUID().uuidString.lowercased()
        _sessionId = newId
        _lastActivityMs = now
        storage.setString(newId, forKey: Self.keySessionId)
        storage.setString(String(now), forKey: Self.keyLastActivityMs)
        return rotationListeners
    }

    private func notifyListeners(_ listeners: [() -> Void]) {
        for listener in listeners {
            listener()
        }
    }
}
