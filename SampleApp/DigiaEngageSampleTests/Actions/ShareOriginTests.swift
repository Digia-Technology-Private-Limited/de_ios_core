import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension HostedUITests {
/// Where the share sheet is anchored. On iPad (regular width) `UIActivityViewController` is a
/// popover, and presenting one with no source view crashes the host app. The share action hands the
/// sheet to `ViewControllerUtil.present`, which must give UIKit an anchor: the top-most
/// controller's view, pointing at its centre with no arrow. Port of
/// `flutter/core/test/actions/share_origin_test.dart`, which pins the same anchor for Flutter's
/// share plugin.
///
/// Read synchronously, before the run loop turns: on an iPhone UIKit then adapts the popover into a
/// sheet and rewrites `sourceRect`, so what the SDK set is only observable at presentation time.
@Suite("Share origin", .serialized, .tags(.actions, .integration))
@MainActor
struct ShareOriginTests {

    // Fails if: `ViewControllerUtil.present` (api/internal/utils/view_controller_util.swift) stops
    // setting `popover.sourceView` / `sourceRect` / `permittedArrowDirections`, or anchors on a
    // controller other than the top-most one.
    @Test("the share sheet is anchored at the centre of the top-most controller's view")
    func shareSheetIsAnchoredOnTheTopView() async throws {
        let sdk = try await SdkHarness.start(loadCampaign("actions/action_share.json"))
        defer {
            sdk.presentedViewer?.dismiss(animated: false)
            sdk.tearDown()
        }
        try sdk.mount { Text("App home") }
        let top = try #require(ViewControllerUtil.topViewController(), "No top-most controller")

        let sheet = UIActivityViewController(activityItems: ["Get 20% off"], applicationActivities: nil)
        ViewControllerUtil.present(sheet, animated: false)

        let popover = try #require(sheet.popoverPresentationController, "No popover controller to anchor")
        #expect(popover.sourceView === top.view)
        #expect(popover.sourceRect == CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0))
        #expect(popover.permittedArrowDirections == [])
    }
}
}
