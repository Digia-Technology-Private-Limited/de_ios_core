import Foundation
import SDWebImage
import SnapshotTesting
import SwiftUI
import UIKit
@testable import DigiaEngage

/// What a command does. [args] are already checked and typed by the contract.
/// Fail with [YamlTestFailure] (expected/actual).
/// Mirrors `World`/`YamlHandler` in `world.dart`.
typealias YamlHandler = @MainActor (YamlWorld, [String: Any]) async throws -> Void

/// Everything one YAML test shares between its steps. Created fresh per file,
/// holding the test-only fakes the driver owns: the network, the CEP plugin
/// and the diagnostic sink. The UI is real: the SDK host mounted in a window.
@MainActor
final class YamlWorld {
    init(yamlDir: URL) {
        self.yamlDir = yamlDir
        let box = YamlCampaignBox()
        self.campaignBox = box
        cep = YamlRecordingCep()
        logSink = YamlLogSink()
        platform = RecordingPlatform()
        network = YamlNetworkFake(bundle: { [box] in box.value })
    }

    /// Folder of the YAML file; fixture paths resolve against it.
    let yamlDir: URL

    /// The step being run, for handlers that report its position.
    var step: YamlStep!

    /// What `mockApi: getCampaigns` set; what the SDK is served on launch.
    /// Backed by a lock-protected box: the network fake reads it off the
    /// main actor, and the fake is built before `self` exists.
    var campaigns: [[String: Any]] {
        get { campaignBox.value }
        set { campaignBox.value = newValue }
    }
    private let campaignBox: YamlCampaignBox

    let network: YamlNetworkFake
    let cep: YamlRecordingCep
    let logSink: YamlLogSink
    let platform: RecordingPlatform

    /// Every story-video player the running test has seen (YamlStoryVideos).
    let storyVideos = YamlStoryVideos()

    /// Every canvas-video player the running test has seen (YamlCanvasVideos).
    let canvasVideos = YamlCanvasVideos()

    var window: UIWindow?

    /// A pushCover screen presented over the app, if one is up.
    var coverPresented: UIViewController?
    var onPhone = false
    var onTablet = false

    /// The first launch's host, kept across stopApp/relaunch rounds in one
    /// test: the contract ignores `host` on a relaunch.
    var phoneHost = false
    var tabletHost = false
    var bootedOnce = false

    /// The test file's stem (`g01_overlay_golden` for
    /// `tests/golden/g01_overlay_golden.yaml`): per-stack goldens are stored
    /// under it. Set by the runner from the test path.
    var testStem = "adhoc"

    /// The status message the last `capturePage` recorded (what the debug UI
    /// shows), or null when no capture has run yet in this test.
    var captureStatus: String?

    /// A hung upload is still in flight: `assertCaptureStatus` awaits it.
    var captureAwaiting = false

    /// Whether `launchApp` has booted the SDK since the last `stopApp`.
    var launched = false

    /// The network log size at the `clearState` launch; `mockApi` rules set
    /// before `launchApp` survive across launches within one test.
    var apiBaseline = 0

    /// The network log size after each boot settled; analytics events the
    /// disk queue held over from an earlier test are flushed before it.
    var eventBaseline = 0

    private var sinkAttached = false
    private static var diskCacheCleared = false

    /// The fake clock `advanceTime` moves. Installed on the auto-dismiss
    /// timer at every boot, removed at teardown.
    let clock = YamlFakeClock()

    /// The fake wall and wait clocks `advanceTime`/`setTime` move; the SDK
    /// reads them through its `clock` and `waitClock` seams from every boot.
    let time = YamlTime()

    /// SDK calls made before `launchApp` (or after `stopApp`): run by the
    /// next launch after the reset and before `initialize`, as a host app
    /// that calls the SDK before initializing it.
    var preLaunch: [@MainActor () async -> Void] = []

    /// A debug link opened before the SDK ran; the next launch routes it,
    /// as a host delivering its launch URL once the shell is up.
    var pendingDebugLink: String?

    /// `seedStorage` values by logical key, written at the next launch.
    var seeds: [String: Any] = [:]

    /// The slots and anchors the test mounted on the plain host screen.
    let mounts = YamlHostMounts()

    /// Host navigation stack for pushScreen/popScreen (isDialog = unnamed modal).
    var navStack: [YamlNavEntry] = []

    /// The app is in the background (`launchApp background` or `background`).
    var inBackground = false

    /// When the current install (the last `clearState` launch) began, on the
    /// real clock analytics stamps `occurred_at` with. The SQLite queues
    /// outlive a reset, so an event an earlier test queued late can upload
    /// on this boot; it is older than this and is not this test's.
    var installedAt = Date.distantPast

