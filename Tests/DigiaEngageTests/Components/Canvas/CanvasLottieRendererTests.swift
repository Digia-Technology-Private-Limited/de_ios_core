import Foundation
import Lottie
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

// Test modes. The seam is CanvasLottieRuntime { loadSource, playbackMode }; the real renderer and the
// real LottieAnimationView run in every mounted test. Each test below is labelled with one mode:
//
//   Mode A  SPY LOADER     `loadSource` is a spy that records the requested URL and returns nil or throws,
//                          so no animation is installed. Asserts which URL was (or was not) requested.
//   Mode B  INJECTED REAL  `loadSource` returns a REAL animation read from a vendored file; the test then
//           ANIMATION      reads the real LottieAnimationView (progress, loop mode, playing, content mode,
//                          installed size). Playback is `.frozen(progress:)` or `.live`.
//   Mode C  PRODUCTION     `loadSource` is nil: the production loader reads a real local .json / .lottie
//           LOADER         file (or a missing one). Asserts the installed animation or its absence.
//   Golden                 Pixels of a presentation-layer capture (see ai_docs/media-testing.md).
//   No mode                Parsing, mapping or environment defaults only; nothing is mounted.
//
// See also ai_docs/video-widget-testing.md for the equivalent video modes.

@MainActor
@Suite("Canvas lottie renderer", .serialized, .tags(.canvas, .component, .media))
struct CanvasLottieRendererTests {

    // No mode: parser only.
    @Test("lottie parser preserves every authored playback option")
    func parserPreservesPlaybackOptions() throws {
        let widget = try parsedLottie([
            "source": ["url": "light.json", "darkUrl": "dark.json"],
            "autoplay": true,
            "loop": true,
            "fit": "cover",
        ])

        guard case .lottie(_, let source, let autoplay, let loop, let fit) = widget else {
            Issue.record("Expected a parsed lottie widget")
            return
        }
        #expect(source.url == "light.json")
        #expect(source.darkUrl == "dark.json")
        #expect(autoplay)
        #expect(loop)
        #expect(fit == "cover")
    }

    // No mode: parser only.
    @Test("lottie parser uses safe defaults for missing options")
    func parserDefaults() throws {
        let widget = try parsedLottie([:])
        guard case .lottie(_, let source, let autoplay, let loop, let fit) = widget else {
            Issue.record("Expected a parsed lottie widget")
            return
        }
        #expect(source.url.isEmpty)
        #expect(source.darkUrl == nil)
        #expect(autoplay)
        #expect(loop)
        #expect(fit == "cover")
    }

    // No mode: pure fit-to-contentMode mapping; nothing is mounted.
    @Test("lottie content mode maps string fit accurately")
    func contentModeMapping() {
        #expect("contain".canvasUIContentMode == .scaleAspectFit)
        #expect("fill".canvasUIContentMode == .scaleToFill)
        #expect("cover".canvasUIContentMode == .scaleAspectFill)
        #expect("unsupported".canvasUIContentMode == .scaleAspectFill)
    }

    // Mode A (spy loader): the spy must receive the authored URL.
    @Test("runtime custom loadSource intercepts URL and returns source")
    func runtimeCustomLoadSource() async throws {
        let probe = LottieRuntimeProbe()
        let testURL = URL(string: "https://example.invalid/mock.json")!

        let runtime = CanvasLottieRuntime(
            loadSource: { url in
                probe.record(url: url)
                return nil // simulate failure or custom source
            },
            playbackMode: .frozen(progress: 0.5)
        )

        let widget = lottieWidget(url: testURL.absoluteString)
        let window = mount(lottie: widget, runtime: runtime)
        let matched = await waitUntil { probe.requestedURLs.contains(testURL) }

        #expect(matched)
        unmount(window)
    }

    // Mode A (spy loader): the spy must receive the light URL, then the dark URL after the theme flip.
    @Test("theme changes switch between light url and darkUrl")
    func themeSwitching() async throws {
        let probe = LottieRuntimeProbe()
        let lightURL = URL(string: "https://example.invalid/light.json")!
        let darkURL = URL(string: "https://example.invalid/dark.json")!

        let runtime = CanvasLottieRuntime(
            loadSource: { url in
                probe.record(url: url)
                return nil
            },
            playbackMode: .frozen(progress: 0.0)
        )

        let widget = lottieWidget(url: lightURL.absoluteString, darkURL: darkURL.absoluteString)
        let theme = LottieThemeDriver()
        let harness = LottieThemeHarness(lottie: widget, theme: theme, runtime: runtime)
        let window = mount(harness: harness)

        let matchedLight = await waitUntil { probe.requestedURLs.contains(lightURL) }
        #expect(matchedLight)

        theme.isDark = true
        let matchedDark = await waitUntil { probe.requestedURLs.contains(darkURL) }
        #expect(matchedDark)

        unmount(window)
    }

