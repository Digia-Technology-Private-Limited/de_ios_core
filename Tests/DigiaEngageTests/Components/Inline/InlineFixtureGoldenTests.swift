import Foundation
import SDWebImage
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension RenderedUITests {
/// Pixel goldens for every shared inline banner, carousel, story and timer fixture.
///
/// The arguments are read from `sdk_testing_fixtures/campaigns/inline_banner/`, `inline_carousel/`,
/// `inline_story/` and `inline_timer/`, so a fixture added there is covered with no code change
/// (record it with `RECORD_SNAPSHOTS=true ./run-tests.sh inline`). Each fixture is decoded by
/// `CampaignModel.fromJson` and drawn by the view `DigiaSlot` picks for its config
/// (`DigiaInlineCanvasView`, `DigiaInlineStoryView`, ...), placed in a scrolling host screen. As in
/// `CanvasFixtureGoldenTests`, the view is given its campaign directly rather than read from the
/// SDK's shared inline controller, which suites running in parallel reset.
///
/// Nothing on screen may move with wall-clock time or depend on the network:
///   - remote images (picsum.photos) are drawn from the Test Kit's vendored `strawberry.jpg`, so
///     each golden shows the layout, not the authored photo;
///   - carousel autoplay is held off for a day, so the first slide is captured;
///   - timers are parsed against a frozen clock at `timerNow`.
@Suite("Test Kit inline banner, carousel, story and timer fixture goldens", .serialized, .tags(.inline))
struct InlineFixtureGoldenTests {

    /// 2d 03h 45m 13s before the timer fixtures' 2030-01-01 deadline: the countdown the Android and
    /// Flutter goldens show.
    private static let timerNowMs: Int64 = 1_893_269_687_000

    /// A clock that never advances: `nowMs()` adds the monotonic time elapsed since
    /// `continuousNanoseconds`, which is none when that is the largest value the clock can read.
    private static let timerNow = TrustedTimeAnchor(serverEpochMs: timerNowMs, continuousNanoseconds: .max)

    @Test("matches the inline banner fixture golden", .tags(.golden),
          arguments: FixtureLoader.fixtureNames(campaignType: "inline_banner"))
    @MainActor
    func testInlineBannerFixtureGolden(fixture: String) async throws {
        try await assertInlineFixture(fixture, campaignType: "inline_banner", function: "testInlineBannerFixtureGolden")
    }

    @Test("matches the inline carousel fixture golden", .tags(.golden),
          arguments: FixtureLoader.fixtureNames(campaignType: "inline_carousel"))
    @MainActor
    func testInlineCarouselFixtureGolden(fixture: String) async throws {
        try await assertInlineFixture(fixture, campaignType: "inline_carousel", function: "testInlineCarouselFixtureGolden")
    }

    @Test("matches the inline story fixture golden", .tags(.golden),
          arguments: FixtureLoader.fixtureNames(campaignType: "inline_story"))
    @MainActor
    func testInlineStoryFixtureGolden(fixture: String) async throws {
        try await assertInlineFixture(fixture, campaignType: "inline_story", function: "testInlineStoryFixtureGolden")
    }

    @Test("matches the inline timer fixture golden", .tags(.golden),
          arguments: FixtureLoader.fixtureNames(campaignType: "inline_timer"))
    @MainActor
    func testInlineTimerFixtureGolden(fixture: String) async throws {
        try await assertInlineFixture(fixture, campaignType: "inline_timer", function: "testInlineTimerFixtureGolden")
    }

    /// Snapshot file: `de_workspace/goldens/ios/InlineFixtureGoldenTests/<test>.<fixture>.png`.
    @MainActor
    private func assertInlineFixture(_ fixture: String, campaignType: String, function: StaticString) async throws {
        let json = try #require(
            FixtureLoader.loadFixture(campaignType: campaignType, fileName: fixture),
            "Failed to load fixture \(campaignType)/\(fixture).json"
        )
        let (standIn, imageURLs) = withLocalImages(json, fixture: fixture)
        let campaign = try #require(
            try CampaignModel.fromJson(withAutoPlayHeld(standIn) as! [String: Any], designTokens: fixtureTokens(json), timeAnchor: Self.timerNow),
            "Fixture must decode to a campaign"
        )
        let payload = CEPTriggerPayload(cepCampaignId: "test_inline", campaignKey: campaign.campaignKey, cepMetadata: [:])

        // The same dispatch as `DigiaSlot.slotContent`.
        let content: AnyView
        switch campaign.config {
        case .inline(let config): content = AnyView(InlineCarouselRenderer.makeView(config, payload: payload, stepGate: CarouselStepGate(payload: payload)))
        case .banner(let config): content = AnyView(DigiaInlineBannerView(config: config, payload: payload))
        case .story(let config): content = AnyView(DigiaInlineStoryView(config: config, payload: payload))
        case .inlineCanvas(let config): content = AnyView(DigiaInlineCanvasView(config: config, payload: payload, stepGate: CarouselStepGate(payload: payload)))
        default:
            Issue.record("Fixture must decode to an inline campaign")
            return
        }

        let window = makeSlotWindow(content: content, device: .engageGolden)
        defer { ComponentTestHost.cleanupOverlayWindow(window) }
        await awaitImagesLoaded(imageURLs)
        // A carousel rebuilds its slides as it settles on its first page, and a rebuilt `WebImage`
        // gets the now-cached image as a synchronous hit, which it drops (it publishes inside the
        // view update that asked for it), leaving the slide blank. Flipping the trait environment
        // re-evaluates every image renderer, which then draws it (as
        // `ComponentTestHost.makeCanvasSlotHost` does).
        if !imageURLs.isEmpty, let controller = window.rootViewController {
            // Awaited, not a spun run loop, so the suites running beside this one are not held up.
            controller.overrideUserInterfaceStyle = .dark
            try await Task.sleep(nanoseconds: 400_000_000)
            controller.overrideUserInterfaceStyle = .light
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        // Exact within the perceptual tolerance, as the other fixture goldens.
        assertVisualGolden(
            matching: ComponentTestHost.settledImage(of: window),
            precision: 1.0,
            perceptualPrecision: 0.98,
            named: fixture,
            function: function
        )
    }

    /// A key window showing the slot between two content blocks, as `CanvasFixtureGoldenTests`
    /// lays it out, so the card's margins and rounded corners show against the page behind it.
    @MainActor
    private func makeSlotWindow(content: AnyView, device: ViewImageConfig) -> UIWindow {
        let size = device.size!
        let window =
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            .map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(origin: .zero, size: size))
        window.frame = CGRect(origin: .zero, size: size)

        let controller = UIHostingController(rootView: InlineHostScreen(content: content, safeArea: device.safeArea))
        if #available(iOS 16.4, *) {
            controller.safeAreaRegions = []
        }
        controller.view.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller
        window.makeKeyAndVisible()

        ComponentTestHost.drainRunLoop(for: 0.2)
        return window
    }

    // MARK: - Determinism

    /// Replaces every remote image URL in [json] with the Test Kit's `strawberry.jpg`. Each stand-in
    /// URL carries a query unique to the fixture and image:
    /// `WebImage` drops a synchronous memory-cache hit (it publishes inside the view update that
    /// asked for it), so every image must take the asynchronous load, which does publish — without
    /// clearing the shared cache under the other suites. Returns the stand-in URLs to wait for.
    private func withLocalImages(_ json: [String: Any], fixture: String) -> (Any, [String]) {
        guard let workspace = FixtureLoader.workspaceURL() else { return (json, []) }
        let file = workspace.appendingPathComponent("testkit/mock-server/assets/strawberry.jpg")
        // One stand-in per occurrence, not per distinct URL: two views of the same URL would share a
        // cache key, and the second takes the synchronous hit `WebImage` drops.
        var standIns: [String] = []
        let replaced = replacingRemoteImages(json) {
            let url = "\(file.absoluteString)?standIn=\(fixture)-\(standIns.count)"
            standIns.append(url)
            return url
        }
        guard !standIns.isEmpty else { return (json, []) }
        return (replaced, standIns)
    }

    private func replacingRemoteImages(_ value: Any, with standIn: () -> String) -> Any {
        switch value {
        case let string as String:
            return isRemote(string) ? standIn() : string
        case let dictionary as [String: Any]:
            if isAction(dictionary) { return dictionary }
            // Sorted keys keep the occurrence numbering stable between runs.
            return Dictionary(uniqueKeysWithValues: dictionary.keys.sorted().map { ($0, replacingRemoteImages(dictionary[$0]!, with: standIn)) })
        case let array as [Any]:
            return array.map { replacingRemoteImages($0, with: standIn) }
        default:
            return value
        }
    }

    private func isRemote(_ string: String) -> Bool {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "http" || scheme == "https" { return true }
        // `FixtureLoader` has already pointed `{{TESTKIT_ASSET_ORIGIN}}` at a local file.
        return scheme == "file" && ["jpg", "jpeg", "png", "webp"].contains(url.pathExtension.lowercased())
    }

    private func isAction(_ dictionary: [String: Any]) -> Bool {
        (dictionary["type"] as? String)?.hasPrefix("Action.") == true
    }

    /// Holds a carousel's autoplay off for a day: at the authored interval the slide on screen would
    /// depend on how long the capture took.
    private func withAutoPlayHeld(_ value: Any) -> Any {
        switch value {
        case var dictionary as [String: Any]:
            if dictionary["autoPlay"] as? Bool == true, dictionary["autoPlayInterval"] != nil {
                dictionary["autoPlayInterval"] = 86_400_000
            }
            return dictionary.mapValues(withAutoPlayHeld)
        case let array as [Any]:
            return array.map(withAutoPlayHeld)
        default:
            return value
        }
    }

    /// Polls until `WebImage` has stored each decoded image (it does so just before publishing it),
    /// up to 5s in all. An image that never loads (one that is off screen in a lazy rail) is not an
    /// error here: the golden shows whatever is on screen.
    @MainActor
    private func awaitImagesLoaded(_ urls: [String]) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline,
              urls.contains(where: { SDImageCache.shared.imageFromMemoryCache(forKey: $0) == nil }) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
}

/// The host app screen: the slot between a teal and a yellow block on a grey page, below the notch.
private struct InlineHostScreen: View {
    let content: AnyView
    let safeArea: UIEdgeInsets

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Color(red: 0x26 / 255, green: 0xA6 / 255, blue: 0x9A / 255).frame(height: 120)
                content
                Color(red: 0xFF / 255, green: 0xCA / 255, blue: 0x28 / 255).frame(height: 120)
            }
        }
        .padding(.top, safeArea.top)
        .padding(.bottom, safeArea.bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(red: 0xEC / 255, green: 0xEF / 255, blue: 0xF1 / 255))
    }
}
