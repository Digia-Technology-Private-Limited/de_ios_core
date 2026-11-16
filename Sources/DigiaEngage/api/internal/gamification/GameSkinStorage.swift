import Foundation

/// Bridge v1 `storage`: string values namespaced by project + skin + user,
/// persisted in UserDefaults and cleared on SDK logout/reset.
///
/// The namespace is one UserDefaults key prefix, so every version of a skin
/// shares it and one user never sees another's values. Reads and writes never
/// throw: violations answer `invalid` (bad key) or `quota` (over budget).
final class GameSkinStorage: @unchecked Sendable {
    /// `^[A-Za-z0-9_.-]{1,64}$`.
    nonisolated static let keyMaxLength = 64
    /// One value may hold this many UTF-8 bytes.
    nonisolated static let valueMaxBytes = 16 * 1024
    /// One namespace may hold this many value bytes in total.
    nonisolated static let namespaceMaxBytes = 64 * 1024
    /// Every skin key starts with this; a user change clears the whole domain.
    nonisolated static let keyPrefix = "digia.game."

    private let defaults: UserDefaults
    private let namespace: String

    /// Builds the namespace: project + skin (all versions share it) + the
    /// current user identity.
    static func namespace(projectId: String, skinId: String, userId: String) -> String {
        "\(projectId).\(skinId).\(userId)"
    }

    /// Removes every skin namespace. Called on `setUserId`/`clearUserId`: the
    /// namespace carries the user, so a reset must not leave the old user's
    /// values behind for the next one to inherit.
    static func clearAll(defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// A key is valid when it is 1…64 ASCII letters, digits, `_`, `.` or `-`.
    /// Pure, so the bridge can reject bad keys before touching storage.
    static func isValidKey(_ key: String) -> Bool {
        guard (1...keyMaxLength).contains(key.utf8.count) else { return false }
        return key.unicodeScalars.allSatisfy { scalar in
            (scalar >= "A" && scalar <= "Z") || (scalar >= "a" && scalar <= "z")
                || (scalar >= "0" && scalar <= "9")
                || scalar == "_" || scalar == "." || scalar == "-"
        }
    }

    init(defaults: UserDefaults, namespace: String) {
        self.defaults = defaults
        self.namespace = namespace
    }

    func get(_ key: String) -> String? {
        defaults.string(forKey: storageKey(key))
    }

    /// Stores `value` under `key`. Returns nil on success, else the bridge
    /// error the caller answers with. Re-setting the same value is free: only
    /// the delta counts against the namespace budget.
    func set(_ key: String, value: String) -> GameBridgeErrorCode? {
        guard Self.isValidKey(key) else { return .invalid }
        let bytes = value.utf8.count
        guard bytes <= Self.valueMaxBytes else { return .quota }
        let delta = bytes - (defaults.string(forKey: storageKey(key))?.utf8.count ?? 0)
        guard storedBytes() + delta <= Self.namespaceMaxBytes else { return .quota }
        defaults.set(value, forKey: storageKey(key))
        return nil
    }

    func remove(_ key: String) {
        defaults.removeObject(forKey: storageKey(key))
    }

    /// Total value bytes in this namespace. Reads the live defaults each
    /// time, so values written by another process still count.
    func storedBytes() -> Int {
        let prefix = storageKey("")
        var total = 0
        for (key, value) in defaults.dictionaryRepresentation() {
            guard key.hasPrefix(prefix), let string = value as? String else { continue }
            total += string.utf8.count
        }
        return total
    }

    private func storageKey(_ key: String) -> String {
        "\(Self.keyPrefix)\(namespace).\(key)"
    }
}
