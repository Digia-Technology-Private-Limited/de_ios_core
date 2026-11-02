import Foundation
import Testing
@testable import DigiaEngage

/// Port of Flutter `test/dmc_app_opens_counter_test.dart`.
///
/// `device.app_opens` (dmc-mvp-spec §3.7, §3.15): one count per phone, read as
/// a rule fact. `app_opened` fires before storage loads, so the counter is
/// attached afterwards — and it must never restart from 0, which would show a
/// first-open campaign again.
@Suite("DMC app opens counter")
struct DMCAppOpensCounterTests {
    private let store = InMemoryLocalStorage()

    private var saved: Int? {
        store.backing[AppOpensCounter.storageKey] as? Int
    }

    @Test("an open counted before storage loads is added to the stored count")
    func countedBeforeStorageLoads() {
        store.set(4, forKey: AppOpensCounter.storageKey)
        let counter = AppOpensCounter()
        // `initialize` counts the cold start before the first storage read.
        counter.countOpen()
        counter.attach(store)

        #expect(counter.value == 5)
        #expect(saved == 5)
    }

    @Test("an open counted after storage loaded is stored too")
    func countedAfterStorageLoaded() {
        store.set(4, forKey: AppOpensCounter.storageKey)
        let counter = AppOpensCounter()
        counter.attach(store)
        #expect(counter.value == 4, "the stored count is the fact")

        counter.countOpen()

        #expect(counter.value == 5)
        #expect(saved == 5)
    }

    @Test("the first attach and the first open are the only ones that count")
    func onlyFirstAttachAndOpenCount() {
        let counting = CountingStorage()
        let counter = AppOpensCounter()
        counter.attach(counting)
        // A second initialize on the same process is a retry, not an open.
        counter.attach(counting)
        counter.countOpen()
        counter.countOpen()

        #expect(counter.value == 1)
        #expect(counting.inner.backing[AppOpensCounter.storageKey] as? Int == 1)
        #expect(counting.writes == 1)
    }

    @Test("a count stored as another type stays unknown instead of restarting")
    func otherTypeStaysUnknown() {
        // 0 would make every campaign on "app opens = 1" match again.
        store.set("not-a-number", forKey: AppOpensCounter.storageKey)
        let counter = AppOpensCounter()
        counter.countOpen()
        counter.attach(store)

        #expect(counter.value == nil)
        #expect(store.string(forKey: AppOpensCounter.storageKey) == "not-a-number")
    }

    // Flutter's remaining three cases (a storage that throws on read, a write
    // that throws on the call, a write that fails later) have no Swift
    // equivalent: `LocalStorage` reads and writes cannot throw. The nearest
    // failure a Swift storage has is a write that is silently dropped (full
    // disk), which must leave the in-memory fact correct.
    @Test("a write that is dropped leaves the in-memory fact correct")
    func droppedWriteKeepsFact() {
        store.dropWrites = true
        let counter = AppOpensCounter()
        counter.attach(store)

        counter.countOpen()

        #expect(counter.value == 1, "the in-memory fact is still correct")
        #expect(saved == nil)
    }
}

/// Counts writes, so a repeated attach or open is seen not to store twice.
private final class CountingStorage: LocalStorage, @unchecked Sendable {
    let inner = InMemoryLocalStorage()
    private(set) var writes = 0

    func string(forKey key: String) -> String? { inner.string(forKey: key) }
    func set(_ value: String?, forKey key: String) { inner.set(value, forKey: key) }
    func bool(forKey key: String) -> Bool { inner.bool(forKey: key) }
    func set(_ value: Bool, forKey key: String) { inner.set(value, forKey: key) }
    func integer(forKey key: String) -> Int { inner.integer(forKey: key) }
    func set(_ value: Int, forKey key: String) {
        writes += 1
        inner.set(value, forKey: key)
    }
    func double(forKey key: String) -> Double { inner.double(forKey: key) }
    func set(_ value: Double, forKey key: String) { inner.set(value, forKey: key) }
    func data(forKey key: String) -> Data? { inner.data(forKey: key) }
    func set(_ value: Data?, forKey key: String) { inner.set(value, forKey: key) }
    func removeObject(forKey key: String) { inner.removeObject(forKey: key) }
}
