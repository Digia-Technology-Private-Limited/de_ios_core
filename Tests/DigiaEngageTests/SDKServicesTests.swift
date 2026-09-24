import Foundation
import Testing

@testable import DigiaEngage

@MainActor
@Suite("SDKServices unit tests", .serialized)
struct SDKServicesTests {

    @Test("storage operations read, write, and remove values")
    func storageOperations() {
        let storage = UserDefaultsLocalStorage(defaults: UserDefaults(suiteName: "test_storage_\(UUID().uuidString)")!)

        #expect(storage.string(forKey: "key_str") == nil)
        storage.set("hello", forKey: "key_str")
        #expect(storage.string(forKey: "key_str") == "hello")

        storage.set(true, forKey: "key_bool")
        #expect(storage.bool(forKey: "key_bool") == true)

        storage.set(42, forKey: "key_int")
        #expect(storage.integer(forKey: "key_int") == 42)

        storage.set(3.14, forKey: "key_double")
        #expect(storage.double(forKey: "key_double") == 3.14)

        let data = "data_val".data(using: .utf8)
        storage.set(data, forKey: "key_data")
        #expect(storage.data(forKey: "key_data") == data)

        storage.removeObject(forKey: "key_str")
        #expect(storage.string(forKey: "key_str") == nil)

        storage.remove(forKey: "key_bool")
        #expect(storage.bool(forKey: "key_bool") == false)
    }
}
