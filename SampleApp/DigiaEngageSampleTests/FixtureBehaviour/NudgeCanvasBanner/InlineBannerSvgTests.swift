import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// How an inline banner draws a vector picture: `inline_banner_svg/inline_banner_svg_with_placeholder`
/// points at the Test Kit's `testkit-badge.svg` (an indigo-to-cyan rounded square with a white
/// tick disc); `inline_banner_svg/inline_banner_svg_missing` points at an SVG that was never
/// uploaded. The fixture's `{{TESTKIT_ASSET_ORIGIN}}` resolves to the mock server's directory on
/// disk, so SDWebImage reads the file with no server.
///
/// What is on screen is read from the window's pixels: the SwiftUI image has no accessibility
/// node, and a decoded badge is the only thing in the app that paints its indigo.
///
/// Not ported from Flutter: holding the download to look at the blur placeholder mid-load (a file
/// URL cannot be held), and the `DigiaNetworkImage` empty-URL cases (no such widget on iOS; the
/// banner parser drops an empty URL, which `inline_banner_empty_url_*` goldens cover).
///
/// Port of `flutter/core/test/fixture_behaviour/ui_banner_svg_test.dart`.
@Suite("Inline banner: vector picture", .serialized,
       .tags(.integration, .behaviour, .inline, .media),
       .enabled(if: testkitAvailable, testkitSkipReason))
@MainActor
struct InlineBannerSvgTests {

    private static func isBadgeIndigo(_ c: (r: Int, g: Int, b: Int)) -> Bool {
        c.b > 180 && c.r < 140 && c.g < 140
    }

    private static func isFallbackBox(_ c: (r: Int, g: Int, b: Int)) -> Bool {
        abs(c.r - 241) <= 2 && abs(c.g - 241) <= 2 && abs(c.b - 245) <= 2
    }

    private func show(_ path: String) async throws -> (SdkHarness, NudgeCanvasFrameProbe) {
        let campaign = try fixture(path)
        let sdk = try await SdkHarness.start(campaign)
        let probe = NudgeCanvasFrameProbe()
        try sdk.mount {
            VStack(spacing: 0) {
                DigiaSlot("home_banner") { EmptyView() }.nudgeCanvasFrame(probe)
                Spacer()
            }
            .background(Color.white)
        }
        try sdk.deliver(keyOf(campaign))
        try await sdk.waitUntilSteady("the banner laid out") { probe.frame.height > 20 ? probe.frame : nil }
        return (sdk, probe)
    }

    // Fails if: digia_cached_image.swift `DigiaImagePipeline` stops registering
    // `SDImageSVGCoder.shared` (the SVG never decodes and the banner keeps its empty box).
    @Test("draws the vector once it has loaded")
    func drawsTheVector() async throws {
        let (sdk, probe) = try await show("inline_banner_svg/inline_banner_svg_with_placeholder")
        defer { sdk.tearDown() }

        try await sdk.waitUntil("the badge is drawn", timeout: 5) {
            ((try? sdk.renderedPixels())?.count(in: probe.frame, where: Self.isBadgeIndigo) ?? 0) > 100
        }
    }

    // Fails if: DigiaInlineBannerView.swift drops the `Color(red: 241 / 255, green: 241 / 255,
    // blue: 245 / 255)` under the image (a missing picture would leave a hole, not the box), or
    // stops holding the authored aspect ratio while the picture is absent.
    @Test("a vector that was never uploaded leaves the banner its own empty box, not a broken picture")
    func missingVectorLeavesTheBox() async throws {
        let (sdk, probe) = try await show("inline_banner_svg/inline_banner_svg_missing")
        defer { sdk.tearDown() }
        // The load fails on a missing file at once; give it ample time to have done so.
        try await sdk.settle(1)

        let frame = probe.frame
        // The slot holds the banner inside its authored margins (16 a side, 8 above and below).
        #expect(abs((frame.height - 16) - (frame.width - 32) / 2) < 1,
                "the banner keeps its authored 2:1 box")
        let pixels = try sdk.renderedPixels()
        #expect(pixels.count(in: frame, where: Self.isBadgeIndigo) == 0)
        #expect(Self.isFallbackBox(pixels.color(at: CGPoint(x: frame.midX, y: frame.midY))),
                "the banner's own empty box, \(pixels.color(at: CGPoint(x: frame.midX, y: frame.midY)))")
    }
}
}
