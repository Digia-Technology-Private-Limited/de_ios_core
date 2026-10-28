import AVFoundation
import Foundation
import Lottie
import SnapshotTesting
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

extension HostedUITests {
/// Pixel goldens for every Test Kit PiP fixture, collapsed and expanded.
///
/// The arguments are read from `sdk_testing_fixtures/campaigns/pip/`, so a fixture added to the Test
/// Kit is covered with no code change (record it by running this target's tests with
/// `TEST_RUNNER_RECORD_SNAPSHOTS=true`; see `SampleApp/README.md`). Each fixture is decoded by
/// `CampaignModel.fromJson`, started on the SDK's floater orchestrator, and drawn by the production
/// `FloaterOverlayView` — the layer `DigiaHost` mounts — over a host screen. Nothing on screen may
/// move with wall-clock time: auto-dismiss is held off, the video never plays and the Lottie is
/// pinned to one frame, so a slow machine captures the same pixels as a fast one. The second state
/// is reached by a real tap, so this suite runs hosted by the sample app.
@Suite("Test Kit PiP fixture goldens", .serialized, .tags(.pip))
struct PipFixtureGoldenTests {

    private static let fixtures = FixtureLoader.fixtureNames(campaignType: "pip")

    /// The Lottie is held at this point of its timeline: its first frame is not representative.
    private static let lottieProgress: AnimationProgressTime = 0.5

    @Test("matches the PiP fixture golden", .tags(.golden), arguments: fixtures)
    @MainActor
    func testPipFixtureGolden(fixture: String) async throws {
        let campaign = try #require(loadCampaign(fixture), "Fixture must decode to a campaign")
        let config = try #require(campaign.floaterConfig, "Fixture must decode to a PiP")
        let orchestrator = SDKInstance.shared.floaterOrchestrator!
        // A player that stays paused at zero on the local file: it reaches `readyToPlay` (which is
        // what reveals the window) without the network, and autoplay cannot move it.
        orchestrator.playerFactory = { url in NeverPlayingPlayer(url: URL(string: url)!) }
        let started = orchestrator.start(
            campaign,
            payload: CEPTriggerPayload(
                cepCampaignId: "test_pip", campaignKey: campaign.campaignKey, cepMetadata: [:]),
            screenName: nil
        )
        try #require(
            started,
            "Floater orchestrator refused the fixture: \(orchestrator.lastStartFailureReason ?? "unknown")"
        )

        // Pin the screen and its notch / home-indicator insets to the golden's device, so the
        // goldens do not depend on which simulator the host app runs on.
        let device = ViewImageConfig.engageGolden
        let insets = device.safeArea
        activeFloaterWindowGeometryOverride = (
            CGRect(origin: .zero, size: device.size!),
            EdgeInsets(
                top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right
            )
        )
        defer {
            activeFloaterWindowGeometryOverride = nil
            orchestrator.playerFactory = nil
        }

        // The window draws nothing until its media has loaded (a file read, a Lottie decode, the
        // player's `readyToPlay`); wait for that rather than for a fixed time.
        try await awaitMediaReady(orchestrator)
        let window = makePipWindow(device: device)
        defer {
            // SDKInstance is process-wide; end the showing so the next fixture can start.
            orchestrator.dismiss(.hostTeardown)
            ComponentTestHost.cleanupOverlayWindow(window)
        }
        switch config.media.kind {
        // The window draws the image the orchestrator decoded before revealing it.
        case .image: try #require(orchestrator.preloadedImage != nil, "Media image was not preloaded")
        case .lottie: try await awaitLottieLoaded(in: window)
        default: break
        }

