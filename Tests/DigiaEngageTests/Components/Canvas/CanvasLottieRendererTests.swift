import Foundation
import Lottie
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

// The canvas Lottie widget runs the real renderer, the real `MediaLottie` and the production loader in
// every mounted test. The only seams are `CanvasLottieRuntime.playbackMode` (`.frozen` pins a frame so
// pixels do not race the display link) and the network: the fake origin (`MediaOrigin`) serves real
// `.json` / `.lottie` bytes or a real status, and `file://` URLs read real local files. Each test below
// is labelled with one mode:
//
//   Mode A  ORIGIN        the fake origin answers a status or a failure; the test reads which URL was
//                         requested (or that none was) and that no animation installed.
//   Mode B  SERVED REAL   the fake origin serves a REAL animation; the test then reads the real
//           ANIMATION     LottieAnimationView (progress, loop mode, playing, content mode, installed
//                         size). Playback is `.frozen(progress:)` or `.live`.
//   Mode C  LOCAL FILE    a real local .json / .lottie file (or a missing one). Asserts the installed
//                         animation or its absence.
//   No mode               Parsing, mapping or environment defaults only; nothing is mounted.
//
// See also ai_docs/video-widget-testing.md for the equivalent video modes.

extension RenderedUITests {
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

    // Mode A: the canvas asks for the authored URL.
    @Test("the canvas requests the authored lottie url")
    func requestsTheAuthoredURL() async throws {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("mock.json")
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: target)

        let window = mount(lottie: lottieWidget(url: target.absoluteString), runtime: .live)
        defer { unmount(window) }

