import Foundation

final class AssistedGeometryDiagnosticsV1: @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private var entries: [AssistedGeometryTraceV1] = []
    private var observers: [UUID: (AssistedGeometryTraceV1) -> Void] = [:]

    init(capacity: Int = 100) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    func append(_ trace: AssistedGeometryTraceV1) {
        lock.lock()
        if entries.count == capacity { entries.removeFirst() }
        entries.append(trace)
        let callbacks = Array(observers.values)
        lock.unlock()
        callbacks.forEach { $0(trace) }
    }

    func snapshot() -> [AssistedGeometryTraceV1] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func clear() {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func observe(_ callback: @escaping (AssistedGeometryTraceV1) -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        observers[token] = callback
        lock.unlock()
        return token
    }

    func removeObserver(_ token: UUID) {
        lock.lock()
        observers.removeValue(forKey: token)
        lock.unlock()
    }
}
