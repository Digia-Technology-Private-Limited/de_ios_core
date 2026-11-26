import Foundation
import Testing

@testable import DigiaEngage

/// The host driver's delivery path. The routes-and-cap case now runs
/// cross-stack in `testkit/sdk-tests/tests/dmc/host_trigger_routes_and_respects_cap.yaml`;
/// only the pre-init drop stays (a pre-launch host trigger is not expressible
/// in shared YAML: the Android driver requires boot).
@MainActor
@Suite("DMC host trigger", .serialized)
struct DMCHostTriggerTests {
    // dmc-case: dmc.trigger.calls_before_init_dropped_not_held
    @Test("a host trigger before initialize drops at once, not silently")
    func dropsBeforeInitialize() {
        let sdk = { let instance = SDKInstance(
            defaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!,
            legacyDefaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!,
            makeNetworkClient: { _ in HeldBundleNetworkClient() }); instance.onHostMounted(SDKInstance.testHostId); return instance }()
        #expect(sdk.sdkState == .notInitialized)

        let presentation = sdk.triggerCampaign("home_banner", variables: nil)
        let recorder = PresentationRecorder(presentation)

        guard case .dropped(let reason, let detail) = recorder.outcome else {
            Issue.record("expected a drop, got \(String(describing: recorder.outcome))")
            return
        }
        #expect(reason == .notInitialized)
        #expect(detail == "Digia.initialize() has not been called")
    }
}
