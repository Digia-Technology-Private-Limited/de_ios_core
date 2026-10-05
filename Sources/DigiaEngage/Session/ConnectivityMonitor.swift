import Foundation
import Network

/// Notifies once when the network comes back, so pending session reports can
/// be flushed (issue #74). The reporter watches only while reports wait to be sent.
protocol ConnectivityMonitor: AnyObject, Sendable {
    /// Starts watching until `stop()`. Repeated calls are no-ops.
    func start(onRecovered: @escaping @Sendable () -> Void)
    /// Cancels the platform monitor. Safe when not started.
    func stop()
}

/// `NWPathMonitor` source: one notice per offline-to-online transition.
final class SystemConnectivityMonitor: ConnectivityMonitor, @unchecked Sendable {
    private let lock = NSLock()
    private var monitor: NWPathMonitor?
    private var onRecovered: (@Sendable () -> Void)?
    /// Recovery means an offline-to-online transition: the first `.unsatisfied`
    /// path arms the watch, so an online send failure is not retried before it.
    private var wasOffline = false

    func start(onRecovered: @escaping @Sendable () -> Void) {
        let monitor = lock.withLock { () -> NWPathMonitor? in
            guard self.monitor == nil else { return nil }
            self.onRecovered = onRecovered
            self.wasOffline = false
            let monitor = NWPathMonitor()
            self.monitor = monitor
            return monitor
        }
        guard let monitor else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handle(path)
        }
        monitor.start(queue: DispatchQueue(label: "tech.digia.engage.connectivity"))
    }

    func stop() {
        let monitor = lock.withLock { () -> NWPathMonitor? in
            onRecovered = nil
            defer { self.monitor = nil }
            return self.monitor
        }
        monitor?.cancel()
    }

    private func handle(_ path: NWPath) {
        if path.status == .satisfied {
            let callback = lock.withLock { () -> (@Sendable () -> Void)? in
                guard wasOffline, let onRecovered else { return nil }
                wasOffline = false
                return onRecovered
            }
            callback?()
        } else {
            lock.withLock { wasOffline = true }
        }
    }
}
