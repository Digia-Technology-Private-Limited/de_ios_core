import AVFoundation
import AVKit
import SnapshotTesting
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

// Test modes (see ai_docs/video-widget-testing.md, section 4.2). Each test below is labelled with one:
//
//   Mode A  SPY      The real renderer and real AVPlayerViewController run; a spy CanvasVideoRuntime
//                    (VideoRuntimeProbe) records every make/play/pause/restart and returns an EMPTY
//                    AVPlayer, so no media loads. Fast and exact.
//   Mode B  LIVE     The real renderer drives the LIVE runtime (LiveVideoRecorder) on a REAL AVPlayer
//                    with a generated local mp4. Tagged `slow`; waits with `await`.
//   Mode C  ADAPTER  The live runtime closures on a real AVPlayer, with NO view or renderer.
//   No mode          Parsing or model logic only; no player runtime is involved.

@MainActor
@Suite("Canvas video renderer", .serialized, .tags(.canvas, .component, .media))
struct CanvasVideoRendererTests {
    // No mode: parser only, no player runtime.
    @Test("video parser preserves every authored playback option")
    func parserPreservesPlaybackOptions() throws {
        let widget = try parsedVideo([
            "source": ["url": "light.mp4", "darkUrl": "dark.mp4"],
            "autoplay": true,
            "loop": true,
            "muted": true,
            "showControls": false,
            "fit": "contain",
        ])

        guard
            case .video(_, let source, let autoplay, let loop, let muted, let controls, let fit) =
                widget
        else {
            Issue.record("Expected a parsed video widget")
            return
        }
        #expect(source.url == "light.mp4")
        #expect(source.darkUrl == "dark.mp4")
        #expect(autoplay)
        #expect(loop)
        #expect(muted)
        #expect(!controls)
        #expect(fit == "contain")
    }

    // No mode: parser only, no player runtime.
    @Test("video parser uses safe defaults and normalizes unsupported fit values")
    func parserDefaults() throws {
        guard
            case .video(_, let source, let autoplay, let loop, let muted, let controls, let fit) =
                try parsedVideo(["fit": "fill"])
        else {
            Issue.record("Expected a parsed video widget")
            return
        }
        #expect(source.url.isEmpty)
        #expect(!autoplay)
        #expect(!loop)
        #expect(!muted)
        #expect(controls)
        #expect(fit == "cover")
    }

    // Mode A (spy): URLs built, player count and `isMuted` are read from the spy.
    @Test("direct video creates one player and applies the authored mute value")
    func createsPlayerAndAppliesMute() {
        for muted in [false, true] {
            let probe = VideoRuntimeProbe()
            let window = mount(video: videoWidget(muted: muted), runtime: probe.runtime)

            #expect(probe.madeURLs == [URL(string: "https://example.invalid/video.mp4")!])
            #expect(probe.players.count == 1)
            #expect(probe.players.first?.isMuted == muted)
            unmount(window)
        }
    }

