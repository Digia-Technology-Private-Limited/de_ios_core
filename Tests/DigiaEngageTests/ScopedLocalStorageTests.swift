import Foundation
import Testing
@testable import DigiaEngage

@Suite("ScopedLocalStorage Tests")
struct ScopedLocalStorageTests {
    private func makeDefaults() -> UserDefaults {
        let name = "test.scoped.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("ScopedLocalStorage prepends domain to all keys")
    func basicScoping() {
        let defaults = makeDefaults()
        let root = UserDefaultsLocalStorage(defaults: defaults)
        let identity = root.scoped("identity")

        identity.set("user_123", forKey: "user_id")
        identity.set(true, forKey: "is_active")
        identity.set(42, forKey: "login_count")
        identity.set(3.14, forKey: "score")
        let testData = "data_val".data(using: .utf8)!
        identity.set(testData, forKey: "payload")

        // Read back through scoped instance
        #expect(identity.string(forKey: "user_id") == "user_123")
        #expect(identity.bool(forKey: "is_active") == true)
        #expect(identity.integer(forKey: "login_count") == 42)
        #expect(identity.double(forKey: "score") == 3.14)
        #expect(identity.data(forKey: "payload") == testData)

        // Verify physical keys in root storage & defaults
        #expect(root.string(forKey: "identity.user_id") == "user_123")
        #expect(defaults.string(forKey: "identity.user_id") == "user_123")
        #expect(defaults.bool(forKey: "identity.is_active") == true)
        #expect(defaults.integer(forKey: "identity.login_count") == 42)
        #expect(defaults.double(forKey: "identity.score") == 3.14)
        #expect(defaults.data(forKey: "identity.payload") == testData)

        // Remove through scoped
        identity.removeObject(forKey: "user_id")
        #expect(identity.string(forKey: "user_id") == nil)
        #expect(root.string(forKey: "identity.user_id") == nil)
        #expect(defaults.string(forKey: "identity.user_id") == nil)
    }

    @Test("Different domains remain isolated")
    func domainIsolation() {
        let defaults = makeDefaults()
        let root = UserDefaultsLocalStorage(defaults: defaults)
        let idStorage = root.scoped("identity")
        let analyticsStorage = root.scoped("analytics")

        idStorage.set("id_value", forKey: "key")
        analyticsStorage.set("analytics_value", forKey: "key")

        #expect(idStorage.string(forKey: "key") == "id_value")
        #expect(analyticsStorage.string(forKey: "key") == "analytics_value")
        #expect(root.string(forKey: "identity.key") == "id_value")
        #expect(root.string(forKey: "analytics.key") == "analytics_value")
    }

    @Test("Nested scoping chains domains")
    func nestedScoping() {
        let defaults = makeDefaults()
        let root = UserDefaultsLocalStorage(defaults: defaults)
        let level1 = root.scoped("level1")
        let level2 = level1.scoped("level2")

        level2.set("deep_value", forKey: "target")

        #expect(level2.string(forKey: "target") == "deep_value")
        #expect(level1.string(forKey: "level2.target") == "deep_value")
        #expect(root.string(forKey: "level1.level2.target") == "deep_value")
    }
}
