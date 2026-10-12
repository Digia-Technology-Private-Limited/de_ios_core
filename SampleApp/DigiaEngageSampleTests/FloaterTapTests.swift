import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension HostedUITests {
/// Real taps on the floater surfaces: a synthesized touch through `UIApplication.sendEvent`, hit
/// tested and recognized by UIKit, so the production tap handlers (and their click analytics) run.
/// This needs the sample app as the test host; the SwiftPM test bundle has no `UIApplication`, so
/// UIKit never turns a touch into a gesture there.
@Suite("Floater taps", .serialized, .tags(.floater, .pip, .component))
@MainActor
struct FloaterTapTests {

    @Test("the test host has an application and a window scene")
    func hostAppHasApplicationAndScene() {
        let app = (UIApplication.self as AnyObject).perform(NSSelectorFromString("sharedApplication"))?
            .takeUnretainedValue()
        #expect(app != nil, "No UIApplication")
        #expect(!UIApplication.shared.connectedScenes.isEmpty, "No window scene")
    }

    @Test("a tap on a collapsed PiP expands it")
    func tapOnCollapsedPipExpandsIt() async throws {
        let (orchestrator, window) = try await startPip("pip-media-image")
        defer { tearDown(window) }
        #expect(orchestrator.surface == .collapsed)

        try FloaterTap.tapWindow(in: window)

        #expect(orchestrator.surface == .expanded, "A tap on the collapsed PiP did not expand it")
    }

    /// Control: a tap that misses the PiP must not expand it, or the test above proves nothing.
    @Test("a tap outside a PiP leaves it collapsed")
    func tapOutsidePipDoesNotExpandIt() async throws {
        let (orchestrator, window) = try await startPip("pip-media-image")
        defer { tearDown(window) }
        let rect = try FloaterTap.windowRect(in: window)
        let miss = CGPoint(x: 40, y: rect.minY > 300 ? 200 : 700)
        #expect(!rect.contains(miss))

        try? TouchSynthesizer.tap(at: miss, in: window)

        #expect(orchestrator.surface == .collapsed, "A tap outside the PiP expanded it")
    }

    @Test("a tap on a story floater opens its story")
    func tapOnStoryFloaterOpensStory() async throws {
        let json = try #require(FixtureLoader.loadFixture(campaignType: "floater", fileName: "floater-story-window"))
        let campaign = try #require(CampaignModel.fromJson(json))
        let orchestrator = SDKInstance.shared.floaterStoryOrchestrator!
        try #require(orchestrator.start(campaign, payload: payload(campaign), screenName: nil),
                     "\(orchestrator.lastStartFailureReason ?? "start refused")")
        let window = mount(FloaterStoryOverlayView())
        defer { tearDown(window) }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(!orchestrator.storyOpen)

        try FloaterTap.tapWindow(in: window)

        #expect(orchestrator.storyOpen, "A tap on the floater window did not open its story")
    }

    // MARK: - Helpers

    private func startPip(_ name: String) async throws -> (FloaterOrchestrator, UIWindow) {
        let json = try #require(FixtureLoader.loadFixture(campaignType: "pip", fileName: name))
        let campaign = try #require(CampaignModel.fromJson(json))
        let orchestrator = SDKInstance.shared.floaterOrchestrator!
        try #require(orchestrator.start(campaign, payload: payload(campaign), screenName: nil),
                     "\(orchestrator.lastStartFailureReason ?? "start refused")")
        for _ in 0..<250 where orchestrator.awaitingMedia {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try #require(!orchestrator.awaitingMedia, "PiP media never became ready")
        let window = mount(FloaterOverlayView())
        try await Task.sleep(nanoseconds: 1_000_000_000)
        return (orchestrator, window)
    }

    private func mount<Content: View>(_ overlay: Content) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        let root = UIViewController()
        root.view.backgroundColor = .systemTeal
        let host = UIHostingController(rootView: overlay)
        host.view.frame = window.bounds
        host.view.backgroundColor = .clear
        root.addChild(host)
        root.view.addSubview(host.view)
        host.didMove(toParent: root)
        window.rootViewController = root
        window.makeKeyAndVisible()
        return window
    }

    private func tearDown(_ window: UIWindow) {
        SDKInstance.shared.floaterOrchestrator.dismiss(.hostTeardown)
        SDKInstance.shared.floaterStoryOrchestrator.dismiss(.hostTeardown)
        ComponentTestHost.cleanupOverlayWindow(window)
    }

    private func payload(_ campaign: CampaignModel) -> CEPTriggerPayload {
        CEPTriggerPayload(cepCampaignId: "tap_check", campaignKey: campaign.campaignKey, cepMetadata: [:])
    }
}
}