    // Mode A (spy): the real AVPlayerViewController is inspected; the spy supplies an empty player.
    @Test("controls and content mode reach the production AVPlayerViewController")
    func controlsAndGravity() throws {
        for controls in [false, true] {
            for fit in ["cover", "contain"] {
                let probe = VideoRuntimeProbe()
                let window = mount(
                    video: videoWidget(showControls: controls, fit: fit),
                    runtime: probe.runtime
                )
                let controller = try #require(findPlayerController(in: window.rootViewController))

                #expect(controller.showsPlaybackControls == controls)
                #expect(
                    controller.videoGravity
                        == (fit == "contain" ? .resizeAspect : .resizeAspectFill))
                unmount(window)
            }
        }
    }

    // Mode A (spy): the spy counts `play` calls.
    @Test("autoplay starts exactly once only when requested")
    func autoplay() {
        for enabled in [false, true] {
            let probe = VideoRuntimeProbe()
            let window = mount(video: videoWidget(autoplay: enabled), runtime: probe.runtime)

            #expect(probe.playCount == (enabled ? 1 : 0))
            unmount(window)
        }
    }

    // Mode A (spy): the test posts AVPlayerItemDidPlayToEndTime; the spy counts `restart` calls.
    @Test("loop restarts only the player item that reached its end")
    func loopPlayback() throws {
        for enabled in [false, true] {
            let probe = VideoRuntimeProbe()
            let window = mount(video: videoWidget(loop: enabled), runtime: probe.runtime)
            let item = try #require(probe.items.first)

            NotificationCenter.default.post(
                name: .AVPlayerItemDidPlayToEndTime,
                object: AVPlayerItem(url: URL(string: "https://example.invalid/unrelated.mp4")!)
            )
            ComponentTestHost.drainRunLoop(for: 0.05)
            #expect(probe.restartCount == 0)

            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
            ComponentTestHost.drainRunLoop(for: 0.05)

            #expect(probe.restartCount == (enabled ? 1 : 0))
            unmount(window)

            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
            ComponentTestHost.drainRunLoop(for: 0.05)
            #expect(probe.restartCount == (enabled ? 1 : 0))
        }
    }

    // Mode A (spy): the spy counts `pause` calls after the window is removed.
    @Test("removing the Canvas pauses and releases the direct player")
    func teardownPausesPlayer() {
        let probe = VideoRuntimeProbe()
        let window = mount(video: videoWidget(), runtime: probe.runtime)
        #expect(probe.pauseCount == 0)

        unmount(window)

        #expect(probe.pauseCount == 1)
    }

    // Mode A (spy): the spy must see no player being built.
    @Test("an empty media URL degrades without constructing a player")
    func emptySourceDoesNotCreatePlayer() {
        let probe = VideoRuntimeProbe()
        let window = mount(video: videoWidget(url: ""), runtime: probe.runtime)
        defer { unmount(window) }

        #expect(probe.madeURLs.isEmpty)
        #expect(findPlayerController(in: window.rootViewController) == nil)
    }

    // Mode A (spy): the spy must see no player being built.
    @Test("a malformed media URL degrades without constructing a player")
    func malformedSourceDoesNotCreatePlayer() {
        let probe = VideoRuntimeProbe()
        let window = mount(video: videoWidget(url: "http://["), runtime: probe.runtime)
        defer { unmount(window) }

        #expect(probe.madeURLs.isEmpty)
        #expect(findPlayerController(in: window.rootViewController) == nil)
    }

    // Mode A (spy): the spy records which URL the renderer built an item for.
    @Test("light and dark media URLs select the correct asset")
    func themeSelectsMediaURL() {
        for isDark in [false, true] {
            let probe = VideoRuntimeProbe()
            let window = mount(
                video: videoWidget(
                    url: "https://example.invalid/light.mp4",
                    darkURL: "https://example.invalid/dark.mp4"),
                isDark: isDark,
                runtime: probe.runtime
            )

            #expect(
                probe.madeURLs.first?.absoluteString
                    == (isDark
                        ? "https://example.invalid/dark.mp4" : "https://example.invalid/light.mp4")
            )
            unmount(window)
        }

        let probe = VideoRuntimeProbe()
        let window = mount(
            video: videoWidget(url: "https://example.invalid/light.mp4", darkURL: ""),
            isDark: true,
            runtime: probe.runtime
        )
        #expect(probe.madeURLs.first?.absoluteString == "https://example.invalid/light.mp4")
        unmount(window)
    }

    // Mode A (spy): dark-mode flip; the spy records the second URL, the pause and the second autoplay.
    @Test("changing the selected theme URL replaces and pauses the existing player")
    func themeChangeReplacesPlayer() {
        let probe = VideoRuntimeProbe()
        let theme = VideoThemeDriver()
        let video = videoWidget(
            url: "https://example.invalid/light.mp4",
            darkURL: "https://example.invalid/dark.mp4",
            autoplay: true,
            muted: true
        )
        let root = VideoThemeHarness(video: video, theme: theme, runtime: probe.runtime)
        let controller = ComponentTestHost.makeComponentHost(
            rootView: root,
            size: CGSize(width: 320, height: 180),
            backgroundColor: .black
        )
        let window = mount(controller)

        #expect(probe.madeURLs.map(\.absoluteString) == ["https://example.invalid/light.mp4"])
        #expect(probe.playCount == 1)
        theme.isDark = true
        ComponentTestHost.drainRunLoop(for: 0.3)

        #expect(
            probe.madeURLs.map(\.absoluteString) == [
                "https://example.invalid/light.mp4",
                "https://example.invalid/dark.mp4",
            ])
        #expect(probe.pauseCount == 1)
        #expect(probe.playCount == 2)
        #expect(probe.players.allSatisfy { $0.isMuted })

        unmount(window)
        #expect(probe.pauseCount == 2)
    }

    // Mode A (spy): the spy records the URL after variable interpolation.
    @Test("runtime variables are resolved before player construction")
    func variablesResolveBeforeLoading() {
        let probe = VideoRuntimeProbe()
        let variables = VariableContext(values: ["clip": "welcome"], types: ["clip": "string"])
        let window = mount(
            video: videoWidget(url: "https://example.invalid/{{clip}}.mp4"),
            variables: variables,
            runtime: probe.runtime
        )
        defer { unmount(window) }

        #expect(probe.madeURLs.first?.absoluteString == "https://example.invalid/welcome.mp4")
    }

    // Mode A (spy): the spy must see no direct player, because the story engine takes over.
    @Test("story playback delegates to the story media engine instead of creating a direct player")
    func storyPlaybackUsesStoryEngine() {
        let probe = VideoRuntimeProbe()
        let window = mount(
            video: videoWidget(url: "https://example.invalid/story.mp4"),
            usesStoryPlayback: true,
            runtime: probe.runtime
        )
        defer { unmount(window) }

        #expect(probe.madeURLs.isEmpty)
    }

    // No mode: model logic only (`isHitTestable`); nothing is mounted and no runtime is used.
    @Test("video consumes touches only when native controls are visible")
    func hitTestingMatchesControls() {
        let interactive = canvasChild(video: videoWidget(showControls: true))
        let decorative = canvasChild(video: videoWidget(showControls: false))

        #expect(interactive.isHitTestable)
        #expect(!decorative.isHitTestable)
    }

    // Mode A (spy): URL change; end-of-item notifications for the old and new item against the spy's restart count.
    @Test("old item's end never restarts the replacement player after a URL change")
    func loopObserverFollowsTheCurrentItem() throws {
        let probe = VideoRuntimeProbe()
        let theme = VideoThemeDriver()
        let video = videoWidget(
            url: "https://example.invalid/light.mp4",
            darkURL: "https://example.invalid/dark.mp4",
            loop: true
        )
        let controller = ComponentTestHost.makeComponentHost(
            rootView: VideoThemeHarness(video: video, theme: theme, runtime: probe.runtime),
            size: CGSize(width: 320, height: 180),
            backgroundColor: .black
        )
        let window = mount(controller)
        defer { unmount(window) }
        let oldItem = try #require(probe.items.first)

        theme.isDark = true
        ComponentTestHost.drainRunLoop(for: 0.3)
        let newItem = try #require(probe.items.last)
        #expect(probe.items.count == 2)

        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: oldItem)
        ComponentTestHost.drainRunLoop(for: 0.05)
        #expect(probe.restartCount == 0)

        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: newItem)
        ComponentTestHost.drainRunLoop(for: 0.05)
        #expect(probe.restartCount == 1)
    }

    // Mode A (spy): SwiftUI show/hide state; the spy records the pause and the rebuilt player.
    @Test("removing and re-adding the video releases the player and builds a fresh one")
    func visibilityLifecycleRebuildsPlayer() {
        let probe = VideoRuntimeProbe()
        let visibility = VideoVisibilityDriver()
        let controller = ComponentTestHost.makeComponentHost(
            rootView: VideoVisibilityHarness(
                video: videoWidget(autoplay: true), visibility: visibility, runtime: probe.runtime),
            size: CGSize(width: 320, height: 180),
            backgroundColor: .black
        )
        let window = mount(controller)
        defer { unmount(window) }
        #expect(probe.players.count == 1)
        #expect(probe.playCount == 1)
        #expect(probe.pauseCount == 0)

        visibility.isShown = false
        ComponentTestHost.drainRunLoop(for: 0.2)
        #expect(probe.pauseCount == 1)
        #expect(findPlayerController(in: window.rootViewController) == nil)

        visibility.isShown = true
        ComponentTestHost.drainRunLoop(for: 0.2)
        #expect(probe.players.count == 2)
        #expect(probe.playCount == 2)
    }

    // MARK: - Real AVFoundation (slow): the live runtime with a real local file

    // Mode B (live + real file): real AVPlayerItem reaches .readyToPlay at 64x64 and the controller is ready for display.
    @Test("the renderer feeds the live runtime a real item that decodes", .tags(.slow))
    func liveRuntimeDecodesRealLocalFile() async throws {
        let videoURL = try makeLocalVideo()
        defer { try? FileManager.default.removeItem(at: videoURL) }
        let recorder = LiveVideoRecorder()
        let window = mount(
            video: videoWidget(url: videoURL.absoluteString, muted: true),
            runtime: recorder.runtime
        )
        defer { unmount(window) }

        let player = try #require(recorder.players.first)
        let item = try #require(player.currentItem)
        #expect((item.asset as? AVURLAsset)?.url == videoURL)
        #expect(player.isMuted)
        #expect(await waitAsync { item.status != .unknown })
        #expect(item.status == .readyToPlay)
        #expect(item.presentationSize == CGSize(width: 64, height: 64))

        let controller = try #require(findPlayerController(in: window.rootViewController))
        #expect(await waitAsync { controller.isReadyForDisplay })
        #expect(recorder.players.count == 1)
    }

    // Mode B (live + real file): pixels of the frame the renderer's real player decodes at a fixed time.
    // A screenshot of the player view is black, so the frame is read from an AVPlayerItemVideoOutput that
    // the test attaches to the item the production renderer built.
    @Test(
        "the renderer's player decodes the expected frame of the light and dark sources",
        .tags(.slow, .golden))
    func decodedFrameMatchesGolden() async throws {
        let frameTime = CMTime(seconds: 3, preferredTimescale: 600)
        let light = Self.vendoredVideo("big-buck-bunny.mp4")
        let dark = Self.vendoredVideo("movie.mp4")

        for isDark in [false, true] {
            let recorder = LiveVideoRecorder()
            let window = mount(
                video: videoWidget(
                    url: light.absoluteString, darkURL: dark.absoluteString, muted: true),
                isDark: isDark,
                runtime: recorder.runtime
            )
            defer { unmount(window) }

            let player = try #require(recorder.players.first)
            let item = try #require(player.currentItem)
            let expected = isDark ? dark : light
            #expect((item.asset as? AVURLAsset)?.url == expected)

            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            item.add(output)
            try #require(await waitAsync { item.status == .readyToPlay }, "the item never became ready")
            try #require(await seek(player, to: frameTime), "the seek never completed")

            var frame: CVPixelBuffer?
            _ = await waitAsync {
                frame = output.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil)
                return frame != nil
            }
            let buffer = try #require(frame, "no frame was decoded for \(expected.lastPathComponent)")

            assertVisualGolden(
                matching: try Self.image(from: buffer),
                precision: 0.99,
                perceptualPrecision: 0.98,
                named: isDark ? "dark" : "light"
            )
        }
    }

    // Mode B (live + real file): the structure of the native AVKit controls with `showControls` on and off.
    // The controls are hidden until the user taps, and a tap cannot be injected without private API, so
    // this golden pins which control views are installed (class names and nesting), not their pixels.
    // Pixels of the visible controls belong to the device journey (Maestro).
    @Test("the native controls are installed only when the widget asks for them", .tags(.slow, .golden))
    func controlsStructureMatchesGolden() async throws {
        let video = Self.vendoredVideo("big-buck-bunny.mp4").absoluteString
        var lineCounts: [Bool: Int] = [:]

        for showControls in [true, false] {
            let recorder = LiveVideoRecorder()
            let window = mount(
                video: videoWidget(url: video, muted: true, showControls: showControls),
                runtime: recorder.runtime
            )
            defer { unmount(window) }

            let controller = try #require(findPlayerController(in: window.rootViewController))
            try #require(await waitAsync { controller.isReadyForDisplay }, "the first frame never became ready")
            #expect(controller.showsPlaybackControls == showControls)

            let structure = await settledControlStructure(of: controller.view)
            lineCounts[showControls] = structure.split(separator: "\n").count
            assertStructureGolden(structure, named: showControls ? "controlsOn" : "controlsOff")
        }

        #expect((lineCounts[true] ?? 0) > (lineCounts[false] ?? 0))
    }

    // Mode B (live + real file): a missing file reaches .failed with an error while the controller stays mounted.
    @Test("a source that cannot be opened fails quietly and keeps the player mounted", .tags(.slow))
    func unreadableSourceFailsQuietly() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).mp4")
        let recorder = LiveVideoRecorder()
        let window = mount(
            video: videoWidget(url: missing.absoluteString, autoplay: true),
            runtime: recorder.runtime
        )
        defer { unmount(window) }

        let item = try #require(recorder.players.first?.currentItem)
        #expect(await waitAsync { item.status != .unknown })
        #expect(item.status == .failed)
        #expect(item.error != nil)
        let controller = try #require(findPlayerController(in: window.rootViewController))
        #expect(!controller.isReadyForDisplay)
        #expect(recorder.players.count == 1)
    }

    // Mode C (adapter): CanvasVideoRuntime.live closures on a real AVPlayer; no view involved.
    @Test("the live adapters drive a real AVPlayer", .tags(.slow))
    func liveAdaptersDriveRealPlayer() async throws {
        let videoURL = try makeLocalVideo()
        defer { try? FileManager.default.removeItem(at: videoURL) }
        let live = CanvasVideoRuntime.live
        let item = AVPlayerItem(url: videoURL)
        let player = live.makePlayer(item)
        #expect(player.currentItem === item)
        try #require(await waitAsync { item.status == .readyToPlay }, "the item never became ready")

        live.play(player)
        #expect(player.rate > 0)
        live.pause(player)
        #expect(player.rate == 0)

        try #require(await seek(player, to: CMTime(seconds: 0.4, preferredTimescale: 600)))
        #expect(player.currentTime().seconds > 0.3)

        live.restart(player)
        #expect(player.rate > 0)
        #expect(await waitAsync { player.currentTime().seconds < 0.3 })
        live.pause(player)
    }

    // Mode C (adapter): the default environment value must be the live runtime; no view involved.
    @Test("production starts from the live runtime, never a fake one")
    func defaultRuntimeIsLive() {
        let item = AVPlayerItem(url: URL(string: "https://example.invalid/default.mp4")!)
        let player = EnvironmentValues().canvasVideoRuntime.makePlayer(item)

        #expect(player.currentItem === item)
    }

    private func parsedVideo(_ props: [String: Any]) throws -> CampaignCanvasWidget {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 320,
            "canvasHeight": 180,
            "children": [
                [
                    "kind": "widget",
                    "id": "video",
                    "rect": ["x": 0, "y": 0, "width": 1, "height": 1],
                    "widget": ["type": "digia/videoPlayer", "props": props],
                ]
            ],
        ])
        guard case .widget(_, _, let widget) = canvas.children.first else {
            throw VideoTestError.missingWidget
        }
        return widget
    }

    /// Class names and nesting of the AVKit views under the controller. Frames, alpha and hidden flags are
    /// left out on purpose: they change with layout and with the user's last tap.
    private func controlStructure(of view: UIView) -> String {
        var lines: [String] = []
        func walk(_ view: UIView, depth: Int) {
            let name = String(describing: type(of: view))
            let isAVKit = name.hasPrefix("AV") || name.hasPrefix("__AV")
            if isAVKit { lines.append(String(repeating: "  ", count: depth) + name) }
            view.subviews.forEach { walk($0, depth: isAVKit ? depth + 1 : depth) }
        }
        walk(view, depth: 0)
        return lines.joined(separator: "\n")
    }

    /// The control views are built lazily after the first frame; wait until the structure stops changing.
    private func settledControlStructure(of view: UIView) async -> String {
        var previous = controlStructure(of: view)
        var stableReads = 0
        let deadline = Date().addingTimeInterval(5)
        while stableReads < 3, Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
            let current = controlStructure(of: view)
            stableReads = current == previous ? stableReads + 1 : 0
            previous = current
        }
        return previous
    }

    private func assertStructureGolden(
        _ structure: String,
        named name: String,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        function: StaticString = #function,
        line: UInt = #line
    ) {
        let failure = verifySnapshot(
            of: structure,
            as: .lines,
            named: name,
            record: isSnapshotRecordingEnabled ? .all : nil,
            fileID: fileID,
            file: filePath,
            testName: String(describing: function).components(separatedBy: "(").first ?? "",
            line: line
        )
        if let failure { Issue.record("\(failure)") }
    }

    private static func vendoredVideo(_ name: String) -> URL {
        FixtureLoader.workspaceURL()!
            .appendingPathComponent("testkit/mock-server/assets")
            .appendingPathComponent(name)
    }

    /// Converts a decoded pixel buffer to an image at 1x with the software renderer, so the pixels
    /// do not depend on the GPU.
    private static func image(from buffer: CVPixelBuffer) throws -> UIImage {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            throw VideoTestError.writerFailed
        }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    private func videoWidget(
        url: String = "https://example.invalid/video.mp4",
        darkURL: String? = nil,
        autoplay: Bool = false,
        loop: Bool = false,
        muted: Bool = false,
        showControls: Bool = true,
        fit: String = "cover"
    ) -> CampaignCanvasWidget {
        .video(
            box: .none,
            source: CampaignCanvasMediaSource(url: url, darkUrl: darkURL, placeholder: nil),
            autoplay: autoplay,
            loop: loop,
            muted: muted,
            showControls: showControls,
            fit: fit
        )
    }

    private func canvas(containing video: CampaignCanvasWidget) -> CampaignCanvas {
        CampaignCanvas(
            version: 2,
            width: 320,
            height: 180,
            background: .solid(.literal("#FF000000")),
            children: [canvasChild(video: video)]
        )
    }

    private func canvasChild(video: CampaignCanvasWidget) -> CampaignCanvasChild {
        .widget(
            id: "video",
            rect: CampaignCanvasRect(x: 0, y: 0, width: 320, height: 180),
            widget: video
        )
    }

    private func mount(
        video: CampaignCanvasWidget,
        isDark: Bool = false,
        usesStoryPlayback: Bool = false,
        variables: VariableContext? = nil,
        runtime: CanvasVideoRuntime
    ) -> UIWindow {
        let canvas = CampaignCanvas(
            version: 2,
            width: 320,
            height: 180,
            background: .solid(.literal("#FF000000")),
            children: [canvasChild(video: video)]
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
                .environment(\.canvasVideoRuntime, runtime)
                .environment(\.canvasVideoUsesStoryPlayback, usesStoryPlayback)
                .environment(\.digiaVariables, variables)
        )
        return mount(
            ComponentTestHost.makeComponentHost(
                rootView: root,
                size: CGSize(width: 320, height: 180),
                backgroundColor: .black
            )
        )
    }

    private func mount<Content: View>(_ controller: UIHostingController<Content>) -> UIWindow {
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first
        {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: controller.view.bounds)
        }
        window.frame = controller.view.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        ComponentTestHost.drainRunLoop(for: 0.1)
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
        ComponentTestHost.drainRunLoop(for: 0.1)
    }

    private func findPlayerController(in controller: UIViewController?) -> AVPlayerViewController? {
        guard let controller else { return nil }
        if let playerController = controller as? AVPlayerViewController { return playerController }
        if let presented = findPlayerController(in: controller.presentedViewController) {
            return presented
        }
        for child in controller.children {
            if let found = findPlayerController(in: child) { return found }
        }
        return nil
    }

    /// Seeks exactly and reports whether the seek completed within the timeout. An item that failed to
    /// load never completes a seek, so the async `seek(to:)` would wait forever; a test must fail instead.
    private func seek(
        _ player: AVPlayer, to time: CMTime, timeout: TimeInterval = 15
    ) async -> Bool {
        let completed = ThreadSafeFlag()
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in completed.set() }
        return await waitAsync(timeout: timeout) { completed.value }
    }

    /// Waits by suspending. AVFoundation delivers item status changes only when the test yields;
    /// blocking run-loop spins never deliver them.
    private func waitAsync(
        timeout: TimeInterval = 15, condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            CATransaction.flush()
        }
        return condition()
    }

    private func makeLocalVideo() throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("canvas-video-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 64,
                AVVideoHeightKey: 64,
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64,
            ]
        )
        guard writer.canAdd(input) else { throw VideoTestError.cannotAddWriterInput }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? VideoTestError.writerFailed }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<2 {
            guard waitUntil(timeout: 2, condition: { input.isReadyForMoreMediaData }),
                let pool = adaptor.pixelBufferPool
            else { throw VideoTestError.writerFailed }
            var optionalBuffer: CVPixelBuffer?
            guard
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer) == kCVReturnSuccess,
                let buffer = optionalBuffer
            else { throw VideoTestError.writerFailed }
            fill(buffer: buffer, red: frame == 0 ? 255 : 0, blue: frame == 0 ? 0 : 255)
            guard
                adaptor.append(
                    buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 2))
            else { throw writer.error ?? VideoTestError.writerFailed }
        }

        input.markAsFinished()
        let finished = ThreadSafeFlag()
        writer.finishWriting { finished.set() }
        guard waitUntil(timeout: 5, condition: { finished.value }), writer.status == .completed
        else {
            throw writer.error ?? VideoTestError.writerFailed
        }
        return outputURL
    }

    private func fill(buffer: CVPixelBuffer, red: UInt8, blue: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<CVPixelBufferGetHeight(buffer) {
            let pixels = baseAddress.advanced(by: row * bytesPerRow).assumingMemoryBound(
                to: UInt8.self)
            for column in 0..<CVPixelBufferGetWidth(buffer) {
                let offset = column * 4
                pixels[offset] = blue
                pixels[offset + 1] = 0
                pixels[offset + 2] = red
                pixels[offset + 3] = 255
            }
        }
    }
}

