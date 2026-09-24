import Foundation
import Testing

@testable import DigiaEngage

@MainActor
@Suite("SDKServices unit tests", .serialized)
struct SDKServicesTests {

    private func makeServices() -> SDKServices {
        let storage = UserDefaultsLocalStorage(defaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!)
        return SDKServices(config: DigiaConfig(apiKey: "test_key"), storage: storage, networkClient: MockNetworkClient())
    }

    private func countRotations(_ services: SDKServices) -> () -> Int {
        var count = 0
        services.sessionManager.addRotationListener { count += 1 }
        return { count }
    }

    @Test("setting the same user ID twice rotates the session once")
    func sameUserIdRotatesOnce() {
        let services = makeServices()
        let rotations = countRotations(services)

        services.identityManager.setUserId("u1")
        services.identityManager.setUserId("u1")
        services.identityManager.setUserId("  u1 ")

        #expect(rotations() == 1)
    }

    @Test("clearing while anonymous does not rotate; clearing a user does")
    func clearRotatesOnlyFromAUser() {
        let services = makeServices()
        let rotations = countRotations(services)

        services.identityManager.clearUserId()
        #expect(rotations() == 0)

        services.identityManager.setUserId("u1")
        services.identityManager.clearUserId()
        #expect(rotations() == 2)
    }
}
