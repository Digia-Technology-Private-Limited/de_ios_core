import AVFoundation
import Foundation
import Lottie
import SDWebImage
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension RenderedUITests {
/// Pixel goldens for every Test Kit inline Canvas fixture.
///
/// The arguments are read from `sdk_testing_fixtures/campaigns/canvas/` and
/// `sdk_testing_fixtures/campaigns/inline_canvas/`, so a fixture added to the Test Kit is covered with
/// no code change (record it with `./run-tests.sh canvas record`). Each fixture is decoded by
/// `CampaignModel.fromJson` and drawn by `DigiaInlineCanvasView` — exactly what `DigiaSlot`
/// renders for an inline Canvas campaign — placed in a scrolling host screen, so each golden is the
/// card users see. The view is given its campaign directly rather than read from the SDK's shared
/// inline controller: other Canvas suites run in parallel and reset that controller, which would
/// empty the slot mid-capture. Nothing on screen may move with wall-clock time: the video never plays and the
/// Lottie is pinned to one frame.
///
/// Images and Lottie files are read from the Test Kit mock server's directory. Two goldens record
/// a stand-in rather than the authored media:
///   - canvas_bg_image: `image-1.png` is missing from the mock server, so `strawberry.jpg` is
///     drawn in its place;
///   - canvas_lottie_animation: `static-lottie.json` is missing, so the Lottie placeholder is drawn.
@Suite("Test Kit inline Canvas fixture goldens", .serialized, .tags(.canvas, .inline))
struct CanvasFixtureGoldenTests {

    /// Fixtures with no iOS golden.
    private static let excluded: Set<String> = ["canvas_divider_vertical"]

    private static let canvasFixtures = FixtureLoader.fixtureNames(campaignType: "canvas").filter { !excluded.contains($0) }
    private static let inlineCanvasFixtures = FixtureLoader.fixtureNames(campaignType: "inline_canvas")

    /// The Lottie is held at this point of its timeline: its first frame is not representative.
    private static let lottieProgress: CGFloat = 0.5

    @Test("matches the canvas fixture golden", .tags(.golden), arguments: canvasFixtures)
    @MainActor
    func testCanvasFixtureGolden(fixture: String) async throws {
        try await assertCanvasFixture(fixture, campaignType: "canvas", function: "testCanvasFixtureGolden")
    }

    @Test("matches the inline canvas fixture golden", .tags(.golden), arguments: inlineCanvasFixtures)
    @MainActor
    func testInlineCanvasFixtureGolden(fixture: String) async throws {
        try await assertCanvasFixture(fixture, campaignType: "inline_canvas", function: "testInlineCanvasFixtureGolden")
    }

    @MainActor
    private func assertCanvasFixture(
        _ fixture: String,
        campaignType: String,
        function: StaticString
    ) async throws {
        let json = try #require(
            FixtureLoader.loadFixture(campaignType: campaignType, fileName: fixture),
            "Fixture must load"
        )
        let standIn = withMissingImagesReplaced(json) as! [String: Any]
        let campaign = try #require(try CampaignModel.fromJson(standIn, designTokens: fixtureTokens(json)), "Fixture must decode to a campaign")
        guard case .inlineCanvas(let config) = campaign.config else {
            Issue.record("Fixture must decode to an inline canvas")
            return
        }
        // A synchronous memory-cache hit is dropped by `WebImage` (it publishes inside the view
        // update that asked for it); start empty so every image takes the asynchronous load, which
        // does publish, and wait for it below.
        SDImageCache.shared.clearMemory()

        let payload = CEPTriggerPayload(cepCampaignId: "test_canvas", campaignKey: campaign.campaignKey, cepMetadata: [:])
        let window = makeSlotWindow(config: config, payload: payload, device: .engageGolden)
        defer { ComponentTestHost.cleanupOverlayWindow(window) }

        // Media loads asynchronously (a file read, a Lottie decode); wait for it rather than for a
        // fixed time.
        try await awaitImagesLoaded(imageURLs(in: standIn))
        if hasExistingLottie(standIn) { try await awaitLottieLoaded(in: window) }

        // Exact within the perceptual tolerance, as the other fixture goldens.
        assertVisualGolden(
            matching: ComponentTestHost.settledImage(of: window),
            precision: 1.0,
            perceptualPrecision: 0.98,
            named: fixture,
            function: function
        )
    }

    /// A key window showing the slot between two content blocks, so the card's margins and rounded
    /// corners show against the page behind it.
    @MainActor
    private func makeSlotWindow(
        config: InlineCanvasConfig,
        payload: CEPTriggerPayload,
        device: ViewImageConfig
    ) -> UIWindow {
        let size = device.size!
        let window =
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            .map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(origin: .zero, size: size))
        window.frame = CGRect(origin: .zero, size: size)

        let host = SlotHostScreen(config: config, payload: payload, safeArea: device.safeArea)
            .environment(\.canvasVideoRuntime, Self.pausedVideo)
            .environment(\.canvasLottieRuntime, CanvasLottieRuntime(playbackMode: .frozen(progress: Self.lottieProgress)))
            // Appear animations jump to their end state, so the golden shows the settled card.
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        let controller = UIHostingController(rootView: host)
        if #available(iOS 16.4, *) {
            controller.safeAreaRegions = []
        }
        controller.view.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller
        window.makeKeyAndVisible()

        ComponentTestHost.drainRunLoop(for: 0.2)
        return window
    }

    /// A player that never starts: autoplay would put a playing video at a different frame in every run.
    private static let pausedVideo = CanvasVideoRuntime(
        makePlayer: { AVPlayer(playerItem: $0) },
        play: { _ in },
        pause: { $0.pause() },
        restart: { _ in }
    )

    // MARK: - Media

    /// A fixture can name an image the mock server does not ship; draw a known stand-in rather
    /// than an error, so the golden still shows the layout.
    private func withMissingImagesReplaced(_ value: Any) -> Any {
        switch value {
        case let string as String:
            guard let url = URL(string: string), url.isFileURL, isImage(url),
                  !FileManager.default.fileExists(atPath: url.path)
            else { return string }
            return url.deletingLastPathComponent().appendingPathComponent("strawberry.jpg").absoluteString
        case let dictionary as [String: Any]:
            return dictionary.mapValues(withMissingImagesReplaced)
        case let array as [Any]:
            return array.map(withMissingImagesReplaced)
        default:
            return value
        }
    }

    private func isImage(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "webp", "gif", "svg"].contains(url.pathExtension.lowercased())
    }

    /// Every Test Kit image URL in [value].
    private func imageURLs(in value: Any) -> [String] {
        switch value {
        case let string as String:
            guard let url = URL(string: string), url.isFileURL, isImage(url) else { return [] }
            return [string]
        case let dictionary as [String: Any]:
            return dictionary.values.flatMap(imageURLs)
        case let array as [Any]:
            return array.flatMap(imageURLs)
        default:
            return []
        }
    }

    /// Whether [value] names a Test Kit Lottie file that exists. One the mock server does not ship
    /// never loads, so its golden records the renderer's placeholder instead.
    private func hasExistingLottie(_ value: Any) -> Bool {
        switch value {
        case let string as String:
            guard let url = URL(string: string), url.isFileURL,
                  ["lottie", "json"].contains(url.pathExtension.lowercased())
            else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        case let dictionary as [String: Any]:
            return dictionary.values.contains(where: hasExistingLottie)
        case let array as [Any]:
            return array.contains(where: hasExistingLottie)
        default:
            return false
        }
    }

    /// Polls until `WebImage` has stored each decoded image (it does so just before publishing it),
    /// up to 5s; the capture then waits for the frame to settle.
    @MainActor
    private func awaitImagesLoaded(_ urls: [String]) async throws {
        for url in urls {
            for _ in 0..<250 where SDImageCache.shared.imageFromMemoryCache(forKey: url) == nil {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            try #require(SDImageCache.shared.imageFromMemoryCache(forKey: url) != nil, "Image did not load: \(url)")
        }
    }

    /// Polls until the canvas's `LottieAnimationView` has an animation installed, up to 5s.
    @MainActor
    private func awaitLottieLoaded(in window: UIWindow) async throws {
        for _ in 0..<250 where !hasLoadedLottie(window) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try #require(hasLoadedLottie(window), "Lottie did not load")
    }

    @MainActor
    private func hasLoadedLottie(_ view: UIView) -> Bool {
        if let lottie = view as? LottieAnimationView, lottie.animation != nil { return true }
        return view.subviews.contains { hasLoadedLottie($0) }
    }
}
}

/// The host app screen: the slot between a teal and a yellow block on a grey page, below the
/// notch, as the Flutter and Android canvas goldens lay it out.
private struct SlotHostScreen: View {
    let config: InlineCanvasConfig
    let payload: CEPTriggerPayload
    let safeArea: UIEdgeInsets

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Color(red: 0x26 / 255, green: 0xA6 / 255, blue: 0x9A / 255).frame(height: 120)
                DigiaInlineCanvasView(config: config, payload: payload, stepGate: CarouselStepGate(payload: payload))
                Color(red: 0xFF / 255, green: 0xCA / 255, blue: 0x28 / 255).frame(height: 120)
            }
        }
        .padding(.top, safeArea.top)
        .padding(.bottom, safeArea.bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(red: 0xEC / 255, green: 0xEF / 255, blue: 0xF1 / 255))
    }
}