    // Mode A (spy loader): the spy must receive the URL after variable interpolation.
    @Test("variable interpolation resolves template tokens in lottie url")
    func variableInterpolation() async throws {
        let probe = LottieRuntimeProbe()
        let runtime = CanvasLottieRuntime(
            loadSource: { url in
                probe.record(url: url)
                return nil
            },
            playbackMode: .frozen(progress: 0.0)
        )

        let widget = lottieWidget(url: "https://example.invalid/{{asset_id}}.json")
        let variables = VariableContext(values: ["asset_id": "resolved-celebration"], types: ["asset_id": "string"])
        let window = mount(lottie: widget, variables: variables, runtime: runtime)

        let expectedURL = URL(string: "https://example.invalid/resolved-celebration.json")!
        let matched = await waitUntil { probe.requestedURLs.contains(expectedURL) }

        #expect(matched)
        unmount(window)
    }

    // MARK: - Playback, loading and failure oracles

    // Mode B (injected real animation, frozen): real LottieAnimationView at progress 0.5, not playing.
    @Test("frozen playback installs the animation at the requested progress without playing")
    func frozenPlaybackStopsAtProgress() async throws {
        let animation = try await Self.animation(named: "static-lottie.json")
        let runtime = CanvasLottieRuntime(
            loadSource: { _ in animation.animationSource },
            playbackMode: .frozen(progress: 0.5)
        )
        let window = mount(lottie: lottieWidget(autoplay: true, loop: true), runtime: runtime)
        defer { unmount(window) }

        let view = try #require(await waitForAnimation(in: window))
        #expect(view.animation?.size == Self.staticJSONSize)
        #expect(view.currentProgress == 0.5)
        #expect(!view.isAnimationPlaying)
    }