    /// Whether [event] (an analytics or app event) was recorded by this install.
    func isFromThisInstall(_ event: [String: Any]) -> Bool {
        guard let text = event["occurred_at"] as? String else { return true }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let at = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text) else {
            return true
        }
        return at >= installedAt
    }

    /// Where the last `assertDecision` stopped reading the records.
    var decisionMark = 0

    /// Every customKV payload the host handler received since the first
    /// launchApp of the test, in order. Recorded by the handler `bootForTest`
    /// installs; clipboard, share and review come from `platform`.
    var customKVReceived: [[String: Any]] = []

    // MARK: - Boot, relaunch, teardown

    /// Boots the real SDK serving [campaigns] through the fake network, with
    /// the recording CEP attached, and mounts the real host. A second launch
    /// without `clearState` is a relaunch over the same storage.
    func bootForTest(
        clearState: Bool, mountPhone: Bool, mountTablet: Bool = false, mountHost: Bool = true, background: Bool = false,
        waitForReady: Bool = true, device: [String: Any]? = nil, withCep: Bool = true, wrapper: String? = nil
    ) async throws {
        let sdk = SDKInstance.shared
        // A relaunch keeps the first launch's host: the contract ignores `host`
        // on a relaunch, so golden files stay on the phone frame across their
        // stopApp/relaunch rounds.
        if !bootedOnce { phoneHost = mountPhone; tabletHost = mountTablet; bootedOnce = true }
        if let old = window {
            // A relaunch is a new process: the old screen goes with it.
            old.isHidden = true
            window = nil
        }
        sdk.resetForTesting()
        // PiP parity with the Flutter/Android fakes: a black 12 s video frozen
        // 4 s in (playing), so the chrome progress matches every stack.
        // Survives resetForTesting (which only disposes); cleared in tearDown
        // so other suites keep the real player.
        sdk.floaterOrchestrator.playerFactory = { YamlFakePipPlayer(url: $0) }
        // The reset clears the screen but not the logger's copy of it.
        DigiaLogger.currentScreenName = nil
        if !sinkAttached {
            // Before anything boots, so start-up records are kept too.
            sinkAttached = true
            DigiaLogger.registerSink(logSink)
        }
        let clock = self.clock
        let time = self.time
        DigiaOverlayController.autoDismissSleepForTesting = { try await clock.sleep(nanoseconds: $0) }
        FloaterOrchestrator.autoDismissSleepForTesting = { try await clock.sleep(nanoseconds: $0) }
        FloaterStoryOrchestrator.autoDismissSleepForTesting = { try await clock.sleep(nanoseconds: $0) }
        CanvasStoryViewer.tickSleepForTesting = { try await clock.sleep(nanoseconds: $0) }
        CanvasStoryViewer.uptimeForTesting = { clock.nowSeconds }
        CanvasStoryViewer.disableCoverAnimationForTesting = true
        RecordingBadgeView.disablePulseForTesting = true
        // The acceptance and anchor watchdogs wait on the same fake clock, so
        // advanceTime fires them like any other timer.
        PresentationCoordinator.acceptanceSleepForTesting = { try await clock.sleep(nanoseconds: $0) }
        AnchorRegistry.readinessSleepForTesting = { try await clock.sleep(nanoseconds: $0) }
        DigiaBottomSheetConfig.disableAnimationForTesting = true
        FloaterOrchestrator.disableExitAnimationForTesting = true
        FloaterStoryOrchestrator.disableExitAnimationForTesting = true
        InlineCarouselRenderer.autoPlaySleepForTesting = { try await clock.sleep(nanoseconds: $0) }
        DigiaInlineStoryTiming.tickSleepForTesting = { try await clock.sleep(nanoseconds: $0) }
        DigiaInlineCanvasView.tickSleepForTesting = { try await clock.sleep(nanoseconds: $0) }
        TrustedTimeAnchor.monotonicNsecForTesting = { UInt64(max(0, time.monotonicMs)) * 1_000_000 }
        // Waits, cap windows, the session and the user context all count on
        // the test's clocks, from before the SDK starts.
        sdk.waitClock = { time.monotonicMs }
        sdk.clock = { time.wallMs }
        cep.clockMs = { time.wallMs }
        sdk.launchedInBackground = { background }
        sdk.deviceFactsForTesting = device.map(Self.deviceFacts)
        inBackground = background
        if clearState {
            network.clearLog()
            mounts.items = []
            mounts.belowFold = []
            mounts.transparent = false
            navStack = []
            // Fleet-health dedup is per app session, and the sink is a process
            // singleton: a fresh install starts with none seen.
            HealthSink.shared.resetForTest()
            let defaults = UserDefaults(suiteName: SdkHarness.storageSuite)
            // Key by key as well: `removePersistentDomain` alone can leave a
            // value the SDK's own instance of the suite still reads.
            for key in defaults?.persistentDomain(forName: SdkHarness.storageSuite)?.keys ?? [:].keys {
                defaults?.removeObject(forKey: key)
            }
            defaults?.removePersistentDomain(forName: SdkHarness.storageSuite)
            // Marks storage as already migrated, so no launch runs the
            // migrator (mirrors `SdkHarness.create`).
            defaults?.set(1, forKey: "storage.version")
            // The simulator's device-level `tech.digia.engage` domain (written
            // by the package tests, which run outside an app container) shows
            // through a wiped suite. Shadow the open count with 0, which the
            // counter reads exactly as "never opened".
            if defaults?.object(forKey: AppOpensCounter.storageKey) != nil {
                defaults?.set(0, forKey: AppOpensCounter.storageKey)
            }
            // Clear persisted SQLite analytics & app-event rows cleanly through
            // their open connections (never unlink the files while open).
            let analyticsQueue = SQLiteAnalyticsQueue(
                opener: AnalyticsDatabaseOpener(resolvePath: { try AnalyticsDatabaseOpener.defaultPath() }))
            await analyticsQueue.clear()
            await analyticsQueue.close()
            let appEventsQueue = SQLiteAnalyticsQueue(
                opener: AnalyticsDatabaseOpener(resolvePath: {
                    try AnalyticsDatabaseOpener.defaultPath(fileName: AnalyticsDatabaseOpener.appEventsFileName)
                }))
            await appEventsQueue.clear()
            await appEventsQueue.close()
        }
        if clearState {
            // `assertEvents` reads what this install sent, boot included.
            eventBaseline = network.logCount
            installedAt = Date().addingTimeInterval(-0.001)
            // The registry's dedupe set is process memory: a fresh install
            // has seen nothing. `initialize` reconfigures it below.
            SDKInstance.shared.componentRegistry.resetForTesting()
            // A fresh install has seen nothing: the timeline buffer is process
            // memory the SDK never clears between tests, so the driver does.
            ScreenSink.shared.clear()
            // A fresh install ships with capture off: state this explicitly
            // rather than trusting wiped storage alone.
            SDKInstance.shared.setCaptureModeEnabled(false)
            SDKInstance.shared.setCaptureProfile(
                includeText: false, includeMedia: false, includeStructure: false)
            // And with the bubble hidden: the overlay controller is a process
            // singleton whose in-memory flag survives the storage wipe.
            SDKInstance.shared.debugOverlayControllerSnapshot().setVisible(false)
        }
        applySeeds()
        ComponentTestHost.enableAccessibilityAutomation()
        GoldenFonts.install()
        // Thumbnail videos would otherwise play real frames during golden
        // captures; freeze them on their static placeholder instead, like
        // Android blanks story video TextureViews.
        InlineStoryRailPlaybackCoordinator.thumbnailPlaybackDisabledForTesting = true
        // Fixture CDN pictures load from the real internet without this;
        // serve the Test Kit strawberry instead, like the Android and Flutter
        // drivers do, so goldens (and image timing) never depend on it.
        YamlImageStubLoader.installIfNeeded()
        YamlTestkitURLProtocol.installIfNeeded()
        // Image caches outlive a boot (and predate the stub): without a clear a
        // run reuses real photos another run downloaded instead of the
        // strawberry the baselines show. Every boot starts uncached, like the
        // registry reset above; the stub re-serves synchronously from there.
        // clearDisk finishes on a queue: await it, or a load that queries the
        // disk mid-delete still hits the stale photo and never sees the stub.
        SDWebImageManager.shared.cancelAll()
        DigiaImagePipeline.imageManager.cancelAll()
        SDImageCache.shared.clearMemory()
        DigiaImagePipeline.imageCache.clearMemory()
        if !Self.diskCacheCleared || phoneHost || tabletHost {
            Self.diskCacheCleared = true
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                SDImageCache.shared.clearDisk(onCompletion: {
                    DigiaImagePipeline.imageCache.clearDisk(onCompletion: { continuation.resume() })
                })
            }
        }
        ActionPlatform.current = platform.actionPlatform
        guard let client = sdk.networkClient as? URLSessionNetworkClient else {
            throw YamlTestFailure("unexpected network client",
                                  expected: "URLSessionNetworkClient",
                                  line: step.line)
        }
        client.overrideForTesting = network
        network.assembleHeaders = { [weak client] in client?.assembleHeaders(for: $0) ?? $0 }
        // The survey's waits and now-reads count on the test's clocks too.
        SurveyClock.sleepForTesting = { try await clock.sleep(nanoseconds: $0) }
        SurveyClock.nowForTesting = { Date(timeIntervalSince1970: Double(time.wallMs) / 1000) }
        SurveyClock.backdropArmDelayNsForTesting = 0
        sdk.captureDelaySleepForTesting = { _ in await Task.yield() }
        let pending = preLaunch
        preLaunch = []
        for call in pending { await call() }
        let config = DigiaConfig(apiKey: "test-api-key", fontFamily: GoldenFonts.family, wrapperBinding: wrapper)
        if waitForReady {
            try await Digia.initialize(config)
            // A failed fetch still settles the state machine (ready with an
            // empty store, or failed): either way the launch goes on, like the
            // harness, and the steps assert what that means.
            try await waitUntil("the SDK to settle", timeout: 10) {
                sdk.sdkState != .initializing
            }
            if withCep { try await attachCep() }
        } else {
            let before = network.logSnapshot(from: 0).filter { $0.endpoint == "getCampaigns" }.count
            Task { @MainActor in try? await Digia.initialize(config) }
            // The customer's order: initialize(), then register() while it runs.
            if withCep { Digia.register(cep) }
            try await waitUntil("the campaign bundle request", timeout: 10) {
                self.network.logSnapshot(from: 0).filter { $0.endpoint == "getCampaigns" }.count > before
            }
        }
        // After initialize: it configures the runner with the config's (empty)
        // action handlers, so a recording installed earlier would be wiped. A
        // reset clears the runner's handlers, so every boot re-installs it.
        Digia.setCustomKVHandler { [weak self] payload in
            self?.customKVReceived.append(payload.mapValues { $0 as Any })
        }
        try mount(mountPhone: phoneHost, mountTablet: tabletHost, mountHost: mountHost)
        launched = true
        // A cold link waits for the shell: route it now that a presenter exists.
        if let link = pendingDebugLink, let url = URL(string: link),
           let root = window?.rootViewController
        {
            _ = Digia.handleDeepLink(url, from: root)
        }
        pendingDebugLink = nil
        await settle()
    }

    private func attachCep() async throws {
        Digia.register(cep)
        try await waitUntil("the plugin is attached", timeout: 5) {
            cep.host != nil
        }
        cep.flush()
    }

    /// `launchApp device` keys to the facts rules read.
    private static func deviceFacts(_ device: [String: Any]) -> [String: Any] {
        var facts: [String: Any] = [:]
        if let platform = device["platform"] { facts["platform"] = platform }
        if let os = device["osVersion"] { facts["os_version"] = os }
        if let app = device["appVersion"] { facts["app_version"] = app }
        if let locale = device["locale"] { facts["locale"] = locale }
        return facts
    }

    /// Writes `seedStorage` values where a previous run would have.
    private func applySeeds() {
        applySeedsKeepingQueued()
        seeds.removeAll()
    }

    /// Applies queued `seedStorage` values now without consuming them, for a
    /// pre-launch read that must see them while the launch still needs them.
    func applySeedsKeepingQueued() {
        guard !seeds.isEmpty else { return }
        let defaults = UserDefaults(suiteName: SdkHarness.storageSuite)
        for (key, value) in seeds {
            if key == "app_opens" {
                if let count = value as? Int {
                    defaults?.set(count, forKey: AppOpensCounter.storageKey)
                } else {
                    defaults?.set("\(value)", forKey: AppOpensCounter.storageKey)
                }
            } else if key == "device_id" {
                // A previous install's device ID, seeding a returning device.
                // Identity storage is scoped, so the key carries its domain.
                defaults?.set("\(value)", forKey: "identity.device_id")
            }
        }
    }

    private func mount(mountPhone: Bool, mountTablet: Bool = false, mountHost: Bool = true) throws {
        onPhone = mountPhone
        onTablet = mountTablet
        if mountPhone {
            let device = ViewImageConfig.engageGolden
            let size = device.size ?? CGSize(width: 390, height: 844)
            let window = ComponentTestHost.makeWindow(frame: CGRect(origin: .zero, size: size))
            // No device scrim: the campaign's own barrier dims the host, exactly
            // as the hand-written goldens mount it (`makeRealOverlayWindow`
            // passes `scrimColor: nil`).
            let rootVC = ComponentTestHost.makeDeviceHost(
                device: device, style: .striped, scrimColor: nil, showHomeIndicator: false)
            // Slot content for the golden frame: nothing when the test mounted
            // nothing (existing overlay goldens keep matching), the mounted
            // slots otherwise, so slot content can be golden-tested.
            let phoneMounts = self.mounts
            let host = UIHostingController(rootView: DigiaHost { YamlPhoneHome(mounts: phoneMounts, topInset: device.safeArea.top) }
                .environment(\.canvasVideoRuntime, canvasVideos.runtime)
                .environment(\.canvasLottieRuntime, CanvasLottieRuntime(playbackMode: .frozen(progress: 0.5)))
                .transaction { $0.animation = nil; $0.disablesAnimations = true })
            rootVC.addChild(host)
            host.view.frame = CGRect(origin: .zero, size: size)
            host.view.backgroundColor = .clear
            rootVC.view.addSubview(host.view)
            host.didMove(toParent: rootVC)
            window.rootViewController = rootVC
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            // The dialog and full-screen goldens lay out against the golden
            // device's screen and insets, exactly as the hand-written goldens
            // do: `NudgeGoldenTests` pins the screen via `makeWindow` and the
            // reference geometry here, with no `pinSafeArea` correction.
            // Floaters read the device box from the app's window, which on a
            // larger simulator is not this 390pt window: the window would land
            // partly off-screen and its chrome miss touches (f06/f10/f27/f28).
            // Pin the geometry the same way the harness does in
            // `deliverFloater`, for floater campaigns on either host.
            if servesDialogOrFullscreen || servesFloater {
                let insets = device.safeArea
                activeFloaterWindowGeometryOverride = (
                    CGRect(origin: .zero, size: size),
                    EdgeInsets(
                        top: insets.top, leading: insets.left,
                        bottom: insets.bottom, trailing: insets.right))
            }
            self.window = window
        } else if mountTablet {
            // The tablet host: a fixed 1024x768 landscape window with the same
            // striped device host as the phone (like Android's tablet host),
            // with the mounted slots inset 24 from the top. No device chrome:
            // the host is the striped screen, dimmed by the campaign's own
            // barrier exactly as the phone's is.
            let device = ViewImageConfig(
                safeArea: UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0),
                size: CGSize(width: 1024, height: 768),
                traits: UITraitCollection(userInterfaceIdiom: .pad))
            let size = CGSize(width: 1024, height: 768)
            let window = ComponentTestHost.makeWindow(frame: CGRect(origin: .zero, size: size))
            let rootVC = ComponentTestHost.makeDeviceHost(
                device: device, style: .striped, scrimColor: nil, showHomeIndicator: false)
            let host = UIHostingController(rootView: DigiaHost { YamlPhoneHome(mounts: self.mounts, topInset: 24) }
                .environment(\.canvasVideoRuntime, canvasVideos.runtime)
                .environment(\.canvasLottieRuntime, CanvasLottieRuntime(playbackMode: .frozen(progress: 0.5)))
                .transaction { $0.animation = nil; $0.disablesAnimations = true })
            rootVC.addChild(host)
            host.view.frame = CGRect(origin: .zero, size: size)
            host.view.backgroundColor = .clear
            rootVC.view.addSubview(host.view)
            host.didMove(toParent: rootVC)
            window.rootViewController = rootVC
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            if servesDialogOrFullscreen || servesFloater {
                activeFloaterWindowGeometryOverride = (
                    CGRect(origin: .zero, size: size),
                    EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0))
            }
            self.window = window
        } else {
            let window = ComponentTestHost.makeWindow(
                frame: CGRect(origin: .zero, size: SdkHarness.screen))
            let mounts = self.mounts
            // host: none boots the SDK with no DigiaHost at all: accepted
            // deliveries pend for a surface that never comes.
            let host: UIViewController
            if mountHost {
                host = UIHostingController(rootView: DigiaHost { YamlHostHome(mounts: mounts) }
                    .environment(\.canvasVideoRuntime, canvasVideos.runtime)
                .environment(\.canvasLottieRuntime, CanvasLottieRuntime(playbackMode: .frozen(progress: 0.5)))
                    .transaction { $0.animation = nil; $0.disablesAnimations = true })
            } else {
                host = UIHostingController(rootView: YamlHostHome(mounts: mounts)
                    .environment(\.canvasVideoRuntime, canvasVideos.runtime)
                .environment(\.canvasLottieRuntime, CanvasLottieRuntime(playbackMode: .frozen(progress: 0.5)))
                    .transaction { $0.animation = nil; $0.disablesAnimations = true })
            }
            window.rootViewController = host
            window.makeKeyAndVisible()
            // Floaters read the device box from the app's window; pin it to
            // this window, as `deliverFloater` does for the harness, or the
            // window lands partly off-screen on a larger simulator.
            if servesFloater {
                let insets = ViewImageConfig.engageGolden.safeArea
                activeFloaterWindowGeometryOverride = (
                    window.bounds,
                    EdgeInsets(
                        top: insets.top, leading: insets.left,
                        bottom: insets.bottom, trailing: insets.right))
            }
            self.window = window
        }
        UIView.setAnimationsEnabled(false)
        if !onPhone && !onTablet {
            window?.layer.speed = 100
        }
        window?.layoutIfNeeded()
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        CATransaction.flush()
    }

    /// Whether a served campaign lays out against the golden device's screen:
    /// a dialog or full-screen surface.
    private var servesDialogOrFullscreen: Bool {
        campaigns.contains { campaign in
            let container = (campaign["templateConfig"] as? [String: Any])?["container"]
                as? [String: Any]
            let display = (container?["displayType"] as? String)?.lowercased() ?? ""
            return display == "dialog" || display == "fullscreen"
                || display == "full_screen" || display == "full-screen"
        }
    }

    /// Whether a served campaign is a floater (PiP or story window): floaters
    /// read the device box from the app's window, so the driver pins it (see
    /// `mount`) instead of trusting whatever simulator is running.
    private var servesFloater: Bool {
        campaigns.contains { campaign in
            let template = (campaign["templateConfig"] as? [String: Any])?["templateType"]
                as? String
            return template == "pip" || template == "floaterStory"
        }
    }

    /// Process death: what is on screen and all in-memory SDK state go; the
    /// fake persistent storage stays. The next `launchApp` without
    /// `clearState` is a relaunch over it.
    func stop() {
        if let window {
            window.endEditing(true)
            window.rootViewController?.dismiss(animated: false)
            window.rootViewController = nil
            window.isHidden = true
            window.resignKey()
        }
        window = nil
        onPhone = false
        onTablet = false
        activeFloaterWindowGeometryOverride = nil
        SDKInstance.shared.resetForTesting()
        launched = false
    }

    func tearDown() {
        UIView.setAnimationsEnabled(true)
        stop()
        InlineStoryRailPlaybackCoordinator.thumbnailPlaybackDisabledForTesting = false
        Digia.setCustomKVHandler(nil)
        if inBackground {
            // The next test starts in the foreground.
            inBackground = false
            NotificationCenter.default.post(
                name: UIApplication.willEnterForegroundNotification, object: nil)
        }
        let sdk = SDKInstance.shared
        sdk.waitClock = MonotonicClock.nowMs
        sdk.clock = SessionManager.systemClock
        sdk.launchedInBackground = { UIApplication.shared.applicationState == .background }
        sdk.deviceFactsForTesting = nil
        sdk.captureDelaySleepForTesting = nil
        // The YAML PiP fake must not leak into the harness suites sharing
        // this process (their tests set their own factory per test).
        sdk.floaterOrchestrator.playerFactory = nil
        DigiaOverlayController.autoDismissSleepForTesting = nil
        FloaterOrchestrator.autoDismissSleepForTesting = nil
        FloaterStoryOrchestrator.autoDismissSleepForTesting = nil
        CanvasStoryViewer.tickSleepForTesting = nil
        CanvasStoryViewer.uptimeForTesting = nil
        CanvasStoryViewer.disableCoverAnimationForTesting = false
        RecordingBadgeView.disablePulseForTesting = false
        PresentationCoordinator.acceptanceSleepForTesting = nil
        AnchorRegistry.readinessSleepForTesting = nil
        DigiaBottomSheetConfig.disableAnimationForTesting = false
        FloaterOrchestrator.disableExitAnimationForTesting = false
        FloaterStoryOrchestrator.disableExitAnimationForTesting = false
        InlineCarouselRenderer.autoPlaySleepForTesting = nil
        DigiaInlineStoryTiming.tickSleepForTesting = nil
        DigiaInlineCanvasView.tickSleepForTesting = nil
        TrustedTimeAnchor.monotonicNsecForTesting = nil
        SurveyClock.sleepForTesting = nil
        SurveyClock.nowForTesting = nil
        SurveyClock.backdropArmDelayNsForTesting = nil
        clock.cancelAll()
        network.releaseAll()
        if sinkAttached {
            sinkAttached = false
            DigiaLogger.unregisterSink(logSink)
        }
    }

    // MARK: - Reading the test

    /// A `json` argument: a path ending `.json` is read from [yamlDir];
    /// anything else is already inline JSON.
    func json(_ value: Any?) throws -> Any? {
        guard let path = value as? String, path.hasSuffix(".json") else {
            return value
        }
        let url = yamlDir.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url),
              var text = String(data: data, encoding: .utf8)
        else {
            throw YamlTestFailure(
                "fixture not found",
                expected: "a file at \(url.path)",
                line: step.line)
        }
        if let workspace = FixtureLoader.workspaceURL() {
            text = FixtureLoader.resolveAssetOrigin(in: text, workspaceUrl: workspace)
        }
        guard let parsed = try? JSONSerialization.jsonObject(
            with: Data(text.utf8), options: [.fragmentsAllowed])
        else {
            throw YamlTestFailure(
                "fixture is not JSON",
                expected: "JSON in \(url.path)",
                line: step.line)
        }
        return parsed
    }

    private var hasPendingAsync: Bool {
        if network.inFlightCount > 0 { return true }
        if SDWebImageManager.shared.isRunning { return true }
        if DigiaImagePipeline.imageManager.isRunning { return true }
        if CarouselStripMotion.pendingRestChecks > 0 { return true }
        if let services = SDKInstance.shared.services {
            if services.analyticsService?.isDispatching == true { return true }
            if services.appEventsService?.isDispatching == true { return true }
            if services.sessionReporter.isBusy && !network.isHolding("session") { return true }
        }
        return false
    }

    /// Lets main-actor work scheduled so far (a delivery's routing, analytics
    /// flushes, unheld fake-network requests, image loads) finish, returning
    /// after two quiet passes instead of sleeping a fixed wall-clock window.
    /// Before `launchApp` there is nothing to wait for.
    func settle() async {
        guard launched else { return }
        cep.flush()
        let deadline = Date().addingTimeInterval(30)
        var quietPasses = 0
        while quietPasses < 2 {
            if Date() > deadline { break }
            window?.layoutIfNeeded()
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
            CATransaction.flush()
            await Task.yield()
            if hasPendingAsync {
                quietPasses = 0
                try? await Task.sleep(nanoseconds: 5_000_000)
            } else {
                quietPasses += 1
            }
        }
        // The fake PiP player renders no frames (its layer stays transparent
        // over the window's navy backdrop): paint it opaque black, the colour
        // the Flutter/Android fakes draw, so goldens match every stack.
        if let player = SDKInstance.shared.floaterOrchestrator.player as? YamlFakePipPlayer,
           let window
        {
            blackenYamlPipSurface(in: window, player: player)
        }
    }

    func finish() async {
        guard launched else { return }
        // Flush both analytics queues and wait until in-flight dispatches settle
        // (two rounds catch events enqueued while the first flush was in flight).
        for _ in 0..<2 {
            SDKInstance.shared.services?.flushAnalytics()
            await settle()
        }
    }

    func waitUntil(
        _ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Task.isCancelled { throw CancellationError() }
            if Date() > deadline {
                throw YamlTestFailure("timed out waiting for \(what)", line: step.line)
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Runs an SDK call that waits on the network until it returns, or until
    /// a request to [endpoint] is held by a `hang` (the call then finishes
    /// when `releaseApi` answers, and the test goes on). Mirrors `_async`.
    func untilDoneOrHeld(
        _ what: String, endpoint: String, _ call: @escaping @MainActor () async -> Void
    ) async throws {
        let before = network.logSnapshot(from: 0).filter { $0.endpoint == endpoint }.count
        var done = false
        Task { @MainActor in
            await call()
            done = true
        }
        try await waitUntil("\(what) to finish", timeout: 10) {
            done || (self.network.isHolding(endpoint)
                && self.network.logSnapshot(from: 0).filter { $0.endpoint == endpoint }.count > before)
        }
    }

    /// The running SDK; fails the step if `launchApp` has not run yet.
    var sdk: SDKInstance {
        get throws {
            guard launched else {
                throw YamlTestFailure(
                    "the app is not running",
                    expected: "launchApp before this command",
                    line: step.line)
            }
            return SDKInstance.shared
        }
    }
}

// MARK: - The fake network

/// One request the fake network saw. Header names are lowercased.
struct YamlRequest {
    let endpoint: String
    let body: Any?
    let headers: [String: String]
}

/// The campaigns the fake bundle answers with, shared with the world across
/// isolation boundaries.
final class YamlCampaignBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: [[String: Any]] = []

    var value: [[String: Any]] {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Everything the network fake knows in one test: per-endpoint rules,
/// one-shot rules, the request log and held requests. Installed as the SDK's
/// real client's override, so the real client, image pipeline and retry
/// stack run; only answers are scripted. Test-only: no `Sources/` change.
final class YamlNetworkFake: NetworkClient, @unchecked Sendable {
    /// What `mockApi` set for one endpoint.
    struct Rule {
        /// `hang: true`: the request stays pending until `releaseApi`.
        var hang = false
        var status = 200
        var body: Any? = nil
        var networkError = false
    }

    /// Answers the campaign bundle with the world's current campaigns, like
    /// the harness default; everything else gets the accepted answer.
    init(bundle: @escaping () -> [[String: Any]]) {
        self.bundle = bundle
    }

    private let bundle: () -> [[String: Any]]
    private let lock = NSLock()
    private var rules: [String: Rule] = [:]
    private var once: [String: [Rule]] = [:]
    private var log: [YamlRequest] = []
    private var held: [String: [CheckedContinuation<NetworkResponse?, Never>]] = [:]
    private var _inFlightCount = 0

    /// Unheld requests currently inside `execute` / `executeMultipart`.
    var inFlightCount: Int { lock.withLock { _inFlightCount } }

    private func beginInFlight() { lock.withLock { _inFlightCount += 1 } }
    private func endInFlight() { lock.withLock { if _inFlightCount > 0 { _inFlightCount -= 1 } } }

    /// Server clock the bundle carries when a test asked for it
    /// (mockServerTime), as the backend's header does.
    var serverTimeMs: Int? {
        get { lock.withLock { _serverTimeMs } }
        set { lock.withLock { _serverTimeMs = newValue } }
    }
    private var _serverTimeMs: Int? = nil

    /// What `mockApi` set for one endpoint, and the one-shot queue.
    func setRule(_ rule: Rule, for endpoint: String) {
        lock.withLock { rules[endpoint] = rule }
    }

    func addOnce(_ rule: Rule, for endpoint: String) {
        lock.withLock { once[endpoint, default: []].append(rule) }
    }

    func removeRule(for endpoint: String) {
        _ = lock.withLock { rules.removeValue(forKey: endpoint) }
    }

    func clearLog() {
        lock.withLock { log.removeAll() }
    }

    var logCount: Int {
        lock.withLock { log.count }
    }

    /// The logged requests from [index] on.
    func logSnapshot(from index: Int) -> [YamlRequest] {
        lock.withLock { Array(log.dropFirst(index)) }
    }

    /// Logical endpoint name to the URL path suffix the SDK calls.
    static let paths: [String: String] = [
        "getCampaigns": "/api/v1/engage/sdk/getCampaignBundle",
        "getSdkConfig": "/api/v1/engage/sdk/getSdkConfig",
        "track": "/api/v1/engage/sdk/track",
        "userContext": "/api/v1/engage/sdk/userContext",
        "session": "/api/v1/engage/sdk/session",
        "surveySubmission": "/api/v1/engage/sdk/recordSubmission",
        "recordComponents": "/api/v1/engage/sdk/recordComponents",
        "recordPageCapture": "/api/v1/engage/sdk/recordPageCapture",
        "liveTestAck": "/api/v1/engage/sdk/testInvocation/ack",
        "liveTestEvent": "/api/v1/engage/sdk/testInvocation/event",
        "liveTestConnect": "/api/v1/engage/sdk/live/connect",
    ]

    static func endpointName(for url: URL) -> String {
        let absolute = url.absoluteString
        for (name, suffix) in paths where absolute.hasSuffix(suffix) {
            return name
        }
        return absolute
    }

    /// Rewrites `https://testkit.local/assets/...` (and `http://`) video and
    /// Lottie URLs in campaign JSON to local `file://` URLs under
    /// `testkit/mock-server`, so `AVPlayer` and Lottie (which bypass
    /// `URLProtocol`) load Test Kit media locally. Image URLs stay `https://`
    /// so `YamlTestkitURLProtocol` / `YamlImageStubLoader` serve them and
    /// parsers requiring http(s) URLs (like anchorless guide crops) accept them.
    static func resolveTestkitUrls(_ value: Any, origin: String) -> Any {
        if let str = value as? String {
            let lower = str.lowercased()
            let isLocalMedia = lower.hasSuffix(".mp4") || lower.hasSuffix(".mov")
                || lower.hasSuffix(".m4v") || lower.hasSuffix(".lottie")
            if isLocalMedia {
                if str.hasPrefix("https://testkit.local/assets/") {
                    return origin + String(str.dropFirst("https://testkit.local".count))
                }
                if str.hasPrefix("http://testkit.local/assets/") {
                    return origin + String(str.dropFirst("http://testkit.local".count))
                }
            }
            return str
        }
        if let dict = value as? [String: Any] {
            return dict.mapValues { resolveTestkitUrls($0, origin: origin) }
        }
        if let list = value as? [Any] {
            return list.map { resolveTestkitUrls($0, origin: origin) }
        }
        return value
    }

    private func decide(url: URL, body: Data?, headers: [String: String]) -> (
        endpoint: String, decoded: Any?, rule: Rule?
    ) {
        let endpoint = Self.endpointName(for: url)
        var decoded: Any? = nil
        if let body {
            decoded = (try? JSONSerialization.jsonObject(
                with: body, options: [.fragmentsAllowed])) ?? String(data: body, encoding: .utf8)
        }
        return (endpoint, decoded, lookup(endpoint: endpoint, decoded: decoded, headers: headers))
    }

    /// The shared rule lookup: logs the request, then serves the one-shot
    /// queue or the standing rule. The logged body is whatever the caller
    /// decoded (plain JSON, or the `capture` field of a multipart upload).
    private func lookup(endpoint: String, decoded: Any?, headers: [String: String]) -> Rule? {
        lock.withLock {
            log.append(YamlRequest(
                endpoint: endpoint, body: decoded,
                headers: Dictionary(
                    headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 })))
            if var queue = once[endpoint], !queue.isEmpty {
                let next = queue.removeFirst()
                once[endpoint] = queue
                return next
            }
            return rules[endpoint]
        }
    }

    private func answer(_ rule: Rule) -> NetworkResponse? {
        if rule.networkError { return nil }
        let data: Data?
        if let body = rule.body {
            if let text = body as? String {
                data = Data(text.utf8)
            } else {
                data = try? JSONSerialization.data(withJSONObject: body)
            }
        } else {
            data = Data("{}".utf8)
        }
        return NetworkResponse(
            statusCode: rule.status, headers: [:], body: data,
            isSuccessful: (200..<300).contains(rule.status))
    }

    /// The real client's header assembly (defaults, provider, session id), so
    /// the log holds the headers the wire would carry. Set at boot.
    var assembleHeaders: (@Sendable ([String: String]) -> [String: String])? {
        get { lock.withLock { _assembleHeaders } }
        set { lock.withLock { _assembleHeaders = newValue } }
    }
    private var _assembleHeaders: (@Sendable ([String: String]) -> [String: String])?

    func execute(request: NetworkRequest) async throws -> NetworkResponse {
        beginInFlight()
        var tracked = true
        defer { if tracked { endInFlight() } }
        let headers = assembleHeaders?(request.headers) ?? request.headers
        let (endpoint, _, rule) = decide(
            url: request.url, body: request.body, headers: headers)
        if let rule {
            if rule.hang {
                tracked = false
                endInFlight()
                let heldAnswer = await withCheckedContinuation { continuation in
                    lock.lock()
                    held[endpoint, default: []].append(continuation)
                    lock.unlock()
                }
                if let heldAnswer { return heldAnswer }
            } else if rule.networkError {
                throw URLError(.notConnectedToInternet)
            } else if let response = answer(rule) {
                return response
            }
        }
        return `default`(for: endpoint)
    }

    /// What an unmocked endpoint answers: the bundle serves the world's
    /// campaigns; everything else is accepted. A fixture carries its Canvas
    /// design-token catalog beside the campaign, as the bundle carries
    /// `designTokens` beside `campaigns`, so the tokens ride along too.
    func `default`(for endpoint: String) -> NetworkResponse {
        if endpoint == "getCampaigns" {
            let rawCampaigns = bundle()
            let campaigns: [[String: Any]]
            if let workspace = FixtureLoader.workspaceURL() {
                let origin = FixtureLoader.resolveAssetOrigin(in: "{{TESTKIT_ASSET_ORIGIN}}", workspaceUrl: workspace)
                campaigns = rawCampaigns.map { Self.resolveTestkitUrls($0, origin: origin) as? [String: Any] ?? $0 }
            } else {
                campaigns = rawCampaigns
            }
            var tokens: [String: Any] = [:]
            for campaign in campaigns {
                if let catalog = campaign["designTokens"] as? [String: Any] {
                    tokens.merge(catalog) { _, new in new }
                }
            }
            var response: [String: Any] = ["campaigns": campaigns]
            if !tokens.isEmpty { response["designTokens"] = tokens }
            let body = try? JSONSerialization.data(withJSONObject:
                ["data": ["response": response]])
            // A server clock the test asked the bundle to carry
            // (mockServerTime), read by parsing that needs it.
            var headers: [String: String] = [:]
            if let ms = serverTimeMs { headers["X-Digia-Server-Time-Ms"] = "\(ms)" }
            return NetworkResponse(statusCode: 200, headers: headers, body: body, isSuccessful: true)
        }
        if endpoint == "userContext" {
            // An empty, fresh context, as the server answers a user it knows nothing of.
            let body = try? JSONSerialization.data(withJSONObject: [
                "isSuccess": true,
                "data": ["response": [
                    "campaigns": [String](), "attributes": [String: Any](),
                    "expiresInSeconds": 900,
                ]],
            ])
            return NetworkResponse(statusCode: 200, headers: [:], body: body, isSuccessful: true)
        }
        if endpoint == "recordPageCapture" {
            // Unmocked, the upload succeeds, as other endpoints' defaults do.
            return NetworkResponse(
                statusCode: 200, headers: [:],
                body: Data(#"{"data":{"response":{"assetId":"yaml-test-asset"}}}"#.utf8),
                isSuccessful: true)
        }
        return NetworkResponse(
            statusCode: 200, headers: [:],
            body: Data(#"{"accepted":1,"rejected":0,"errors":[]}"#.utf8),
            isSuccessful: true)
    }

    /// Whether a `hang` rule holds the endpoint now.
    func isHolding(_ endpoint: String) -> Bool {
        lock.withLock { rules[endpoint]?.hang == true || !(held[endpoint]?.isEmpty ?? true) }
    }

    /// Answers every held request as the harness would, so none outlives the test.
    func releaseAll() {
        lock.withLock {
            let all = held.values.flatMap { $0 }
            held.removeAll()
            return all
        }.forEach { $0.resume(returning: nil) }
    }

    /// Answers every held request on [endpoint], then stops holding it.
    /// Returns false when nothing was held.
    func release(endpoint: String, with rule: Rule?) -> Bool {
        lock.lock()
        let pending = held.removeValue(forKey: endpoint) ?? []
        if rules[endpoint]?.hang == true { rules.removeValue(forKey: endpoint) }
        lock.unlock()
        guard !pending.isEmpty else { return false }
        for continuation in pending {
            continuation.resume(returning: rule.flatMap(answer) ?? `default`(for: endpoint))
        }
        return true
    }

    func executeMultipart(request: MultipartUploadRequest) async throws -> NetworkResponse {
        beginInFlight()
        var tracked = true
        defer { if tracked { endInFlight() } }
        // The logged body is the decoded `capture` field, so assertApi and
        // assertCaptureUpload match the envelope on every stack (the
        // `capture.png` file part is wire detail the unit tests own).
        let captureJSON: Any? = request.formFields["capture"].flatMap { text in
            (try? JSONSerialization.jsonObject(
                with: Data(text.utf8), options: [.fragmentsAllowed])) ?? text
        }
        let headers = assembleHeaders?(request.headers) ?? request.headers
        let endpoint = Self.endpointName(for: request.url)
        if let rule = lookup(endpoint: endpoint, decoded: captureJSON, headers: headers) {
            if rule.hang {
                tracked = false
                endInFlight()
                let heldAnswer = await withCheckedContinuation { continuation in
                    lock.lock()
                    held[endpoint, default: []].append(continuation)
                    lock.unlock()
                }
                if let heldAnswer { return heldAnswer }
            } else if rule.networkError {
                throw URLError(.notConnectedToInternet)
            } else if let response = answer(rule) {
                return response
            }
        }
        return `default`(for: endpoint)
    }

    private func appendLog(_ entry: YamlRequest) {
        lock.withLock { log.append(entry) }
    }

    func openSseStream(
        request: NetworkRequest, handler: any SseStreamHandler
    ) -> any CancellableSubscription {
        appendLog(YamlRequest(endpoint: Self.endpointName(for: request.url), body: nil, headers: [:]))
        let subscription = YamlSseSubscription()
        lock.withLock { sseStreams.append((handler: handler, subscription: subscription)) }
        handler.onOpen()
        return subscription
    }

    /// Every live-test stream the SDK opened this test, open or cancelled.
    private var sseStreams: [(handler: any SseStreamHandler, subscription: YamlSseSubscription)] = []

    /// Delivers one dashboard event down every still-open live-test stream.
    /// Throws when none is open, so reaching a later step proves switching
    /// live testing on opened the stream.
    func emitSse(event: String, data: String, line: Int) throws {
        let live = lock.withLock { sseStreams.filter { !$0.subscription.isCancelled }.map(\.handler) }
        guard !live.isEmpty else {
            throw YamlTestFailure(
                "emitSse: no open live-test stream",
                expected: "live testing switched on first",
                line: line)
        }
        for handler in live { handler.onEvent(SseEvent(event: event, data: data)) }
    }
}

private final class YamlSseSubscription: CancellableSubscription, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

// MARK: - The recording CEP plugin

/// What a CEP does in production, reduced to what the driver asserts:
/// holds the host, hands it triggers (buffering what arrives before the host
/// is ready, as the contract says), and records every call the SDK makes.
@MainActor
final class YamlRecordingCep: DigiaCEPPlugin {
    let id = "yaml-test"
    private(set) var host: DigiaCEPHost?

    /// `{ call: setup|teardown|onScreenChanged|trackEvent, ... }`, in order.
    private(set) var calls: [[String: Any]] = []

    /// Every delivery, in delivery order, with the trigger as delivered.
    private(set) var deliveries: [(trigger: CEPTriggerPayload, presentation: any CampaignPresentation)] = []

    /// Triggers held while the host was not ready, with the test-clock time
    /// they arrived at. Entries older than 5 minutes drop as pending_expired
    /// on flush, as a shipped plugin's own buffer does.
    private var buffered: [(payload: CEPTriggerPayload, heldAtMs: Int64)] = []

    /// The test's fake wall clock in milliseconds. Set by the YAML driver at
    /// launch; unset means wall time (which never reaches the TTL in a test).
    var clockMs: (() -> Int64)?

    /// The signals each delivery received, in order (`displayed`, `clicked`).
    private(set) var signals: [ObjectIdentifier: [String]] = [:]

    private func deliver(_ host: DigiaCEPHost, _ payload: CEPTriggerPayload) {
        let presentation = host.deliver(payload)
        let key = ObjectIdentifier(presentation)
        signals[key] = signals[key] ?? []
        _ = presentation.onSignal { [weak self] signal in
            self?.signals[key, default: []].append(signal.type)
        }
        deliveries.append((payload, presentation))
    }

    func attach(host: DigiaCEPHost) {
        self.host = host
        calls.append(["call": "setup"])
        flush()
    }

    func detach() {
        calls.append(["call": "teardown"])
        host = nil
    }

    func onScreenChanged(_ screenName: String) {
        calls.append(["call": "onScreenChanged", "screenName": screenName])
    }

    func trackEvent(_ eventName: String, properties: [String: Any]) {
        calls.append(["call": "trackEvent", "name": eventName, "properties": properties])
    }

    func onHostReady() {
        flush()
    }

    /// What the CEP does when its campaign fires. Queued when the host is
    /// not ready yet; dropped payloads never silently vanish — they deliver
    /// once the host is ready.
    func fire(_ payload: CEPTriggerPayload) {
        guard let host, host.isReady else {
            buffered.append((payload, (clockMs?() ?? Int64(Date().timeIntervalSince1970 * 1000))))
            return
        }
        deliver(host, payload)
    }

    func flush() {
        guard let host, host.isReady else { return }
        // A trigger held past its 5-minute TTL drops as pending_expired and
        // is never delivered, as D9 specifies.
        if let now = clockMs?() {
            buffered.removeAll { now - $0.heldAtMs >= 5 * 60 * 1000 }
        }
        // Newest first, so the freshest modal takes the surface: the
        // FakeCep buffer's flush order on every stack.
        for payload in buffered.reversed() {
            deliver(host, payload.payload)
        }
        buffered.removeAll()
    }
}

// MARK: - The diagnostic sink

/// Records every diagnostic record the SDK emits, like the rule-case
/// runner's sink does on Flutter.
final class YamlLogSink: DiagnosticSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _records: [TimelineRecord] = []

    var records: [TimelineRecord] { lock.withLock { _records } }

    func accepts(_ record: TimelineRecord) -> Bool { true }
    func emit(_ record: TimelineRecord) { lock.withLock { _records.append(record) } }
}

// MARK: - Partial matching

/// Every key of [want] is in [got] with a matching value; maps recurse, so a
/// nested `properties` may be partial too. Anything else is compared whole.
/// Mirrors `_matches`/`_contains` in the Flutter driver.
enum YamlMatch {
    static func matches(_ got: Any?, _ want: Any?) -> Bool {
        if let matcher = valueMatcher(want) {
            return matchValue(matcher, got, present: true)
        }
        if let wantMap = want as? [String: Any] {
            guard let gotMap = got as? [String: Any] else { return false }
            return wantMap.allSatisfy { key, value in
                if let matcher = valueMatcher(value) {
                    return matchValue(matcher, gotMap[key], present: gotMap.keys.contains(key))
                }
                return gotMap.keys.contains(key) && matches(gotMap[key], value)
            }
        }
        if let wantList = want as? [Any] {
            guard let gotList = got as? [Any], gotList.count == wantList.count else {
                return false
            }
            return zip(gotList, wantList).allSatisfy { matches($0, $1) }
        }
        return equal(got, want)
    }

    /// A value matcher (commands.yaml header): a non-empty map whose every
    /// key starts with `$`. Mirrors `isValueMatcher` in matchers.dart.
    static func valueMatcher(_ want: Any?) -> [String: Any]? {
        guard let map = want as? [String: Any], !map.isEmpty,
              map.keys.allSatisfy({ $0.hasPrefix("$") })
        else { return nil }
        return map
    }

    /// Whether [got] satisfies [matcher]. [present] is false when the key the
    /// value would sit under is absent (only `$exists: false` passes then).
    /// An unknown matcher key or `$type` never matches. Mirrors `matchValue`.
    static func matchValue(_ matcher: [String: Any], _ got: Any?, present: Bool) -> Bool {
        let number: Double? = {
            guard let n = got as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return n.doubleValue
        }()
        return matcher.allSatisfy { key, value in
            switch key {
            case "$exists": return present == ((value as? Bool) ?? false)
            case "$gte":
                guard present, let n = number, let w = (value as? NSNumber)?.doubleValue else { return false }
                return n >= w
            case "$lte":
                guard present, let n = number, let w = (value as? NSNumber)?.doubleValue else { return false }
                return n <= w
            case "$type": return present && hasType(got, "\(value)")
            default: return false
            }
        }
    }

    private static func hasType(_ value: Any?, _ type: String) -> Bool {
        let isBool = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        switch type {
        case "int":
            // A whole number with no fraction part on the wire: JSONSerialization
            // reads `5` as an integer NSNumber and `5.0`/`4.5` as a double.
            guard let n = value as? NSNumber, !isBool else { return false }
            return !CFNumberIsFloatType(n)
        case "number": return value is NSNumber && !isBool
        case "string": return value is String
        case "bool": return isBool
        case "list": return value is [Any]
        case "map": return value is [String: Any]
        default: return false
        }
    }

    private static func equal(_ a: Any?, _ b: Any?) -> Bool {
        switch (norm(a), norm(b)) {
        case (.none, .none): return true
        case (.some(let x), .some(let y)): return x == y
        default: return false
        }
    }

    private static func norm(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let number = value as? NSNumber {
            // Bool is an NSNumber too: keep true/false distinct from 1/0.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            if CFNumberIsFloatType(number) {
                return String(number.doubleValue)
            }
            return String(number.int64Value)
        }
        return "\(value)"
    }

    /// Canonical JSON for failure output.
    static func json(_ value: Any?) -> String {
        guard let value else { return "null" }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(
               withJSONObject: value, options: [.sortedKeys, .prettyPrinted]),
           let text = String(data: data, encoding: .utf8)
        {
            return text
        }
        if let text = value as? String, let data = text.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           JSONSerialization.isValidJSONObject(parsed),
           let pretty = try? JSONSerialization.data(
               withJSONObject: parsed, options: [.sortedKeys, .prettyPrinted]),
           let out = String(data: pretty, encoding: .utf8)
        {
            return out
        }
        return "\(value)"
    }
}

/// A clock that only moves when the test says so. A sleeper waits until
/// `advance` passes its due time; cancelling its task ends the wait.
@MainActor
final class YamlFakeClock {
    private var now: UInt64 = 0
    var nowSeconds: TimeInterval { Double(now) / 1_000_000_000 }
    private var nextId = 0
    private var sleepers: [(id: Int, due: UInt64, wake: CheckedContinuation<Void, Error>)] = []

    func sleep(nanoseconds: UInt64) async throws {
        let id = nextId
        nextId += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (wake: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    wake.resume(throwing: CancellationError())
                } else {
                    sleepers.append((id, now + nanoseconds, wake))
                }
            }
        } onCancel: {
            Task { @MainActor in self.end(id) }
        }
    }

    /// Moves to now + [delta] one due time at a time: each sleeper due on
    /// the way wakes at its own due time, and its task runs (and may sleep
    /// again, counted from that time) before the clock moves on, so a loop of
    /// 1 s ticks fires once per second covered.
    func advance(byNanoseconds delta: UInt64) async {
        let (sum, overflow) = now.addingReportingOverflow(delta)
        let target = overflow ? UInt64.max : sum
        var rounds = 0
        while rounds < 100_000, let next = sleepers.map(\.due).filter({ $0 <= target }).min() {
            rounds += 1
            now = max(now, next)
            let due = sleepers.filter { $0.due <= now }
            sleepers.removeAll { $0.due <= now }
            due.forEach { $0.wake.resume() }
            // Let the woken tasks run on the main actor before moving on.
            for _ in 0..<5 { await Task.yield() }
            try? await Task.sleep(nanoseconds: 500_000)
        }
        now = max(now, target)
    }

    func cancelAll() {
        let all = sleepers
        sleepers.removeAll()
        all.forEach { $0.wake.resume(throwing: CancellationError()) }
    }

    private func end(_ id: Int) {
        guard let i = sleepers.firstIndex(where: { $0.id == id }) else { return }
        sleepers.remove(at: i).wake.resume(throwing: CancellationError())
    }
}