        // A campaign that opens expanded is captured that way first, then collapsed by a tap on
        // its collapse button; every other one the other way round, expanded by a tap on the
        // window. Real touches: a tap the shield refuses or a recognizer swallows fails here.
        let startsExpanded = config.behavior.startExpanded
        try await assertState(
            startsExpanded ? "expanded" : "collapsed", fixture: fixture, window: window)
        if startsExpanded {
            let collapse = try #require(
                collapseButtonCenter(in: window, config: config),
                "No collapse button in the expanded chrome"
            )
            try TouchSynthesizer.tap(at: collapse, in: window)
            #expect(orchestrator.surface == .collapsed, "Tapping the collapse button did not collapse the PiP")
        } else if !config.behavior.tapExpands {
            // Authored `onTap: none`: a tap must leave the window as it is, so its `expanded` golden
            // is the collapsed window it stays as.
            try FloaterTap.tapWindow(in: window)
            #expect(orchestrator.surface == .collapsed, "Tapping a PiP authored onTap: none expanded it")
        } else {
            try FloaterTap.tapWindow(in: window)
            #expect(orchestrator.surface == .expanded, "Tapping the PiP did not expand it")
        }
        try await awaitTransition(config)
        try await assertState(
            startsExpanded ? "collapsed" : "expanded", fixture: fixture, window: window)
    }

    @MainActor
    private func assertState(
        _ state: String, fixture: String, window: UIWindow
    ) async throws {
        // The Lottie plays on wall-clock time, and every SwiftUI update re-applies its authored
        // `.playing` mode, so it is pinned after each transition, right before the capture.
        holdLottie(in: window)
        // Exact within the perceptual tolerance, as the nudge and floater fixture goldens.
        assertVisualGolden(
            matching: ComponentTestHost.settledImage(of: window),
            precision: 1.0,
            perceptualPrecision: 0.98,
            named: "\(fixture)-\(state)",
            function: "testPipFixtureGolden"
        )
    }

    /// Where the expanded chrome's collapse button is on screen, or nil when it is hidden. The
    /// chrome's glyph buttons carry no accessibility label, so it is found by position: one row,
    /// close then the trailing pill (collapse first) when `closeOnLeft`, else the pill then close.
    /// Accessibility only locates it; the tap itself is a real touch.
    @MainActor
    private func collapseButtonCenter(in window: UIWindow, config: FloaterConfig) -> CGPoint? {
        guard config.controls.showCollapse else { return nil }
        ComponentTestHost.enableAccessibilityAutomation()
        var frames: [CGRect] = []
        collectButtonFrames(in: window, into: &frames)
        let row = frames.filter { !$0.isEmpty }.sorted { $0.minX < $1.minX }
        let index = config.expanded.closeOnLeft && config.expanded.showCloseButton ? 1 : 0
        guard row.indices.contains(index) else { return nil }
        return CGPoint(x: row[index].midX, y: row[index].midY)
    }

    @MainActor
    private func collectButtonFrames(in element: NSObject, into frames: inout [CGRect]) {
        if element.accessibilityTraits.contains(.button) {
            frames.append(element.accessibilityFrame)
        }
        if let view = element as? UIView {
            view.subviews.forEach { collectButtonFrames(in: $0, into: &frames) }
        }
        (element.accessibilityElements as? [NSObject])?.forEach {
            collectButtonFrames(in: $0, into: &frames)
        }
    }

    /// Polls until the orchestrator reveals the window, up to its own 10s media timeout. Awaiting
    /// (not spinning the run loop) lets the load's main-actor completion run.
    @MainActor
    private func awaitMediaReady(_ orchestrator: FloaterOrchestrator) async throws {
        for _ in 0..<500 where orchestrator.awaitingMedia {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try #require(
            orchestrator.state != nil,
            "Media was abandoned: \(orchestrator.lastStartFailureReason ?? "unknown")")
        try #require(
            !orchestrator.awaitingMedia, "Media did not load within the orchestrator's timeout")
    }

    /// The window's `LottieView` decodes the file again on its own, after the orchestrator's
    /// preload; polls until it has an animation installed, up to 5s.
    @MainActor
    private func awaitLottieLoaded(in window: UIWindow) async throws {
        for _ in 0..<250 where !hasLoadedLottie(window) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try #require(hasLoadedLottie(window), "Media Lottie did not load")
    }

    @MainActor
    private func hasLoadedLottie(_ view: UIView) -> Bool {
        if let lottie = view as? LottieAnimationView, lottie.animation != nil { return true }
        return view.subviews.contains { hasLoadedLottie($0) }
    }

    /// The grow/shrink runs `transitionMs`, and the expanded canvas is revealed by a main-queue
    /// callback at that same deadline; the view exposes neither, so wait out the authored duration.
    /// A longer wait captures the same frame: nothing on screen moves once the transition is over.
    @MainActor
    private func awaitTransition(_ config: FloaterConfig) async throws {
        try await Task.sleep(nanoseconds: UInt64(config.expanded.transitionMs + 100) * 1_000_000)
    }

    /// Pauses every Lottie in the window at `lottieProgress`.
    @MainActor
    private func holdLottie(in view: UIView) {
        if let lottie = view as? LottieAnimationView {
            lottie.setPlaybackMode(.paused(at: .progress(Self.lottieProgress)))
        }
        view.subviews.forEach { holdLottie(in: $0) }
    }

    /// With the auto-dismiss held off for a day, a collapsed window outlives a slow capture: at the
    /// authored length it would vanish at a different point in every run.
    private func loadCampaign(_ fixture: String) -> CampaignModel? {
        guard var json = FixtureLoader.loadFixture(campaignType: "pip", fileName: fixture) else {
            return nil
        }
        if var template = json["templateConfig"] as? [String: Any],
            var behavior = template["behavior"] as? [String: Any],
            behavior["autoDismissAfterMs"] is Int
        {
            behavior["autoDismissAfterMs"] = 86_400_000
            template["behavior"] = behavior
            json["templateConfig"] = template
        }
        return try? CampaignModel.fromJson(json, designTokens: fixtureTokens(json))
    }

    /// A key window with the floater layer over a plain host, as `DigiaHost` stacks them.
    @MainActor
    private func makePipWindow(device: ViewImageConfig) -> UIWindow {
        let size = device.size!
        let window =
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            .map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(origin: .zero, size: size))
        window.frame = CGRect(origin: .zero, size: size)

        let rootVC = ComponentTestHost.makeDeviceHost(
            device: device,
            style: .striped,
            scrimColor: nil,
            showHomeIndicator: false
        )
        let overlayVC = UIHostingController(rootView: FloaterOverlayView())
        overlayVC.view.frame = CGRect(origin: .zero, size: size)
        overlayVC.view.backgroundColor = .clear
        rootVC.addChild(overlayVC)
        rootVC.view.addSubview(overlayVC.view)
        overlayVC.didMove(toParent: rootVC)

        window.rootViewController = rootVC
        window.makeKeyAndVisible()

        ComponentTestHost.drainRunLoop(for: 0.2)
        return window
    }
}
}

/// An `AVPlayer` that never starts: autoplay calls `play()` on `readyToPlay`, and a playing video
/// would put its progress and its play/pause glyph at a different point in every run.
private final class NeverPlayingPlayer: AVPlayer {
    override func play() {}
}
