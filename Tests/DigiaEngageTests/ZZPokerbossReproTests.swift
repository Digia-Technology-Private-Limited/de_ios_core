// TEMPORARY — PokerBoss tg_suppport_popup repro. Do not commit.
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

@MainActor
struct ZZPokerbossReproTests {
    private func templateConfig(showClose: Bool, nullPlacement: Bool = false, omitPlacement: Bool = false, oldInside: Bool = false) -> [String: Any] {
        let placement: Any = nullPlacement ? NSNull() : [
            "x": 0.9222222222222223, "y": 0.02097902097902098,
            "width": 0.06111111111111111, "height": 0.038461538461538464,
        ]
        var close: [String: Any] = [
            "backgroundColor": ["value": "#E6ECE3"],
            "iconColor": ["value": "#283F37"],
            "iconSize": 12,
        ]
        if !omitPlacement { close["placement"] = oldInside ? ["mode": "inside", "horizontal": "right", "vertical": "top", "offsetX": 12, "offsetY": 12] as [String: Any] : placement }
        return [
            "templateType": "nudge",
            "layoutMode": "canvas",
            "container": [
                "displayType": "dialog",
                "backgroundColor": ["value": "#FEFDFB"],
                "barrierColor": ["value": "#FF000000"],
                "cornerRadius": 16,
                "padding": 0,
                "backdropDismissible": true,
                "showCloseButton": showClose,
                "closeButton": close,
                "itemAlign": "center", "itemArrange": "center",
                "showHandle": true, "draggable": true,
                "widthPct": 100, "minHorizontalMargin": 24,
                "useSafeArea": false, "bottomSafeAreaMode": "insetContent",
            ] as [String: Any],
            "designWidth": 360,
            "canvas": [
                "version": 2, "canvasWidth": 360, "canvasHeight": 572,
                "background": ["type": "color", "color": ["value": "#3B4CCA"]],
                "children": [[
                    "kind": "tapRegion", "id": "tap_mvmaxo4kn1lhg",
                    "rect": ["x": 0, "y": 0.015061782667336699, "width": 1, "height": 0.9849382173326634],
                    "onClick": ["steps": [["type": "Action.dismissDialog"]], "inkWell": true],
                    "isPrimary": true,
                ] as [String: Any]],
            ] as [String: Any],
            "variables": [],
        ]
    }

    private func render(_ name: String, showClose: Bool, nullPlacement: Bool = false, omitPlacement: Bool = false, oldInside: Bool = false) throws {
        let name = ProcessInfo.processInfo.environment["PB_TAG"].map { "\(name)_\($0)" } ?? name
        let config = try #require(try NudgeConfig.fromJson(templateConfig(showClose: showClose, nullPlacement: nullPlacement, omitPlacement: omitPlacement, oldInside: oldInside)))
        let presentation = DigiaNudgePresentation(
            config: config,
            payload: CEPTriggerPayload(cepCampaignId: "tg", campaignKey: "tg_suppport_popup", cepMetadata: [:]),
            variables: nil)
        let size = CGSize(width: 393, height: 852)
        let root = ZStack {
            Color(white: 0.12)
            Text("HOST APP SCREEN").foregroundStyle(.gray)
            NudgeDialogContainer(presentation: presentation, viewportSize: size, safeAreaInsets: .zero)
        }
        .frame(width: size.width, height: size.height)
        .ignoresSafeArea()

        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        for _ in 0..<5 {
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            host.view.layer.render(in: UIGraphicsGetCurrentContext()!)
        }
        let dir = URL(fileURLWithPath: "/tmp/pokerboss")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try image.pngData()!.write(to: dir.appendingPathComponent("\(name).png"))
    }

    @Test func oldInside() throws { try render("oldinside", showClose: true, oldInside: true) }
    @Test func asIs() throws { try render("asis", showClose: true) }
    @Test func noCloseWorkaround() throws { try render("no_close", showClose: false) }
    @Test func legacyNoPlacementKey() throws { try render("legacy_no_placement", showClose: true, omitPlacement: true) }
    @Test func nullPlacement() throws { try render("null_placement", showClose: true, nullPlacement: true) }
}
