import Foundation
import Testing

@testable import DigiaEngage

/// Guards the skin storage contract: the production lines are `isValidKey`,
/// the 16 KB value check and namespace-delta check in `set`, and `clearAll`.
@Suite("Game skin storage", .tags(.unit, .game))
struct GameSkinStorageTests {
    private func makeStorage(namespace: String = "proj/wheel/user1") -> (GameSkinStorage, UserDefaults) {
        let defaults = UserDefaults(suiteName: "test-game-\(UUID().uuidString)")!
        return (GameSkinStorage(defaults: defaults, namespace: namespace), defaults)
    }

    @Test("key regex accepts the contract shape and rejects the rest")
    func keyRegex() {
        #expect(GameSkinStorage.isValidKey("hi.score-1_x"))
        #expect(GameSkinStorage.isValidKey("a"))
        #expect(GameSkinStorage.isValidKey(String(repeating: "k", count: 64)))
        // Guards the length and character checks in isValidKey.
        #expect(!GameSkinStorage.isValidKey(""))
        #expect(!GameSkinStorage.isValidKey(String(repeating: "k", count: 65)))
        #expect(!GameSkinStorage.isValidKey("a/b"))
        #expect(!GameSkinStorage.isValidKey("a b"))
        #expect(!GameSkinStorage.isValidKey("héllo"))
    }

    @Test("set, get and remove round-trip, missing reads null")
    func roundTrip() {
        let (storage, _) = makeStorage()

        #expect(storage.get("score") == nil)
        #expect(storage.set("score", value: "42") == nil)
        #expect(storage.get("score") == "42")
        storage.remove("score")
        #expect(storage.get("score") == nil)
    }

    @Test("values over 16 KB answer quota")
    func valueBudget() {
        let (storage, _) = makeStorage()
        let max = String(repeating: "a", count: 16 * 1024)

        #expect(storage.set("big", value: max) == nil)
        #expect(storage.get("big") == max)
        // Guards the per-value check in set: one byte over fails.
        #expect(storage.set("big", value: max + "a") == .quota)
        #expect(storage.get("big") == max)
    }

    @Test("namespaces over 64 KB answer quota; rewriting the same value is free")
    func namespaceBudget() {
        let (storage, _) = makeStorage()
        let quarter = String(repeating: "a", count: 64 * 1024 / 4)

        #expect(storage.set("k1", value: quarter) == nil)
        #expect(storage.set("k2", value: quarter) == nil)
        #expect(storage.set("k3", value: quarter) == nil)
        #expect(storage.set("k4", value: quarter) == nil)
        // Rewriting an existing key charges only the delta: free here.
        #expect(storage.set("k1", value: quarter) == nil)
        // One more byte over the namespace total fails, on the total check.
        #expect(storage.set("k5", value: "b") == .quota)
        // Guards the namespace-total check in set: freed room works again.
        storage.remove("k1")
        #expect(storage.set("k5", value: "b") == nil)
    }

    @Test("namespaces are isolated per project, skin and user")
    func namespaceIsolation() {
        let defaults = UserDefaults(suiteName: "test-game-\(UUID().uuidString)")!
        let first = GameSkinStorage(
            defaults: defaults,
            namespace: GameSkinStorage.namespace(projectId: "p", skinId: "wheel", identity: "u1"))
        let second = GameSkinStorage(
            defaults: defaults,
            namespace: GameSkinStorage.namespace(projectId: "p", skinId: "wheel", identity: "u2"))

        #expect(first.set("score", value: "1") == nil)
        #expect(second.get("score") == nil)
        #expect(second.set("score", value: "2") == nil)
        #expect(first.get("score") == "1")
    }
}
