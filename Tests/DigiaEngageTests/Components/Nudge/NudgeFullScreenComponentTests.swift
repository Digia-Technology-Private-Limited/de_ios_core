import Foundation
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

@Suite("Full screen", .serialized, .tags(.nudge))
struct NudgeFullScreenComponentTests {

    private func makeFullScreenConfig(
        safeAreaMode: BottomSafeAreaMode = .none,
        showCloseButton: Bool = false,
        placement: [String: Any]? = nil
    ) -> NudgeConfig {
        guard let fixture = FixtureLoader.loadFixture(campaignType: "nudge_dialog", fileName: "nudge-dialog"),
              var templateConfig = fixture["templateConfig"] as? [String: Any] else {
            fatalError("Failed to load nudge-dialog fixture")
        }
        var container = templateConfig["container"] as? [String: Any] ?? [:]
        container["displayType"] = "full_screen"
        container["safeAreaMode"] = safeAreaMode.rawValue
        container["showCloseButton"] = showCloseButton
        if let placement {
            container["closeButton"] = [
                "placement": NSNull(),
                "outsidePlacement": placement
            ]
        } else if !showCloseButton {
            container.removeValue(forKey: "closeButton")
        }
        templateConfig["container"] = container
        guard let config = NudgeConfig.fromJson(templateConfig) else {
            fatalError("Failed to parse full screen config")
        }
        return config
    }

    @Test("renders full-screen nudge with edge-to-edge safe area mode", .tags(.unit, .smoke)) @MainActor
    func testFullScreenEdgeToEdgeRendering() {
        let config = makeFullScreenConfig(safeAreaMode: .none, showCloseButton: false)
        let presentation = DigiaNudgePresentation(
            config: config,
            payload: CEPTriggerPayload(cepCampaignId: "fs_none", campaignKey: "campaign_1", cepMetadata: [:]),
            variables: nil
        )
        let view = NudgeFullScreenView(presentation: presentation)
        let hosting = UIHostingController(rootView: AnyView(view))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        ComponentTestHost.drainRunLoop(for: 0.1)
        _ = ComponentTestHost.renderImage(of: hosting.view)
        window.rootViewController = nil
        window.isHidden = true
        #expect(hosting.view != nil)
    }

    @Test("renders full-screen nudge with inset-surface safe area mode and close button", .tags(.unit)) @MainActor
    func testFullScreenInsetSurfaceWithCloseButton() {
        let config = makeFullScreenConfig(safeAreaMode: .insetSurface, showCloseButton: true)
        let presentation = DigiaNudgePresentation(
            config: config,
            payload: CEPTriggerPayload(cepCampaignId: "fs_inset_surface", campaignKey: "campaign_1", cepMetadata: [:]),
            variables: nil
        )
        let view = NudgeFullScreenView(presentation: presentation)
        let hosting = UIHostingController(rootView: AnyView(view))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        ComponentTestHost.drainRunLoop(for: 0.1)
        _ = ComponentTestHost.renderImage(of: hosting.view)
        window.rootViewController = nil
        window.isHidden = true
        #expect(hosting.view != nil)

        // Also verify safeCloseButton bounds calculation
        let safeClose = view.safeCloseButton(bounds: CGSize(width: 375, height: 812))
        #expect(safeClose.marginTop >= 0)
        #expect(safeClose.marginRight >= 0)
    }

    @Test("renders full-screen nudge with placed close button overlay", .tags(.unit)) @MainActor
    func testFullScreenPlacedCloseButton() {
        let config = makeFullScreenConfig(
            safeAreaMode: .none,
            showCloseButton: true,
            placement: ["horizontal": "right", "vertical": "top"]
        )
        let presentation = DigiaNudgePresentation(
            config: config,
            payload: CEPTriggerPayload(cepCampaignId: "fs_placed_close", campaignKey: "campaign_1", cepMetadata: [:]),
            variables: nil
        )
        let view = NudgeFullScreenView(presentation: presentation)
        let hosting = UIHostingController(rootView: AnyView(view))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        ComponentTestHost.drainRunLoop(for: 0.1)
        _ = ComponentTestHost.renderImage(of: hosting.view)
        window.rootViewController = nil
        window.isHidden = true
        #expect(hosting.view != nil)
    }
}
