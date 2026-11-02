import Foundation

private let log = DigiaLogger()

/// The phone's cold starts, read by rules as the `device.app_opens` fact
/// (DMC spec §3.7). Kept per phone: not the session count, and not cleared on
/// `setUserId` or `clearUserId`.
///
/// One instance per process. `app_opened` fires before storage loads (R58),
/// so ``countOpen()`` can run first; ``attach(_:)`` then adds it to the stored
/// count. Both happen before a held `app_opened` is replayed, so it sees its
/// own open.
final class AppOpensCounter {
    static let storageKey = "device.app_opens"

    private var storage: LocalStorage?
    private var opened = false
    private(set) var value: Int?

    /// Counts this process's open. A second call (an init retry) is ignored.
    func countOpen() {
        guard !opened else { return }
        opened = true
        if let value { save(value + 1) }
    }

    /// Loads the stored count once, adding an open counted before it loaded.
    func attach(_ storage: LocalStorage) {
        guard self.storage == nil else { return }
        self.storage = storage
        // A stored value of another type is left alone: restarting from 0
        // would show a first-open campaign again. `integer(forKey:)` reads
        // text that is not a number as 0, so the text form is checked first.
        if let text = storage.string(forKey: Self.storageKey), Int(text) == nil {
            log.e("App opens count unreadable — app_opens conditions will fail")
            return
        }
        let stored = storage.integer(forKey: Self.storageKey)
        value = stored
        if opened { save(stored + 1) }
    }

    private func save(_ count: Int) {
        value = count
        storage?.set(count, forKey: Self.storageKey)
    }
}