        #expect(await waitUntil { !MediaOrigin.requests(for: target).isEmpty })
    }

    // Mode A: the light URL is requested, then the dark URL after the theme flip.
    @Test("theme changes switch between light url and darkUrl")
    func themeSwitching() async throws {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let lightURL = MediaOrigin.url("light.json")
        let darkURL = MediaOrigin.url("dark.json")
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: lightURL)
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: darkURL)

        let widget = lottieWidget(url: lightURL.absoluteString, darkURL: darkURL.absoluteString)
        let theme = LottieThemeDriver()
        let harness = LottieThemeHarness(lottie: widget, theme: theme, runtime: .live)
        let window = mount(harness: harness)
        defer { unmount(window) }

        #expect(await waitUntil { !MediaOrigin.requests(for: lightURL).isEmpty })
        #expect(MediaOrigin.requests(for: darkURL).isEmpty)

        theme.isDark = true
        #expect(await waitUntil { !MediaOrigin.requests(for: darkURL).isEmpty })
    }

    // Mode A: the URL that is requested is the one after variable interpolation.
    @Test("variable interpolation resolves template tokens in lottie url")
    func variableInterpolation() async throws {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let template = MediaOrigin.rawURL("{{asset_id}}.json")
        let expectedURL = try #require(URL(string: template.replacingOccurrences(of: "{{asset_id}}", with: "resolved-celebration")))
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: expectedURL)

        let widget = lottieWidget(url: template)
        let variables = VariableContext(values: ["asset_id": "resolved-celebration"], types: ["asset_id": "string"])
        let window = mount(lottie: widget, variables: variables, runtime: .live)
        defer { unmount(window) }

        #expect(await waitUntil { !MediaOrigin.requests(for: expectedURL).isEmpty })
    }

    // MARK: - Playback, loading and failure oracles

    // Mode B (served real animation, frozen): real LottieAnimationView at progress 0.5, not playing.
    @Test("frozen playback installs the animation at the requested progress without playing")
    func frozenPlaybackStopsAtProgress() async throws {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let runtime = CanvasLottieRuntime(playbackMode: .frozen(progress: 0.5))
        let url = try Self.serve("static-lottie.json")
        let window = mount(lottie: lottieWidget(url: url, autoplay: true, loop: true), runtime: runtime)
        defer { unmount(window) }

        let view = try #require(await waitForAnimation(in: window))
        #expect(view.animation?.size == Self.staticJSONSize)
        #expect(view.currentProgress == 0.5)
        #expect(!view.isAnimationPlaying)
    }

    // Mode B (served real animation, live): real LottieAnimationView playing state and loop mode for 4 option combinations.
    @Test("live playback follows the authored autoplay and loop options")
    func livePlaybackFollowsAutoplayAndLoop() async throws {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let runtime = CanvasLottieRuntime(playbackMode: .live)
        let url = try Self.serve("static-lottie.json")
        let cases: [(autoplay: Bool, loop: Bool, playing: Bool, mode: LottieLoopMode)] = [
            (true, true, true, .loop),
            (true, false, true, .playOnce),
            (false, true, false, .playOnce),
            (false, false, false, .playOnce),
        ]

        for expected in cases {
            let widget = lottieWidget(url: url, autoplay: expected.autoplay, loop: expected.loop)
            let window = mount(lottie: widget, runtime: runtime)
            let view = try #require(await waitForAnimation(in: window))

            #expect(view.isAnimationPlaying == expected.playing)
            #expect(view.loopMode == expected.mode)
            if !expected.autoplay { #expect(view.currentProgress == 0) }
            unmount(window)
        }
    }

    // Mode B (served real animation): real LottieAnimationView.contentMode for contain, cover and fill.
    @Test("authored fit reaches the Lottie view content mode")
    func fitReachesContentMode() async throws {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let runtime = CanvasLottieRuntime(playbackMode: .frozen(progress: 0))
        let url = try Self.serve("static-lottie.json")
        let expected: [String: UIView.ContentMode] = [
            "contain": .scaleAspectFit, "cover": .scaleAspectFill, "fill": .scaleToFill,
        ]

        for (fit, mode) in expected {
            let window = mount(lottie: lottieWidget(url: url, fit: fit), runtime: runtime)
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

    // Mode A + C: a 404 and a lost connection from the origin (A), and missing files (C); no animation may install.
    @Test("a failed load installs no animation")
    func failedLoadInstallsNothing() async throws {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let notFound = MediaOrigin.url("gone.json")
        MediaOrigin.set(.status(404, Data("not found".utf8)), for: notFound)
        let offline = MediaOrigin.url("offline.json")
        MediaOrigin.set(.fail(.notConnectedToInternet), for: offline)
        let cases: [(name: String, url: String)] = [
            ("404", notFound.absoluteString),
            ("lost connection", offline.absoluteString),
            ("missing json", Self.assetURL("missing.json").absoluteString),
            ("missing dotlottie", Self.assetURL("missing.lottie").absoluteString),
        ]

        for failing in cases {
            let window = mount(lottie: lottieWidget(url: failing.url), runtime: .init(playbackMode: .frozen(progress: 0)))
            // A real load that fails never produces a signal to wait on, so give the loader its turn.
            _ = await waitUntil(timeout: 0.5) { false }
            #expect(lottieViews(in: window).allSatisfy { $0.animation == nil }, "\(failing.name)")
            unmount(window)
        }
    }

    // Mode A: nothing is requested and no LottieAnimationView is mounted.
    @Test("empty and malformed URLs never reach the network and mount no Lottie view")
    func unusableURLsMountNothing() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        // A blank "   " is deliberately absent: `URL(string:)` percent-encodes it on current iOS, so it is
        // handed to the loader and fails there (see ai_docs/media-testing.md).
        for url in ["", "http://[invalid"] {
            let window = mount(lottie: lottieWidget(url: url), runtime: .init(playbackMode: .frozen(progress: 0)))
            _ = await waitUntil(timeout: 0.3) { false }

            #expect(MediaOrigin.totalRequestCount() == 0, "url \(url.debugDescription)")
            #expect(lottieViews(in: window).isEmpty, "url \(url.debugDescription)")
            unmount(window)
        }
    }

    // Mode B (served real animation): a different real animation per URL; the installed size must change on the theme flip.
    @Test("switching to the dark URL installs the other animation")
    func themeSwitchInstallsOtherAnimation() async throws {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let lightURL = try Self.serve("static-lottie.json", as: "light.json")
        let darkURL = try Self.serve("payday.lottie", as: "dark.lottie")
        let runtime = CanvasLottieRuntime(playbackMode: .frozen(progress: 0))
        let theme = LottieThemeDriver()
        let widget = lottieWidget(url: lightURL, darkURL: darkURL)
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

    // No mode: environment default only (`.live` playback); nothing is mounted.
    @Test("production starts from the live runtime, never a frozen one")
    func defaultRuntimeIsLive() {
        #expect(EnvironmentValues().canvasLottieRuntime.playbackMode == .live)
    }

    // MARK: - Helpers

    // MARK: - Fixtures and view-tree probes

    private static let staticJSONSize = CGSize(width: 1143, height: 818)
    private static let paydayLottieSize = CGSize(width: 1080, height: 798)

    private static func assetURL(_ name: String) -> URL {
        let workspace = FixtureLoader.workspaceURL()!
        return workspace.appendingPathComponent("testkit/mock-server/assets").appendingPathComponent(name)
    }

    /// Serves the Test Kit file `file` from the fake origin as `name` (its extension picks the loader)
    /// and returns the URL.
    private static func serve(_ file: String, as name: String? = nil) throws -> String {
        let target = MediaOrigin.url(name ?? file)
        MediaOrigin.set(.status(200, try testkitAsset(file)), for: target)
        return target.absoluteString
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
                .ignoresSafeArea()
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
                rootView: AnyView(harness.ignoresSafeArea()),
                size: CGSize(width: 320, height: 200),
                backgroundColor: .white
            )
        )
    }

    private func mount<Content: View>(_ controller: UIHostingController<Content>) -> UIWindow {
        ComponentTestHost.mount(controller)
    }

    private func unmount(_ window: UIWindow) {
        ComponentTestHost.unmount(window)
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

private enum LottieTestError: Error {
    case missingWidget
}