/// The test's fake time: the wall clock (session timeout, cap windows,
/// user-context expiry) and the clock waits count on, which keeps counting
/// in the background. Read off the main actor by the SDK, so lock-protected.
final class YamlTime: @unchecked Sendable {
    private let lock = NSLock()
    private var _wallMs = Int64(Date().timeIntervalSince1970 * 1000)
    private var _monotonicMs = 1_000_000_000

    var wallMs: Int64 { lock.withLock { _wallMs } }
    var monotonicMs: Int { lock.withLock { _monotonicMs } }

    func advance(byMs delta: Int64) {
        lock.withLock {
            _wallMs += delta
            // Saturates: a wait end past Int.max never comes due.
            let (sum, overflow) = _monotonicMs.addingReportingOverflow(Int(delta))
            _monotonicMs = overflow ? Int.max : sum
        }
    }

    func setWall(_ ms: Int64) { lock.withLock { _wallMs = ms } }
}

/// What the plain host screen shows below its title, in mount order.
@MainActor
final class YamlHostMounts: ObservableObject {
    struct Item: Hashable {
        let kind: String
        let key: String
    }

    @Published var items: [Item] = []

    /// Slots mounted below the fold (after a tall spacer), initially unexposed.
    @Published var belowFold: [Item] = []

    /// Whether the whole host is transparent (alpha 0 that keeps layout).
    @Published var transparent = false

