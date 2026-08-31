import Foundation
import Testing
@testable import DigiaEngage

@MainActor
@Suite("DigiaDebugOverlayController")
struct DigiaDebugOverlayControllerTests {

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!
    }

    @Test("defaults to visible when no toggle was ever persisted")
    func defaultsToVisible() {
        let controller = DigiaDebugOverlayController(defaults: makeDefaults())
        #expect(controller.isVisible)
    }

    @Test("unset persisted toggle falls back to the config default")
    func configDefaultAppliesWhenUnset() {
        let controller = DigiaDebugOverlayController(defaults: makeDefaults())
        controller.applyConfigDefault(false)
        #expect(!controller.isVisible)
    }

    @Test("persisted false beats a config default of true")
    func persistedFalseBeatsConfigTrue() {
        let defaults = makeDefaults()
        DigiaDebugOverlayController(defaults: defaults).setVisible(false)

        let reconfigured = DigiaDebugOverlayController(defaults: defaults)
        reconfigured.applyConfigDefault(true)

        #expect(!reconfigured.isVisible)
    }

    @Test("setVisible persists across a fresh instance reading the same defaults")
    func persistsAcrossInstances() {
        let defaults = makeDefaults()
        DigiaDebugOverlayController(defaults: defaults).setVisible(true)

        let reconfigured = DigiaDebugOverlayController(defaults: defaults)

        #expect(reconfigured.isVisible)
    }
}