@MainActor
private final class VideoThemeDriver: ObservableObject {
    @Published var isDark = false
}

private struct VideoThemeHarness: View {
    let video: CampaignCanvasWidget
    @ObservedObject var theme: VideoThemeDriver
    let runtime: CanvasVideoRuntime

    var body: some View {
        var stage = CampaignCanvasStage(
            canvas: CampaignCanvas(
                version: 2,
                width: 320,
                height: 180,
                background: .solid(.literal("#FF000000")),
                children: [
                    .widget(
                        id: "video",
                        rect: CampaignCanvasRect(x: 0, y: 0, width: 320, height: 180),
                        widget: video
                    )
                ]
            ),
            authoredCornerRadius: 0,
            isDark: theme.isDark,
            showBackground: true,
            onAction: { _ in }
        )
        stage.animateWidgetsOnAppear = false
        return stage.environment(\.canvasVideoRuntime, runtime)
    }
}

@MainActor
private final class VideoRuntimeProbe {
    private(set) var items: [AVPlayerItem] = []
    private(set) var players: [AVPlayer] = []
    private(set) var madeURLs: [URL] = []
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var restartCount = 0

    var runtime: CanvasVideoRuntime {
        CanvasVideoRuntime(
            makePlayer: { item in
                self.items.append(item)
                if let asset = item.asset as? AVURLAsset { self.madeURLs.append(asset.url) }
                let player = AVPlayer()
                self.players.append(player)
                return player
            },
            play: { _ in self.playCount += 1 },
            pause: { _ in self.pauseCount += 1 },
            restart: { _ in self.restartCount += 1 }
        )
    }
}

