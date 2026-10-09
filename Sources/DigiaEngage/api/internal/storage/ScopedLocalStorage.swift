import Foundation

final class ScopedLocalStorage: LocalStorage, @unchecked Sendable {
    private let parent: LocalStorage
    let domain: String

    init(parent: LocalStorage, domain: String) {
        self.parent = parent
        self.domain = domain
    }

    private func prefixedKey(_ key: String) -> String {
        "\(domain).\(key)"
    }

    func string(forKey key: String) -> String? {
        parent.string(forKey: prefixedKey(key))
    }

    func set(_ value: String?, forKey key: String) {
        parent.set(value, forKey: prefixedKey(key))
    }

    func bool(forKey key: String) -> Bool {
        parent.bool(forKey: prefixedKey(key))
    }

    func set(_ value: Bool, forKey key: String) {
        parent.set(value, forKey: prefixedKey(key))
    }

    func integer(forKey key: String) -> Int {
        parent.integer(forKey: prefixedKey(key))
    }

    func set(_ value: Int, forKey key: String) {
        parent.set(value, forKey: prefixedKey(key))
    }

    func double(forKey key: String) -> Double {
        parent.double(forKey: prefixedKey(key))
    }

    func set(_ value: Double, forKey key: String) {
        parent.set(value, forKey: prefixedKey(key))
    }

    func data(forKey key: String) -> Data? {
        parent.data(forKey: prefixedKey(key))
    }

    func set(_ value: Data?, forKey key: String) {
        parent.set(value, forKey: prefixedKey(key))
    }

    func removeObject(forKey key: String) {
        parent.removeObject(forKey: prefixedKey(key))
    }

    func scoped(_ domain: String) -> LocalStorage {
        ScopedLocalStorage(parent: self, domain: domain)
    }
}