    // Mode B (injected real animation, live): real LottieAnimationView playing state and loop mode for 4 option combinations.
    @Test("live playback follows the authored autoplay and loop options")
    func livePlaybackFollowsAutoplayAndLoop() async throws {
        let animation = try await Self.animation(named: "static-lottie.json")
        let runtime = CanvasLottieRuntime(
            loadSource: { _ in animation.animationSource }, playbackMode: .live)
        let cases: [(autoplay: Bool, loop: Bool, playing: Bool, mode: LottieLoopMode)] = [
            (true, true, true, .loop),
            (true, false, true, .playOnce),
            (false, true, false, .playOnce),
            (false, false, false, .playOnce),
        ]

        for expected in cases {
            let widget = lottieWidget(autoplay: expected.autoplay, loop: expected.loop)
            let window = mount(lottie: widget, runtime: runtime)
            let view = try #require(await waitForAnimation(in: window))

            #expect(view.isAnimationPlaying == expected.playing)
            #expect(view.loopMode == expected.mode)
            if !expected.autoplay { #expect(view.currentProgress == 0) }
            unmount(window)
        }
    }

    // Mode B (injected real animation): real LottieAnimationView.contentMode for contain, cover and fill.
    @Test("authored fit reaches the Lottie view content mode")
    func fitReachesContentMode() async throws {
        let animation = try await Self.animation(named: "static-lottie.json")
        let runtime = CanvasLottieRuntime(
            loadSource: { _ in animation.animationSource }, playbackMode: .frozen(progress: 0))
        let expected: [String: UIView.ContentMode] = [
            "contain": .scaleAspectFit, "cover": .scaleAspectFill, "fill": .scaleToFill,
        ]

        for (fit, mode) in expected {
            let window = mount(lottie: lottieWidget(fit: fit), runtime: runtime)
            let view = try #require(await waitForAnimation(in: window))
            #expect(view.contentMode == mode, "fit \(fit)")
            unmount(window)
        }
    }

    // Mode C (production loader): real local .json and .lottie files; installed animation size is the oracle.
    @Test("the production loader reads local .json and .lottie sources")
    func productionLoaderReadsLocalSources() async throws {
        let runtime = CanvasLottieRuntime(playbackMode: .frozen(progress: 0))
        let sources: [(file: String, size: CGSize)] = [
            ("static-lottie.json", Self.staticJSONSize),
            ("payday.lottie", Self.paydayLottieSize),
        ]

        for source in sources {
            let url = Self.assetURL(source.file).absoluteString
            let window = mount(lottie: lottieWidget(url: url), runtime: runtime)
            let view = try #require(await waitForAnimation(in: window), "\(source.file)")
            #expect(view.animation?.size == source.size, "\(source.file)")
            unmount(window)
        }
    }

    // Mode A + C: spy loaders that return nil or throw (A), and missing files through the production loader (C); no animation may install.
    @Test("a failed load installs no animation")
    func failedLoadInstallsNothing() async throws {
        let missingJSON = Self.assetURL("missing.json").absoluteString
        let missingDotLottie = Self.assetURL("missing.lottie").absoluteString
        let cases: [(name: String, url: String, runtime: CanvasLottieRuntime)] = [
            ("loader returns nil", "https://example.invalid/a.json",
             CanvasLottieRuntime(loadSource: { _ in nil }, playbackMode: .frozen(progress: 0))),
            ("loader throws", "https://example.invalid/a.json",
             CanvasLottieRuntime(
                loadSource: { _ in throw URLError(.cannotLoadFromNetwork) },
                playbackMode: .frozen(progress: 0))),
            ("missing json", missingJSON, CanvasLottieRuntime(playbackMode: .frozen(progress: 0))),
            ("missing dotlottie", missingDotLottie,
             CanvasLottieRuntime(playbackMode: .frozen(progress: 0))),
        ]

        for failing in cases {
            let window = mount(lottie: lottieWidget(url: failing.url), runtime: failing.runtime)
            // A real load that fails never produces a signal to wait on, so give the loader its turn.
            _ = await waitUntil(timeout: 0.5) { false }
            #expect(lottieViews(in: window).allSatisfy { $0.animation == nil }, "\(failing.name)")
            unmount(window)
        }
    }

    // Mode A (spy loader): the spy must see no URL and no LottieAnimationView may be mounted.
    @Test("empty and malformed URLs never reach a loader and mount no Lottie view")
    func unusableURLsMountNothing() async {
        // A blank "   " is deliberately absent: `URL(string:)` percent-encodes it on current iOS, so it is
        // handed to the loader and fails there (see ai_docs/media-testing.md).
        for url in ["", "http://[invalid"] {
            let probe = LottieRuntimeProbe()
            let runtime = CanvasLottieRuntime(
                loadSource: { requested in
                    probe.record(url: requested)
                    return nil
                },
                playbackMode: .frozen(progress: 0)
            )
            let window = mount(lottie: lottieWidget(url: url), runtime: runtime)
            _ = await waitUntil(timeout: 0.3) { false }

            #expect(probe.requestedURLs.isEmpty, "url \(url.debugDescription)")
            #expect(lottieViews(in: window).isEmpty, "url \(url.debugDescription)")
            unmount(window)
        }
    }

    // Mode B (injected real animation): the loader returns a different real animation per URL; the installed size must change on the theme flip.
    @Test("switching to the dark URL installs the other animation")
    func themeSwitchInstallsOtherAnimation() async throws {
        let light = try await Self.animation(named: "static-lottie.json")
        let dark = try await Self.animation(named: "payday.lottie")
        let lightURL = URL(string: "https://example.invalid/light.json")!
        let darkURL = URL(string: "https://example.invalid/dark.json")!
        let runtime = CanvasLottieRuntime(
            loadSource: { url in url == darkURL ? dark.animationSource : light.animationSource },
            playbackMode: .frozen(progress: 0)
        )
        let theme = LottieThemeDriver()
        let widget = lottieWidget(url: lightURL.absoluteString, darkURL: darkURL.absoluteString)
        let window = mount(harness: LottieThemeHarness(lottie: widget, theme: theme, runtime: runtime))
        defer { unmount(window) }

        let first = try #require(await waitForAnimation(in: window))
        #expect(first.animation?.size == Self.staticJSONSize)

        theme.isDark = true
        let switched = await waitUntil {
            lottieViews(in: window).first?.animation?.size == Self.paydayLottieSize
        }
        #expect(switched)
    }

    // No mode: environment default only (`.live` playback, no custom loader); nothing is mounted.
    @Test("production starts from the live runtime, never a frozen or fake one")
    func defaultRuntimeIsLive() {
        let runtime = EnvironmentValues().canvasLottieRuntime
        #expect(runtime.playbackMode == .live)
        #expect(runtime.loadSource == nil)
    }

    // Mode A (failing spy loader) + Golden: pixels of the labelled "Lottie" placeholder.
    @Test("a failed load shows the labelled placeholder", .tags(.golden))
    func failedLoadShowsLabelledPlaceholder() async throws {
        let probe = LottieRuntimeProbe()
        let runtime = CanvasLottieRuntime(
            loadSource: { url in
                probe.record(url: url)
                return nil
            },
            playbackMode: .frozen(progress: 0)
        )
        let controller = ComponentTestHost.makeComponentHost(
            rootView: AnyView(lottieStage(lottieWidget(), runtime: runtime)),
            size: CGSize(width: 320, height: 200),
            backgroundColor: .white
        )
        let window = mount(controller)
        defer { unmount(window) }
        // The placeholder turns into the labelled one only after the loader has answered and SwiftUI has
        // re-rendered, which can lag under load. Wait for the outcome itself: a capture that is no longer
        // blank (the stage background is plain white).
        #expect(await waitUntil { !probe.requestedURLs.isEmpty })
        let rendered = await waitUntil {
            Self.hasMoreThanOneColor(ComponentTestHost.renderImage(of: controller.view))
        }
        try #require(rendered, "the failed-load placeholder never rendered")
        ComponentTestHost.drainRunLoop(for: 0.2)

        assertVisualGolden(
            matching: ComponentTestHost.renderImage(of: controller.view),
            precision: 0.999,
            perceptualPrecision: 0.98
        )
    }

    // MARK: - Helpers

    // MARK: - Fixtures and view-tree probes

    private static let staticJSONSize = CGSize(width: 1143, height: 818)
    private static let paydayLottieSize = CGSize(width: 1080, height: 798)

    private static func assetURL(_ name: String) -> URL {
        let workspace = FixtureLoader.workspaceURL()!
        return workspace.appendingPathComponent("testkit/mock-server/assets").appendingPathComponent(name)
    }

    private static func animation(named name: String) async throws -> LottieAnimationBox {
        let url = assetURL(name)
        if url.pathExtension == "lottie" {
            let file = try await DotLottieFile.loadedFrom(url: url)
            return LottieAnimationBox(animationSource: try #require(file.animationSource))
        }
        let animation = try #require(await LottieAnimation.loadedFrom(url: url))
        return LottieAnimationBox(animationSource: try #require(animation.animationSource))
    }

    private static func hasMoreThanOneColor(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage, let data = cgImage.dataProvider?.data,
            let bytes = CFDataGetBytePtr(data)
        else { return false }
        let bytesPerPixel = max(cgImage.bitsPerPixel / 8, 3)
        let first = (bytes[0], bytes[1], bytes[2])
        for pixel in stride(from: 0, to: cgImage.width * cgImage.height, by: 97) {
            let offset = pixel * bytesPerPixel
            if (bytes[offset], bytes[offset + 1], bytes[offset + 2]) != first { return true }
        }
        return false
    }

    private func lottieViews(in window: UIWindow) -> [LottieAnimationView] {
        var found: [LottieAnimationView] = []
        func walk(_ view: UIView) {
            if let lottie = view as? LottieAnimationView { found.append(lottie) }
            view.subviews.forEach(walk)
        }
        if let root = window.rootViewController?.view { walk(root) }
        return found
    }

    /// Waits until a `LottieAnimationView` in the window has an animation installed.
    private func waitForAnimation(in window: UIWindow) async -> LottieAnimationView? {
        _ = await waitUntil { lottieViews(in: window).first?.animation != nil }
        ComponentTestHost.drainRunLoop(for: 0.1)
        return lottieViews(in: window).first(where: { $0.animation != nil })
    }

    private func lottieStage(
        _ lottie: CampaignCanvasWidget, runtime: CanvasLottieRuntime
    ) -> some View {
        var stage = CampaignCanvasStage(
            canvas: CampaignCanvas(
                version: 2,
                width: 320,
                height: 200,
                background: .solid(.literal("#FFFFFFFF")),
                children: [
                    .widget(
                        id: "lottie",
                        rect: CampaignCanvasRect(x: 0, y: 0, width: 320, height: 200),
                        widget: lottie
                    )
                ]
            ),
            authoredCornerRadius: 0,
            isDark: false,
            showBackground: true,
            onAction: { _ in }
        )
        stage.animateWidgetsOnAppear = false
        return stage.ignoresSafeArea().environment(\.canvasLottieRuntime, runtime)
    }

    private func parsedLottie(_ props: [String: Any]) throws -> CampaignCanvasWidget {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 320,
            "canvasHeight": 200,
            "children": [[
                "kind": "widget",
                "id": "lottie",
                "rect": ["x": 0, "y": 0, "width": 1, "height": 1],
                "widget": ["type": "digia/lottie", "props": props],
            ]],
        ])
        guard case .widget(_, _, let widget) = canvas.children.first else {
            throw LottieTestError.missingWidget
        }
        return widget
    }

    private func lottieWidget(
        url: String = "https://example.invalid/anim.json",
        darkURL: String? = nil,
        autoplay: Bool = false,
        loop: Bool = false,
        fit: String = "contain"
    ) -> CampaignCanvasWidget {
        .lottie(
            box: .none,
            source: CampaignCanvasMediaSource(url: url, darkUrl: darkURL, placeholder: nil),
            autoplay: autoplay,
            loop: loop,
            fit: fit
        )
    }

    private func mount(
        lottie: CampaignCanvasWidget,
        isDark: Bool = false,
        variables: VariableContext? = nil,
        runtime: CanvasLottieRuntime
    ) -> UIWindow {
        let canvas = CampaignCanvas(
            version: 2,
            width: 320,
            height: 200,
            background: .solid(.literal("#FFFFFFFF")),
            children: [
                .widget(
                    id: "lottie",
                    rect: CampaignCanvasRect(x: 0, y: 0, width: 320, height: 200),
                    widget: lottie
                )
            ]
        )
        var stage = CampaignCanvasStage(
            canvas: canvas,
            authoredCornerRadius: 0,
            isDark: isDark,
            showBackground: true,
            onAction: { _ in }
        )
        stage.animateWidgetsOnAppear = false
        let root = AnyView(
            stage
                .environment(\.canvasLottieRuntime, runtime)
                .environment(\.digiaVariables, variables)
        )
        return mount(
            ComponentTestHost.makeComponentHost(
                rootView: root,
                size: CGSize(width: 320, height: 200),
                backgroundColor: .white
            )
        )
    }

    private func mount(harness: LottieThemeHarness) -> UIWindow {
        mount(
            ComponentTestHost.makeComponentHost(
                rootView: AnyView(harness),
                size: CGSize(width: 320, height: 200),
                backgroundColor: .white
            )
        )
    }

    private func mount<Content: View>(_ controller: UIHostingController<Content>) -> UIWindow {
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: controller.view.bounds)
        }
        window.frame = controller.view.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        controller.view.layoutIfNeeded()
        ComponentTestHost.drainRunLoop(for: 0.05)
        return window
    }

    private func unmount(_ window: UIWindow) {
        if let root = window.rootViewController {
            root.beginAppearanceTransition(false, animated: false)
            root.endAppearanceTransition()
        }
        window.rootViewController = nil
        window.isHidden = true
        window.resignKey()
        ComponentTestHost.drainRunLoop(for: 0.02)
    }

    private func waitUntil(timeout: TimeInterval = 10.0, condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            ComponentTestHost.drainRunLoop(for: 0.02)
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}