@MainActor
private final class VideoVisibilityDriver: ObservableObject {
    @Published var isShown = true
}

private struct VideoVisibilityHarness: View {
    let video: CampaignCanvasWidget
    @ObservedObject var visibility: VideoVisibilityDriver
    let runtime: CanvasVideoRuntime

    var body: some View {
        ZStack {
            if visibility.isShown {
                CampaignCanvasStage(
                    canvas: CampaignCanvas(
                        version: 2,
                        width: 320,
                        height: 180,
                        background: .solid(.literal("#FF000000")),
                        children: [
                            .widget(
                                id: "video",
                                rect: CampaignCanvasRect(x: 0, y: 0, width: 320, height: 180),
                                widget: video
                            )
                        ]
                    ),
                    authoredCornerRadius: 0,
                    isDark: false,
                    showBackground: true,
                    onAction: { _ in }
                )
                .environment(\.canvasVideoRuntime, runtime)
            }
        }
    }
}

/// Wraps the live runtime and records every player it builds, so a test can inspect the real
/// AVPlayer while the production adapters run unchanged.
@MainActor
private final class LiveVideoRecorder {
    private(set) var players: [AVPlayer] = []

    var runtime: CanvasVideoRuntime {
        let live = CanvasVideoRuntime.live
        return CanvasVideoRuntime(
            makePlayer: { item in
                let player = live.makePlayer(item)
                self.players.append(player)
                return player
            },
            play: live.play,
            pause: live.pause,
            restart: live.restart
        )
    }
}

private enum VideoTestError: Error {
    case missingWidget
    case cannotAddWriterInput
    case writerFailed
}

private final class ThreadSafeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set() {
        lock.lock()
        storage = true
        lock.unlock()
    }
}
