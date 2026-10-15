import Foundation
import Network

/// Whether the device has a network, so analytics can pause while offline
/// instead of spending retries, and send as soon as the network returns.
protocol NetworkMonitor: AnyObject, Sendable {
    /// False only when the OS reports no usable network.
    var isOnline: Bool { get }
    /// Starts reporting changes to [onChange], from any thread.
    func start(_ onChange: @escaping @Sendable (_ online: Bool) -> Void)
    func stop()
}

/// Never pauses delivery. For tests, and for containers built without one.
final class AlwaysOnlineNetworkMonitor: NetworkMonitor, @unchecked Sendable {
    var isOnline: Bool { true }
    func start(_ onChange: @escaping @Sendable (Bool) -> Void) {}
    func stop() {}
}

/// Follows the device's network through `NWPathMonitor`. Needs no permission.
/// Reports online until its first update, so a slow first report never holds
/// back delivery.
final class PathNetworkMonitor: NetworkMonitor, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "tech.digia.engage.network-monitor", qos: .utility)
    private let lock = NSLock()
    private var online = true
    private var started = false

    var isOnline: Bool { lock.withLock { online } }

    func start(_ onChange: @escaping @Sendable (Bool) -> Void) {
        let shouldStart = lock.withLock {
            defer { started = true }
            return !started
        }
        guard shouldStart else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let now = path.status == .satisfied
            let changed = self.lock.withLock {
                defer { self.online = now }
                return self.online != now
            }
            if changed { onChange(now) }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}
