import Foundation

/// Which Digia host draws, when an app has more than one.
///
/// Every host (`DigiaHost`, and the `DigiaHostView` that `Digia.attach(to:)` adds) registers when it
/// appears and leaves when it disappears. While `attach` is in use, exactly one is **active**: the most
/// recently mounted one still on screen. Only it draws; every other host renders nothing and lets all
/// touches through, so a campaign is never drawn twice. When the active host goes, the one mounted
/// before it takes over.
///
/// Without `attach` (a SwiftUI app with `DigiaHost`, or React Native's own mount) every host stays
/// active, as before.
@MainActor
final class HostRegistry: ObservableObject {
    static let shared = HostRegistry()

    private let log = DigiaLogger()
    /// Mounted hosts, oldest first.
    private var mounted: [UUID] = []
    @Published private(set) var activeId: UUID?
    /// Set once `Digia.attach(to:)` is called.
    @Published private(set) var enforcing = false

    var isEmpty: Bool { mounted.isEmpty }

    func enforce() {
        guard !enforcing else { return }
        enforcing = true
        warnIfDuplicated()
    }

    func isActive(_ id: UUID) -> Bool {
        !enforcing || activeId == id
    }

    func mount(_ id: UUID) {
        mounted.removeAll { $0 == id }
        mounted.append(id)
        activeId = id
        warnIfDuplicated()
    }

    func unmount(_ id: UUID) {
        mounted.removeAll { $0 == id }
        activeId = mounted.last
    }

    func reset() {
        mounted = []
        activeId = nil
        enforcing = false
    }

    private func warnIfDuplicated() {
        #if DEBUG
        guard enforcing, mounted.count == 2 else { return }
        log.w("A Digia host was added more than once; only the latest one draws campaigns.")
        #endif
    }
}