@MainActor
private final class LottieThemeDriver: ObservableObject {
    @Published var isDark = false
}

private struct LottieThemeHarness: View {
    let lottie: CampaignCanvasWidget
    @ObservedObject var theme: LottieThemeDriver
    let runtime: CanvasLottieRuntime

    var body: some View {
        var stage = CampaignCanvasStage(
            canvas: CampaignCanvas(
                version: 2,
                width: 320,
                height: 200,
                background: .solid(.literal("#FFFFFFFF")),
                children: [
                    .widget(
                        id: "lottie",
                        rect: CampaignCanvasRect(x: 0, y: 0, width: 320, height: 200),
                        widget: lottie
                    )
                ]
            ),
            authoredCornerRadius: 0,
            isDark: theme.isDark,
            showBackground: true,
            onAction: { _ in }
        )
        stage.animateWidgetsOnAppear = false
        return stage.environment(\.canvasLottieRuntime, runtime)
    }
}

/// `LottieAnimationSource` is immutable once built; the loader closures only read it.
private struct LottieAnimationBox: @unchecked Sendable {
    let animationSource: LottieAnimationSource
}

private enum LottieTestError: Error {
    case missingWidget
}

private final class LottieRuntimeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    var requestedURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }

    func record(url: URL) {
        lock.lock()
        defer { lock.unlock() }
        urls.append(url)
    }
}
