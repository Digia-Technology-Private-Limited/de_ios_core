import Foundation
import SnapshotTesting
import Testing
import UIKit
@testable import DigiaEngage

extension HostedUITests {
/// Pixel goldens for what an anchorless guide draws inside its cutout: each crop format, the pill
/// highlight and a second step.
///
/// `AnchorlessFixtureGoldenTests` draws the Test Kit's fixtures, whose crops are all one stand-in
/// photo. These goldens use one picture the test controls (`Support/CropAssets/crop_stripes.*`: four
/// stripes and a dark square at its centre) as a PNG, a lossless WebP and an SVG, so a crop that is
/// scaled, clipped or placed wrongly shows as a different picture. The three formats should look
/// alike; they differ only by anti-aliased edge pixels.
///
/// A 300x100 target is wider than the square picture, so `scaledToFill` scales it up and shows only
/// its middle band: stripes with the dark square centred.
@Suite("Anchorless crop format goldens", .serialized, .tags(.guide, .golden))
struct AnchorlessFormatsGoldenTests {

    private struct Step {
        var url: String
        var width = 300.0
        var top = 150.0
        var height = 100.0
        var shape = "rect"
    }

    @Test("matches the crop golden", arguments: ["png", "webp", "svg"])
    @MainActor
    func testCropFormatGolden(format: String) async throws {
        try await assertFirstStep([Step(url: "https://crops.test/crop.\(format)")], named: "crop-\(format)")
    }

    @Test("matches the pill highlight golden")
    @MainActor
    func testHighlightPillGolden() async throws {
        try await assertFirstStep(
            [Step(url: "https://crops.test/crop.png", height: 60, shape: "pill")],
            named: "highlight-pill")
    }

    @Test("matches the golden of each step of a two-step guide")
    @MainActor
    func testTwoStepGolden() async throws {
        let showing = try show([
            Step(url: "https://crops.test/crop.png"),
            Step(url: "https://crops.test/crop.webp", width: 200, top: 400, height: 60),
        ])
        defer { showing.end() }

        try #require(
            try await AnchorlessGuideHost.waitUntilDrawn(showing.window, differingFrom: showing.hostOnly),
            "The guide drew nothing"
        )
        let first = ComponentTestHost.settledImage(of: showing.window)
        assertGolden(first, named: "two-step-1")

        SDKInstance.shared.advanceGuide()
        try #require(
            try await AnchorlessGuideHost.waitUntilDrawn(showing.window, differingFrom: first),
            "The second step drew nothing"
        )
        assertGolden(ComponentTestHost.settledImage(of: showing.window), named: "two-step-2")
    }

    @MainActor
    private func assertFirstStep(_ steps: [Step], named name: String) async throws {
        let showing = try show(steps)
        defer { showing.end() }

        try #require(
            try await AnchorlessGuideHost.waitUntilDrawn(showing.window, differingFrom: showing.hostOnly),
            "The guide drew nothing"
        )
        assertGolden(ComponentTestHost.settledImage(of: showing.window), named: name)
    }

    /// Exact within the perceptual tolerance, as the other fixture goldens. Snapshot file:
    /// `de_workspace/goldens/ios/AnchorlessFormatsGoldenTests/testCropGolden.<name>.png`.
    @MainActor
    private func assertGolden(_ image: UIImage, named name: String) {
        assertVisualGolden(
            matching: image,
            precision: 1.0,
            perceptualPrecision: 0.98,
            named: name,
            function: "testCropGolden"
        )
    }

    @MainActor
    private func show(_ steps: [Step]) throws -> AnchorlessGuideHost.Showing {
        let campaign = try #require(
            try CampaignModel.fromJson(Self.campaign(steps), devicePlatform: "ios"),
            "The guide must decode"
        )
        let assets = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Support/CropAssets")
        return try AnchorlessGuideHost.show(campaign, anchors: false) { url in
            // The crop picture in the format the URL's extension names.
            try? Data(contentsOf: assets.appendingPathComponent("crop_stripes.\(url.pathExtension)"))
        }
    }

    private static func campaign(_ steps: [Step]) -> [String: Any] {
        [
            "id": "id-anchorless-golden",
            "campaignKey": "anchorless_golden",
            "campaignType": "guide",
            "status": "active",
            "templateConfig": [
                "templateType": "spotlight",
                "designWidth": 360,
                "steps": steps.enumerated().map { index, step -> [String: Any] in
                    [
                        "id": "step_\(index)",
                        "stepId": "step_\(index)",
                        "sequenceOrder": index,
                        "layoutMode": "canvas",
                        "highlightShape": step.shape,
                        "target": [
                            "type": "anchorless",
                            "version": 1,
                            "pageKey": "home",
                            "imageUrl": step.url,
                            "horizontal": [
                                "frame": "window",
                                "rule": ["kind": "centered", "width": step.width],
                            ],
                            "vertical": [
                                "frame": "appContent",
                                "rule": ["kind": "topFixed", "topOffset": step.top, "height": step.height],
                            ],
                        ],
                        "canvas": [
                            "version": 2,
                            "canvasWidth": 280,
                            "canvasHeight": 90,
                            "children": [Any](),
                        ],
                    ]
                },
                "variables": [Any](),
            ],
        ]
    }
}
}