    func slotMounted(_ key: String) -> Bool {
        items.contains(Item(kind: "slot", key: key)) || belowFold.contains(Item(kind: "slot", key: key))
    }
}

/// Slot content for the phone golden frame: nothing when the test mounted
/// nothing (existing overlay goldens keep matching), the mounted slots
/// otherwise, so slot content can be golden-tested on the fixed phone surface.
struct YamlPhoneHome: View {
    @ObservedObject var mounts: YamlHostMounts
    /// The golden device's top safe inset (47 phone, 24 tablet). The simulator's
    /// own inset differs by model, so the home is placed by this fixed value,
    /// the same one Android and Flutter use.
    let topInset: CGFloat

    var body: some View {
        Group {
            if mounts.items.isEmpty && mounts.belowFold.isEmpty {
                Color.clear
            } else {
                YamlHostHome(mounts: mounts)
                    .padding(.top, topInset)
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
    }
}

/// The app's home screen: a title, then every mounted slot and anchor.
struct YamlHostHome: View {
    @ObservedObject var mounts: YamlHostMounts

    var body: some View {
        // No wrapper when opaque and nothing below the fold, so tests that
        // never scroll or fade see the exact tree they always did.
        Group {
            if mounts.belowFold.isEmpty {
                // Top-left, like Android and Flutter, so anchors (and what the
                // SDK places against them) land at the same spot on every stack.
                VStack(alignment: .leading, spacing: 0) {
                    Text("App home").font(.custom("Roboto", size: 14)).frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40, alignment: .topLeading)
                    hostItems
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("App home").font(.custom("Roboto", size: 14)).frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40, alignment: .topLeading)
                        hostItems
                        ForEach(mounts.belowFold, id: \.self) { item in
                            Color.clear.frame(height: 1500)
                            hostSlot(item)
                        }
                    }
                }
            }
        }
        .opacity(mounts.transparent ? 0 : 1)
    }

    @ViewBuilder
    private var hostItems: some View {
        ForEach(mounts.items, id: \.self) { item in
            hostSlot(item)
        }
    }

    @ViewBuilder
    private func hostSlot(_ item: YamlHostMounts.Item) -> some View {
        if item.kind == "slot" {
            // A test hook for tapSlot (and any slot-frame lookup): the driver
            // host, never the SDK. `children: .contain`, like the SDK's own
            // TestView: a bare identifier hides the slot's children from the
            // accessibility walk, which tapOn/tapSlot by id need.
            DigiaSlot(item.key) { EmptyView() }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("slot:\(item.key)")
        } else {
            DigiaAnchor(anchorKey: item.key) {
                Text("anchor \(item.key)").font(.custom("Roboto", size: 14)).frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40, alignment: .topLeading)
            }
        }
    }
}

/// One pushed host screen for pushScreen/popScreen/showDialog.
struct YamlNavEntry {
    let viewController: UIViewController
    let isDialog: Bool
}
