import Foundation
import Testing
@testable import DigiaEngage

@MainActor
@Suite("DigiaDebugOverlayController")
struct DigiaDebugOverlayControllerTests {

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!
    }

    @Test("defaults to hidden")
    func defaultsToHidden() {
        let controller = DigiaDebugOverlayController(defaults: makeDefaults())
        #expect(!controller.isVisible)
    }

    @Test("setVisible persists across a fresh instance reading the same defaults")
    func persistsAcrossInstances() {
        let defaults = makeDefaults()
        DigiaDebugOverlayController(defaults: defaults).setVisible(true)

        let reconfigured = DigiaDebugOverlayController(defaults: defaults)

        #expect(reconfigured.isVisible)
    }
}
