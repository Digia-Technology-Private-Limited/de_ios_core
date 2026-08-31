import Combine
import Foundation
import UIKit

@MainActor
final class SDKInstance: ObservableObject, DigiaCEPDelegate {
    static let shared = SDKInstance()

    private struct ExternalGuide {
        let campaign: CampaignModel
        let payload: CEPTriggerPayload
    }

    @Published private(set) var config: DigiaConfig?
    @Published private(set) var sdkState: SDKState = .notInitialized
    @Published private(set) var isHostMounted = false
    @Published private(set) var captureModeEnabled = UserDefaults.standard.bool(
        forKey: "digia_anchorless_capture_enabled"
    )
    @Published private(set) var captureTextEnabled = UserDefaults.standard.bool(
        forKey: "digia_anchorless_capture_include_text"
    )
    @Published private(set) var captureMediaEnabled = UserDefaults.standard.bool(
        forKey: "digia_anchorless_capture_include_media"
    )
    @Published private(set) var captureStructureEnabled = UserDefaults.standard.bool(
        forKey: "digia_anchorless_capture_include_structure"
    )
    @Published private(set) var capturedPages: [CaptureDebugPage] = []
    @Published private(set) var captureStatusMessage: String?
    @Published private(set) var captureFlashRevision = 0
    var isCaptureSupported: Bool { config?.wrapperBinding == "react_native" }

    private var activePlugin: DigiaCEPPlugin?
    private let hostActionExecutor = HostActionExecutor()
    private lazy var actionExecutor = EngageActionExecutor(
        hostActionExecutor: hostActionExecutor
    )
    private(set) var font = DigiaFont()
    /// Mirrors Android's `ScreenTracker`: the last screen name reported via
    /// `Digia.setCurrentScreen`, forwarded to the active plugin and read into
    /// analytics events (`screenName`).
    private var _currentScreen: String?
    internal var currentScreenForAnchorless: String? { _currentScreen }
    private(set) var lastCampaignDropReason: String?
    private var activeExternalGuide: ExternalGuide?
    private var screenUpdateRevision = 0
    private var captureInFlight = false
    private var guideCompletionFired = false
    /// The design tokens the current campaign bundle was parsed with.
    ///
    /// Held because live test parses a campaign that never came through the
    /// bundle, and it has to resolve the same tokens the bundle's campaigns do.
    private var currentDesignTokens = DesignTokenCatalog.empty
    private var guideRenderer = GuideRenderer.reactNative

    let campaignStore = CampaignStore()
    let controller = DigiaOverlayController()
    let inlineController = InlineCampaignController()
    let guideOrchestrator = GuideOrchestrator()
    let surveyOrchestrator = SurveyOrchestrator()
    /// Assigned in `init()` — its callbacks close over `self`, so it can't be a
    /// plain no-arg stored property the way `surveyOrchestrator` is. Mirrors
    /// `events`'s identical implicitly-unwrapped-var pattern below.
    var floaterOrchestrator: FloaterOrchestrator!
    /// Holds the single active story floater. Its own orchestrator rather than a mode of
    /// `floaterOrchestrator`: a PiP's whole design rests on owning an `AVPlayer` that
    /// outlives its view, and a story floater has no media surface at all — its window is
    /// a canvas and its story is mounted by `FloaterStoryOverlayView`.
    var floaterStoryOrchestrator: FloaterStoryOrchestrator!
    /// Wired to `floaterOrchestrator.setAppForegrounded` in `init()` — matches
    /// Android's `DigiaInstance.kt` `ProcessLifecycleOwner` `ON_START`/`ON_STOP`
    /// observer, pausing/resuming the floater's video when the app backgrounds.
    private var appBackgroundObserver: NSObjectProtocol?
    private var appForegroundObserver: NSObjectProtocol?

    private var completedSurveyToken: Int64?
    /// Survey whose start-engagement ("welcome_start") click has already fired
    /// (once per showing).
    private var welcomeStartToken: Int64?
    /// Per-question viewed-at timestamps, keyed by "<surveyToken>:<nodeId>".
    /// Used to compute `time_to_answer_ms` on QuestionAnswered.
    private var questionViewedAt: [String: Date] = [:]
    private var analyticsService: AnalyticsService?
    /// Whether the floating "Digia" debug bubble is shown. See
    /// `DigiaDebugOverlayController`.
    private let debugOverlayController = DigiaDebugOverlayController()
    /// Batches pages/anchors/slots seen at runtime to the Engage Component
    /// Registry, when the debug-only "recording mode" toggle is on. See
    /// `ComponentRegistryService`.
    private let componentRegistry: ComponentRegistryService
    /// Debug-only live-campaign-testing coordinator (SSE connect + ACKs).
    private var liveTestService = LiveTestService()
    /// Live-test campaigns, parsed on the spot — never added to `campaignStore`.
    private var liveTestCampaigns: [String: CampaignModel] = [:]
    /// In-flight live test invocations, keyed by synthetic `cepCampaignId`.
    private var liveTestContexts: [String: LiveTestContext] = [:]
    /// Whether the host app is a debug build, resolved once at `initialize`.
    /// Gates the component registry and `DigiaDebugSettingsView`.
    private(set) var isDebugBuild = false
    /// Native frequency capping for all managed campaigns (nudge, survey, and —
    /// on React Native — guides, whose lifecycle events arrive over the bridge).
    private var frequencyManager: FrequencyManager?
    /// Reports an unhealthy CEP plugin as a gated warning. Mirrors Android's
    /// `DiagnosticsReporter` wired into `PluginRegistry`.
    private let diagnostics = DiagnosticsReporter(logger: { DigiaLog.warning($0) })

    /// Set by the RN bridge. When non-nil the SDK is RN-driven: guides render in
    /// JS, so on a guide trigger native only applies frequency capping and (if
    /// allowed) invokes this hook to ask JS to render, instead of rendering the
    /// guide natively. Nil in pure-native apps, where guides render natively.
    var onGuideRenderRequest: ((CEPTriggerPayload) -> Void)?
    var onLiveTestGuideRenderRequest: ((LiveTestGuideRenderRequest) -> Void)?
    var onLiveTestGuideCancelRequest: ((String) -> Void)?
    var guideHostActionHandler: GuideHostActionHandler?

    // Event system (mirrors Android): a fan-out emitter over two sinks — the
    // coarse CEP channel (`toCep`) and Digia's rich analytics (`toDigia`).
    // Campaign id/type are resolved from the store inside the Digia sink.
    private let dwellTracker = DwellTracker()
    private var events: EngageEventEmitter!

    private init() {
        componentRegistry = ComponentRegistryService(debugOverlay: debugOverlayController)
        events = EngageEventEmitter(
            cep: CepPluginSink { [weak self] event, payload in
                self?.activePlugin?.notifyEvent(event, payload: payload)
            },
            digia: DigiaAnalyticsSink(
                getAnalyticsService: { [weak self] in self?.analyticsService },
                getCampaign: { [weak self] key in self?.campaignStore.find(key) }
            ),
            onLiveTestShown: { [weak self] cepCampaignId in
                self?.liveTestContexts[cepCampaignId]?.reportShown()
            }
        )
        controller.onAction = { [weak self] actionType, url, payload in
            self?.activePlugin?.notifyAction(actionType: actionType, url: url, payload: payload)
                ?? false
        }
        hostActionExecutor.setLegacyActionHandler { [weak self] actionType, url in
            guard let self,
                  let payload = guideOrchestrator.state?.payload ?? controller.activeNudge?.payload
            else { return false }
            return controller.onAction?(actionType, url, payload) ?? false
        }
        floaterOrchestrator = FloaterOrchestrator(
            onDismissed: { [weak self] state, reason, metrics in
                self?.emitFloaterDismissed(state, reason, metrics)
            },
            onCompleted: { [weak self] state in self?.emitFloaterCompleted(state) },
            onStepViewed: { [weak self] state in self?.emitFloaterStepViewed(state) },
            onStepDismissed: { [weak self] state in self?.emitFloaterStepDismissed(state) },
            onVisible: { [weak self] state in self?.reportFloaterImpression(state) }
        )
        guideOrchestrator.onStateChanged = { [weak self] state in
            self?.guideStateDidChange(state)
        }
        floaterStoryOrchestrator = FloaterStoryOrchestrator(
            onDismissed: { [weak self] state, reason, metrics in
                self?.emitFloaterStoryDismissed(state, reason, metrics)
            },
            onCompleted: { [weak self] state in self?.emitFloaterStoryCompleted(state) },
            onStepViewed: { [weak self] state in self?.emitFloaterStoryStepViewed(state) },
            onStepDismissed: { [weak self] state in self?.emitFloaterStoryStepDismissed(state) },
            onVisible: { [weak self] state in self?.reportFloaterStoryImpression(state) }
        )

        appBackgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.floaterOrchestrator.setAppForegrounded(false)
                self?.floaterStoryOrchestrator.setAppForegrounded(false)
            }
        }
        appForegroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.floaterOrchestrator.setAppForegrounded(true)
                self?.floaterStoryOrchestrator.setAppForegrounded(true)
            }
        }
    }

    func initialize(_ config: DigiaConfig) async throws {
        hostActionExecutor.configure(config.actionHandlers)
        guard self.config == nil else { return }
        self.config = config
        DigiaLog.configure(config.logLevel)
        DigiaEndpoints.configure(config)
        isDebugBuild = DigiaDebugDetection.isDebugBuild()
        // Config default for the debug bubble; an explicit per-device toggle
        // persisted by DigiaDebugOverlayController wins over it.
        debugOverlayController.applyConfigDefault(config.showDebugTools)

        font = DigiaFont(fontFamily: config.fontFamily)
        CampaignCanvasTheme.shared.update(config.themeMode)

        if config.wrapperBinding == "react_native" {
            // RN fetches campaigns itself (it needs the same response to render
            // JS-side campaigns) and hands them to us via populateCampaignBundle() —
            // fetching here too would duplicate the network call. sdkState stays
            // .notInitialized until that call arrives.
            logVerbose("Skipping native campaign fetch — awaiting populateCampaignBundle() from RN")
            return
        }

        var campaigns: [CampaignModel] = []
        do {
            let bundle = try await CampaignFetcher(config: config).fetch()
            campaigns = bundle.campaigns
            currentDesignTokens = bundle.designTokens
            guideRenderer = bundle.guideRenderer
        } catch {
            // Campaign fetch failure must not block SDK readiness.
            logVerbose("CampaignFetcher failed: \(error)")
        }
        completeInitialization(campaigns)
    }

    func executeActionFlow(
        _ actions: [EngageAction],
        variables: VariableContext?,
        localActionExecutor: LocalActionExecutor
    ) async {
        await actionExecutor.executeActionFlow(
            actions,
            variables: variables,
            localActionExecutor: localActionExecutor
        )
    }

    func executeGuideActionFlow(
        _ actions: [EngageAction],
        variables: VariableContext?,
        campaignID: String,
        localActionExecutor: LocalActionExecutor
    ) async {
        let hostActionHandler: ((EngageAction) -> Bool)? = if guideHostActionHandler == nil {
            nil
        } else {
            { [weak self] action in
                self?.handleGuideHostAction(action, campaignID: campaignID) ?? false
            }
        }
        await actionExecutor.executeActionFlow(
            actions,
            variables: variables,
            localActionExecutor: localActionExecutor,
            hostActionHandler: hostActionHandler
        )
    }

    private func handleGuideHostAction(_ action: EngageAction, campaignID: String) -> Bool {
        guard let guideHostActionHandler else { return false }
        switch action {
        case .openDeeplink(let url, let fallbackUrl):
            return guideHostActionHandler("deepLink", url, fallbackUrl, nil, campaignID)
        case .openUrl(let url, let presentation):
            return guideHostActionHandler(
                "openURL", url, nil, presentation ?? "external", campaignID)
        default:
            return false
        }
    }

    func setCustomKVHandler(_ handler: CustomKVHandler?) {
        hostActionExecutor.setCustomKVHandler(handler)
    }

    func setDeepLinkHandler(_ handler: DeepLinkHandler?) {
        hostActionExecutor.setDeepLinkHandler(handler)
    }

    func setOpenURLHandler(_ handler: OpenURLHandler?) {
        hostActionExecutor.setOpenURLHandler(handler)
    }

    private func completeInitialization(_ campaigns: [CampaignModel]) {
        campaignStore.populate(campaigns)
        if campaignStore.isEmpty {
            DigiaLog.warning("[SDKInstance] CampaignStore populated empty")
        } else {
            DigiaLog.warning(
                "[SDKInstance] CampaignStore populated count=\(campaigns.count) entries=[\(campaignStore.debugSummary)]"
            )
        }

        sdkState = .ready
        if analyticsService == nil, let config {
            analyticsService = AnalyticsService.create(config: config)
        }
        if let config, let analyticsService {
            componentRegistry.configure(
                config: config,
                deviceId: analyticsService.identity.anonymousId,
                isDebugBuild: isDebugBuild
            )
            if captureModeEnabled, isCaptureSupported {
                componentRegistry.setEnabled(true)
            } else if captureModeEnabled {
                setCaptureModeEnabled(false)
            }
            liveTestService.configure(
                config: config,
                deviceId: analyticsService.identity.anonymousId,
                isDebugBuild: isDebugBuild,
                onCampaignTest: { [weak self] invocation in self?.handleLiveTestCampaign(invocation)
                }
            )
        }

        // Frequency capping pulls the authoritative sessionId from analytics so
        // `session` windows track the same session the backend sees.
        if frequencyManager == nil {
            frequencyManager = FrequencyManager(
                sessionIdProvider: { [weak self] in self?.analyticsService?.identity.sessionId }
            )
        }

        if let plugin = activePlugin {
            let report = plugin.healthCheck()
            if !report.isHealthy {
                diagnostics.report(report, source: plugin.identifier)
                plugin.setup(delegate: self)
            }
        }
    }

    /// RN-only entrypoint: JS already fetched campaigns for its own rendering needs,
    /// so it hands the raw campaign-bundle response here instead of native re-fetching.
    /// Called once after `initialize` when `wrapperBinding == "react_native"`.
    func populateCampaignBundle(
        _ bundleJson: String,
        guideRenderer resolvedGuideRenderer: GuideRenderer? = nil
    ) {
        var campaigns: [CampaignModel] = []
        do {
            let bundle = try CampaignFetcher.parse(Data(bundleJson.utf8), devicePlatform: "ios")
            campaigns = bundle.campaigns
            currentDesignTokens = bundle.designTokens
            guideRenderer = resolvedGuideRenderer ?? bundle.guideRenderer
            DigiaLog.warning(
                "[SDKInstance] populateCampaignBundle parsed raw=\(bundle.rawCampaigns.count) accepted=\(campaigns.count)"
            )
        } catch {
            DigiaLog.warning(
                "[SDKInstance] populateCampaignBundle failed: \(error.localizedDescription)")
        }
        completeInitialization(campaigns)
    }

    func setThemeMode(_ mode: DigiaThemeMode) { CampaignCanvasTheme.shared.update(mode) }

    private func logVerbose(_ message: String) {
        DigiaLog.verbose("[SDKInstance] \(message)")
    }

    private func logError(_ message: String) {
        DigiaLog.error("[SDKInstance] ERROR: \(message)")
    }

    func register(_ plugin: DigiaCEPPlugin) {
        activePlugin?.teardown()
        activePlugin = plugin
        plugin.setup(delegate: self)
        diagnostics.report(plugin.healthCheck(), source: plugin.identifier)
        if let screen = _currentScreen {
            plugin.forwardScreen(screen)
        }
    }

    func setCurrentScreen(_ name: String) {
        screenUpdateRevision += 1
        let revision = screenUpdateRevision
        let screenName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousScreen = _currentScreen
        _currentScreen = screenName.isEmpty ? nil : screenName
        DigiaLog.warning("[SDKInstance] Current screen set: \(_currentScreen ?? "<unset>")")
        componentRegistry.recordPage(screenName)
        if previousScreen != _currentScreen {
            dismissActiveCampaignsNotTargetingCurrentScreen()
        }
        if screenUpdateRevision == revision {
            activePlugin?.forwardScreen(screenName)
        }
    }

    func setCaptureModeEnabled(_ enabled: Bool) {
        guard !enabled || (isDebugBuild && isCaptureSupported) else { return }
        captureModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "digia_anchorless_capture_enabled")
        componentRegistry.setEnabled(enabled)
        if enabled { debugOverlayController.setVisible(true) }
    }

    func setCaptureProfile(
        includeText: Bool? = nil,
        includeMedia: Bool? = nil,
        includeStructure: Bool? = nil
    ) {
        if let includeText {
            captureTextEnabled = includeText
            UserDefaults.standard.set(includeText, forKey: "digia_anchorless_capture_include_text")
        }
        if let includeMedia {
            captureMediaEnabled = includeMedia
            UserDefaults.standard.set(includeMedia, forKey: "digia_anchorless_capture_include_media")
        }
        if let includeStructure {
            captureStructureEnabled = includeStructure
            UserDefaults.standard.set(includeStructure, forKey: "digia_anchorless_capture_include_structure")
        }
    }

    func captureCurrentPage() {
        guard isDebugBuild, isCaptureSupported, captureModeEnabled, !captureInFlight else { return }
        guard !Digia.hasActiveOverlay else {
            publishCaptureStatus("Capture unavailable — dismiss the active Digia experience first")
            return
        }
        guard let config, let pageKey = _currentScreen, !pageKey.isEmpty,
              let window = ViewControllerUtil.keyWindow(),
              let source = UIKitCaptureFacts.sourceFrame(window: window)
        else {
            publishCaptureStatus("Capture unavailable — current screen or app window is unavailable")
            return
        }

        captureInFlight = true
        let wasVisible = debugOverlayController.isVisible
        debugOverlayController.setVisible(false)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                captureInFlight = false
                if wasVisible { debugOverlayController.setVisible(true) }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            let profile = CaptureProfile(
                includeText: captureTextEnabled,
                includeImagesAndMedia: captureMediaEnabled,
                includeOtherStructuralNodes: captureStructureEnabled
            )
            let walk = await CaptureEvidenceWalker.walk(
                root: UIKitCaptureNode(view: window, rootView: window),
                windowBoundsPx: source.windowBoundsPx,
                profile: profile
            )
            guard case let .succeeded(nodes, traversal) = walk,
                  let png = Self.renderPNG(window: window)
            else {
                publishCaptureStatus("Capture unavailable — screen could not be rendered")
                return
            }
            captureFlashRevision += 1

            let appInfo = Bundle.main.infoDictionary ?? [:]
            let envelope = PageCaptureEnvelopeV1(
                pageKey: pageKey,
                binding: "reactNative",
                devicePlatform: .ios,
                source: source,
                screenshotSizePx: CaptureSize(
                    width: Int((window.bounds.width * window.screen.scale).rounded()),
                    height: Int((window.bounds.height * window.screen.scale).rounded())
                ),
                appVersion: appInfo["CFBundleShortVersionString"] as? String ?? "",
                appBuildNumber: appInfo["CFBundleVersion"] as? String ?? "",
                sdkVersion: DigiaSdkVersion.value,
                profile: profile,
                traversal: traversal,
                nodes: nodes
            )

            let upload = await URLSessionCaptureUploader(apiKey: config.apiKey).upload(
                envelope: envelope,
                png: png
            )
            switch upload {
            case let .accepted(assetId):
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                capturedPages.removeAll { $0.pageKey == pageKey }
                capturedPages.append(CaptureDebugPage(
                    pageKey: pageKey,
                    assetId: assetId,
                    capturedAt: ISO8601DateFormatter().string(from: Date())
                ))
                publishCaptureStatus("Captured \(pageKey)")
            case .rejected:
                publishCaptureStatus("Capture failed — upload was rejected")
            }
        }
    }

    func exportCurrentPageCapture(
        includeText: Bool,
        includeImagesAndMedia: Bool,
        includeOtherStructuralNodes: Bool
    ) async -> String? {
        guard isDebugBuild, isCaptureSupported, !captureInFlight,
              let pageKey = _currentScreen, !pageKey.isEmpty,
              let window = ViewControllerUtil.keyWindow(),
              let source = UIKitCaptureFacts.sourceFrame(window: window)
        else { return nil }

        captureInFlight = true
        let wasVisible = debugOverlayController.isVisible
        debugOverlayController.setVisible(false)
        defer {
            captureInFlight = false
            if wasVisible { debugOverlayController.setVisible(true) }
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        let profile = CaptureProfile(
            includeText: includeText,
            includeImagesAndMedia: includeImagesAndMedia,
            includeOtherStructuralNodes: includeOtherStructuralNodes
        )
        let walk = await CaptureEvidenceWalker.walk(
            root: UIKitCaptureNode(view: window, rootView: window),
            windowBoundsPx: source.windowBoundsPx,
            profile: profile
        )
        guard case let .succeeded(nodes, traversal) = walk else { return nil }

        let appInfo = Bundle.main.infoDictionary ?? [:]
        let envelope = PageCaptureEnvelopeV1(
            pageKey: pageKey,
            binding: "reactNative",
            devicePlatform: .ios,
            source: source,
            screenshotSizePx: CaptureSize(
                width: Int((window.bounds.width * window.screen.scale).rounded()),
                height: Int((window.bounds.height * window.screen.scale).rounded())
            ),
            appVersion: appInfo["CFBundleShortVersionString"] as? String ?? "",
            appBuildNumber: appInfo["CFBundleVersion"] as? String ?? "",
            sdkVersion: DigiaSdkVersion.value,
            profile: profile,
            traversal: traversal,
            nodes: nodes
        )
        guard let data = CaptureEnvelopeSerializer.jsonBytes(envelope) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func clearCaptureStatus() {
        captureStatusMessage = nil
    }

    private func publishCaptureStatus(_ message: String) {
        captureStatusMessage = message
    }

    private static func renderPNG(window: UIWindow) -> Data? {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        var rendered = false
        let image = renderer.image { _ in
            rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return rendered ? image.pngData() : nil
    }

    /// Revalidates active overlays on every host screen update. Inline campaigns are
    /// intentionally excluded because their placement lifecycle remains owned by the host view.
    private func dismissActiveCampaignsNotTargetingCurrentScreen() {
        if let nudge = controller.activeNudge {
            dismissForScreenChangeIfNeeded(
                campaignKey: nudge.payload.campaignKey,
                campaignType: "nudge",
                campaign: campaignStore.find(nudge.payload.campaignKey),
                dismiss: { markNudgeDismissed() }
            )
        }

        if let survey = surveyOrchestrator.state {
            dismissForScreenChangeIfNeeded(
                campaignKey: survey.payload.campaignKey,
                campaignType: "survey",
                campaign: campaignStore.find(survey.payload.campaignKey),
                dismiss: { markSurveyDismissed() }
            )
        }

        if let guide = guideOrchestrator.state {
            if let pageKey = guide.steps.first?.target.anchorlessTarget?.pageKey,
               pageKey != _currentScreen {
                liveTestContexts[guide.payload.cepCampaignId]?.reportFailed(
                    .noMatchingScreen,
                    message: "screen changed before the Guide was shown"
                )
                dismissGuide()
            } else {
                dismissForScreenChangeIfNeeded(
                    campaignKey: guide.campaign.campaignKey,
                    campaignType: "guide",
                    campaign: guide.campaign,
                    dismiss: {
                        self.liveTestContexts[guide.payload.cepCampaignId]?.reportFailed(
                            .noMatchingScreen,
                            message: "screen changed before the Guide was shown"
                        )
                        self.dismissGuide()
                    }
                )
            }
        }

        if let guide = activeExternalGuide {
            dismissForScreenChangeIfNeeded(
                campaignKey: guide.campaign.campaignKey,
                campaignType: "guide",
                campaign: guide.campaign
            ) {
                activeExternalGuide = nil
                if isLiveTestCepId(guide.payload.cepCampaignId) {
                    onLiveTestGuideCancelRequest?(guide.payload.cepCampaignId)
                    liveTestContexts[guide.payload.cepCampaignId]?.reportFailed(
                        .noMatchingScreen,
                        message: "screen changed before the Guide was shown"
                    )
                } else {
                    events.toCep(.dismissed, payload: guide.payload)
                }
            }
        }

        // Not the shared `dismissForScreenChangeIfNeeded` helper above — a floater
        // is bound to the *exact* screen it appeared on, not `targetScreenNames`
        // generally, so it has its own `onScreenChanged` (see that method's kdoc).
        floaterOrchestrator.onScreenChanged(_currentScreen ?? "")
        // Same contract for the story floater: it belongs to the screen it opened on.
        floaterStoryOrchestrator.onScreenChanged(_currentScreen ?? "")
    }

    private func dismissForScreenChangeIfNeeded(
        campaignKey: String,
        campaignType: String,
        campaign: CampaignModel?,
        dismiss: () -> Void
    ) {
        let targetScreenNames = campaign?.targetScreenNames
        let isMismatch =
            targetScreenNames == nil
            || (!(targetScreenNames?.isEmpty ?? true)
                && !(targetScreenNames?.contains(_currentScreen ?? "") ?? false))
        guard isMismatch else { return }

        let targets = targetScreenNames.map { String(describing: $0) } ?? "<missing>"
        DigiaLog.warning(
            "[SDKInstance] Campaign dropped — screen changed: "
                + "campaignKey=\(campaignKey) campaignType=\(campaignType) "
                + "currentScreen=\(_currentScreen ?? "<unset>") "
                + "targetScreenNames=\(targets) reason=screen_changed"
        )
        dismiss()
    }

    /// Called the first time an anchor key registers (`AnchorRegistry.register`).
    func recordAnchorSeen(_ anchorKey: String) {
        componentRegistry.recordAnchor(anchorKey, screenName: _currentScreen)
    }

    /// Called the first time a placement key appears (`DigiaSlot`).
    func recordSlotSeen(_ placementKey: String) {
        componentRegistry.recordSlot(placementKey, screenName: _currentScreen)
    }

    /// Exposes the recording toggle + control surface to `DigiaDebugSettingsView`.
    func componentRegistrySnapshot() -> ComponentRegistryService {
        componentRegistry
    }

    /// Exposes the live-test connection state to `DigiaDebugSettingsView`.
    func liveTestServiceSnapshot() -> LiveTestService {
        liveTestService
    }

    /// Exposes bubble visibility to `RecordingBadgeView` and `DigiaDebugSettingsView`.
    func debugOverlayControllerSnapshot() -> DigiaDebugOverlayController {
        debugOverlayController
    }

    func registerPlaceholderForSlot(propertyID: String) -> Int? {
        activePlugin?.registerPlaceholder(propertyID: propertyID)
    }

    func deregisterPlaceholderForSlot(_ id: Int) {
        activePlugin?.deregisterPlaceholder(id)
    }

    func onHostMounted() {
        isHostMounted = true
    }

    func onHostUnmounted() {
        isHostMounted = false
    }

    func onCampaignTriggered(_ payload: CEPTriggerPayload) -> Bool {
        lastCampaignDropReason = nil
        logVerbose(
            "onCampaignTriggered cepCampaignId='\(payload.cepCampaignId)' "
                + "campaignKey='\(payload.campaignKey)'")
        // Route purely by the campaignKey resolved from the store (mirrors
        // Android) — fall back to cepCampaignId when no campaignKey was supplied.
        let key = payload.campaignKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedKey =
            key.isEmpty
            ? payload.cepCampaignId.trimmingCharacters(in: .whitespacesAndNewlines)
            : key
        guard !resolvedKey.isEmpty, campaignStore.find(resolvedKey) != nil else {
            lastCampaignDropReason = "no native campaign for key '\(resolvedKey)'"
            logError(
                "campaign dropped — no campaign for key '\(resolvedKey)' knownKeys=[\(campaignStore.keys.joined(separator: ", "))]"
            )
            return false
        }
        return routeByCampaignKey(resolvedKey, payload: payload)
    }

    private func routeByCampaignKey(_ key: String, payload: CEPTriggerPayload) -> Bool {
        guard let campaign = campaignStore.find(key) else {
            logError("routeByCampaignKey: no campaign found for key '\(key)'")
            return false
        }
        return route(
            campaign, payload: payload,
            context: OrganicRoutingContext(frequencyManager: frequencyManager, events: events))
    }

    /// Abstracts the two points where `route` otherwise diverges between an
    /// organic trigger and a live test — frequency capping, and how a
    /// routed/dropped campaign reports back — so the routing switch itself never
    /// branches on which one this is.
    @MainActor
    private protocol RoutingContext {
        var liveTestGuideRequest: LiveTestGuideRenderRequest? { get }
        func isFrequencyCapped(campaignKey: String, policy: FrequencyPolicy?) -> Bool
        func onInlineRouted(payload: CEPTriggerPayload)
        func onDropped(_ code: LiveTestFailureCode, message: String)
    }

    @MainActor
    private struct OrganicRoutingContext: RoutingContext {
        let liveTestGuideRequest: LiveTestGuideRenderRequest? = nil
        let frequencyManager: FrequencyManager?
        let events: EngageEventEmitter

        func isFrequencyCapped(campaignKey: String, policy: FrequencyPolicy?) -> Bool {
            guard
                let reason = frequencyManager?.blockReason(campaignKey: campaignKey, policy: policy)
            else {
                return false
            }
            DigiaLog.warning(
                "[SDKInstance] Campaign dropped — frequency capped: key=\(campaignKey) reason=\(reason) policy=\(String(describing: policy))"
            )
            return true
        }

        func onInlineRouted(payload: CEPTriggerPayload) {
            // syncTemplate semantics: CEP considers an inline slot shown and done
            // the moment it is delivered. Digia's impression fires only when the
            // slot first renders (see reportSlotFirstRender).
            events.toCep(.impressed, payload: payload)
            events.toCep(.dismissed, payload: payload)
        }

        func onDropped(_ code: LiveTestFailureCode, message: String) {
            // Nothing to report organically — the caller already logged why.
        }
    }

    /// Seconds a live-test inline campaign waits for its target slot to mount
    /// before giving up. Inline routing always "succeeds" immediately, so this
    /// stands in for the synchronous anchor check guide gets.
    private static let liveTestNoMatchTimeoutSeconds: UInt64 = 5

    @MainActor
    private final class LiveTestRoutingContext: RoutingContext {
        let liveTestGuideRequest: LiveTestGuideRenderRequest?
        private let testContext: LiveTestContext

        init(
            testContext: LiveTestContext,
            liveTestGuideRequest: LiveTestGuideRenderRequest? = nil
        ) {
            self.testContext = testContext
            self.liveTestGuideRequest = liveTestGuideRequest
        }

        func isFrequencyCapped(campaignKey: String, policy: FrequencyPolicy?) -> Bool { false }

        func onInlineRouted(payload: CEPTriggerPayload) {
            // No synchronous way to know a matching DigiaSlot exists — bound it
            // with a timeout; reportSlotFirstRender's shown ACK wins the race if
            // a slot renders first (LiveTestContext is idempotent).
            let testContext = testContext
            let seconds = SDKInstance.liveTestNoMatchTimeoutSeconds
            Task {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                testContext.reportFailed(
                    .noMatchingScreen,
                    message: "no matching slot for this campaign mounted within \(seconds)s"
                )
            }
        }

        func onDropped(_ code: LiveTestFailureCode, message: String) {
            testContext.reportFailed(code, message: message)
        }
    }

    /// Whether a nudge, survey, or an *expanded* floater currently occupies the
    /// screen modally. A *collapsed* floater is deliberately not modal — it is a
    /// third, independent lane that never blocks and is never blocked by the
    /// others (`ai_docs/pip-campaign-design.md` §3.2) — so this only starts
    /// returning true once the floater expands, at which point it behaves like
    /// every other full-screen surface. Gates only floater's own start (mirrors
    /// Android's `DigiaInstance.isModalCampaignActive`, used identically at its
    /// one call site); nudge/survey routing is intentionally left unchanged.
    private func isModalCampaignActive() -> Bool {
        controller.activeNudge != nil || surveyOrchestrator.state != nil
            || floaterOrchestrator.surface == .expanded
            // An open story is the story floater's expanded state: it fills the
            // screen, so from here on it behaves like every other modal surface.
            || floaterStoryOrchestrator.storyOverlayActive
    }

    private func route(
        _ campaign: CampaignModel,
        payload: CEPTriggerPayload,
        context: RoutingContext
    ) -> Bool {
        let key = campaign.campaignKey
        if !campaign.targetScreenNames.isEmpty
            && !campaign.targetScreenNames.contains(_currentScreen ?? "")
        {
            lastCampaignDropReason =
                "screen not targeted: currentScreen=\(_currentScreen ?? "<unset>") targetScreenNames=\(campaign.targetScreenNames)"
            context.onDropped(
                .noMatchingScreen,
                message:
                    "currentScreen=\(_currentScreen ?? "<unset>") targetScreenNames=\(campaign.targetScreenNames)"
            )
            DigiaLog.warning(
                "[SDKInstance] Campaign dropped — screen not targeted: "
                    + "campaignKey=\(key) currentScreen=\(_currentScreen ?? "<unset>") "
                    + "targetScreenNames=\(campaign.targetScreenNames)"
            )
            context.onDropped(.noMatchingScreen, message: "screen not targeted")
            return false
        }

        logVerbose("routeByCampaignKey key='\(key)' type='\(campaign.campaignType)'")
        switch campaign.config {
        case .inline(let cfg):
            logVerbose(
                "routeByCampaignKey INLINE slotKey='\(cfg.slotKey)' items=\(cfg.items.count)")
            inlineController.setCarouselConfig(cfg.slotKey, config: cfg)
            inlineController.setCampaign(cfg.slotKey, payload: payload)
            context.onInlineRouted(payload: payload)
            return true
        case .banner(let cfg):
            inlineController.setBannerConfig(cfg.slotKey, config: cfg)
            inlineController.setCampaign(cfg.slotKey, payload: payload)
            events.toCep(.impressed, payload: payload)
            events.toCep(.dismissed, payload: payload)
            return true
        case .inlineCanvas(let cfg):
            logVerbose("routeByCampaignKey INLINE CANVAS slotKey='\(cfg.slotKey)'")
            inlineController.setCanvasConfig(cfg.slotKey, config: cfg)
            inlineController.setCampaign(cfg.slotKey, payload: payload)
            context.onInlineRouted(payload: payload)
            return true
        case .story(let cfg):
            inlineController.setStoryConfig(cfg.slotKey, config: cfg)
            inlineController.setCampaign(cfg.slotKey, payload: payload)
            context.onInlineRouted(payload: payload)
            return true
        case .guide(let guideConfig):
            if !guideConfig.isAnchorless,
               config?.wrapperBinding == "react_native",
               guideRenderer == .reactNative,
               guideConfig.steps.allSatisfy({ $0.widgetConfig.layoutMode != "canvas" })
            {
                if context.liveTestGuideRequest != nil {
                    guard onLiveTestGuideRenderRequest != nil else {
                        let message = "React Native live-test guide renderer is not registered"
                        lastCampaignDropReason = message
                        context.onDropped(.renderError, message: message)
                        return false
                    }
                    activeExternalGuide = ExternalGuide(campaign: campaign, payload: payload)
                    return true
                }
                guard let renderViaJs = onGuideRenderRequest else {
                    let message = "React Native guide renderer is not registered"
                    lastCampaignDropReason = message
                    context.onDropped(.renderError, message: message)
                    logNativeGuideStage("route", "result=dropped reason=js_renderer_missing campaign_key=\(key)")
                    return false
                }
                if context.isFrequencyCapped(campaignKey: key, policy: campaign.frequency) {
                    lastCampaignDropReason = "frequency capped"
                    return false
                }
                activeExternalGuide = ExternalGuide(campaign: campaign, payload: payload)
                renderViaJs(payload)
                return true
            }
            if context.isFrequencyCapped(campaignKey: key, policy: campaign.frequency) {
                lastCampaignDropReason = "frequency capped"
                logNativeGuideStage("route", "result=dropped reason=frequency_capped campaign_key=\(key)")
                return false
            }
            if guideOrchestrator.state != nil, !guideConfig.steps.isEmpty { dismissGuide() }
            guard guideOrchestrator.start(campaign, payload: payload) else {
                lastCampaignDropReason = "another guide is already on screen"
                context.onDropped(.renderError, message: "another guide is already on screen")
                logNativeGuideStage("route", "result=dropped reason=guide_active campaign_key=\(key)")
                return false
            }
            guideCompletionFired = false
            logNativeGuideStage("route", "result=accepted campaign_key=\(key)")
            return true
        case .nudge(let nudgeConfig):
            if context.isFrequencyCapped(campaignKey: key, policy: campaign.frequency) {
                lastCampaignDropReason = "frequency capped"
                return false
            }
            // Resolve variable context: dashboard schemas define type + fallback;
            // CEP trigger variables win over fallbacks (D3′).
            let variableContext = buildVariableContext(
                schemas: nudgeConfig.variableSchemas,
                cepVars: payload.variables
            )
            controller.showNudge(
                DigiaNudgePresentation(
                    config: nudgeConfig,
                    payload: payload,
                    variables: variableContext.values.isEmpty && variableContext.types.isEmpty
                        ? nil : variableContext
                ))
            return true
        case .survey(let cfg):
            if context.isFrequencyCapped(campaignKey: key, policy: campaign.frequency) {
                lastCampaignDropReason = "frequency capped"
                return false
            }
            let started = surveyOrchestrator.start(payload: payload, config: cfg)
            if !started {
                lastCampaignDropReason = "another survey is already on screen"
                logVerbose("survey campaign dropped: another survey is on screen: \(key)")
                context.onDropped(.renderError, message: "another survey is already on screen")
            }
            return started
        // Both floater subtypes route through the same gate — a collapsed window of
        // either kind is the same third, non-blocking lane.
        case .floater, .floaterStory:
            if context.isFrequencyCapped(campaignKey: key, policy: campaign.frequency) {
                lastCampaignDropReason = "frequency capped"
                return false
            }
            // A collapsed floater is a third, independent lane (see
            // `isModalCampaignActive`'s kdoc) — it does not compete with
            // nudge/survey. But it must not *start* while one of them is already
            // the modal surface, since it would otherwise float on top of a
            // nudge/survey that is supposed to own the screen exclusively.
            if isModalCampaignActive() {
                lastCampaignDropReason = "a nudge, survey, or expanded floater is already on screen"
                logVerbose(
                    "floater campaign dropped: a nudge, survey, or expanded floater is already modal: \(key)"
                )
                context.onDropped(
                    .renderError,
                    message: "a nudge, survey, or expanded floater is already on screen")
                return false
            }
            // One floater at a time across BOTH subtypes. Each orchestrator only knows
            // about its own showing, so without this a PiP and a story window could
            // float over each other — two draggable boxes competing for one corner.
            let wantsStory = campaign.floaterStoryConfig != nil
            let otherLaneBusy =
                wantsStory ? floaterOrchestrator.state != nil : floaterStoryOrchestrator.state != nil
            if otherLaneBusy {
                lastCampaignDropReason = "another floater is already on screen"
                logVerbose("floater campaign dropped: another floater is on screen: \(key)")
                context.onDropped(.renderError, message: "another floater is already on screen")
                return false
            }
            // Two template shapes under one campaign type, each with its own
            // orchestrator — see `CampaignConfigModel.floaterStory`.
            if wantsStory {
                let started = floaterStoryOrchestrator.start(
                    campaign, payload: payload, screenName: _currentScreen)
                if !started {
                    lastCampaignDropReason =
                        floaterStoryOrchestrator.lastStartFailureReason
                        ?? "story floater start failed"
                    DigiaLog.warning(
                        "[SDKInstance] Story floater campaign skipped: key=\(key) reason=\(floaterStoryOrchestrator.lastStartFailureReason ?? "unknown")"
                    )
                    context.onDropped(
                        .renderError, message: "another floater is already on screen")
                }
                return started
            }
            let started = floaterOrchestrator.start(
                campaign, payload: payload, screenName: _currentScreen)
            if !started {
                lastCampaignDropReason =
                    floaterOrchestrator.lastStartFailureReason ?? "floater start failed"
                DigiaLog.warning(
                    "[SDKInstance] Floater campaign skipped: key=\(key) currentScreen=\(_currentScreen ?? "<unset>") reason=\(floaterOrchestrator.lastStartFailureReason ?? "unknown")"
                )
                context.onDropped(.renderError, message: "another floater is already on screen")
            }
            return started
        }
    }

    /// Handles one `campaign_test` SSE event.
    private func handleLiveTestCampaign(_ invocation: LiveTestInvocation) {
        let reporter = liveTestService.ackReporter
        reporter.postReceived(invocation.testInvocationId)

        guard sdkState == .ready else {
            reporter.postFailed(
                invocation.testInvocationId, code: .renderError,
                message: "SDK not ready (state=\(sdkState))"
            )
            return
        }

        guard let campaignJson = invocation.campaign else {
            reporter.postFailed(
                invocation.testInvocationId, code: .campaignNotFound,
                message: "campaign_test message had no usable campaign object"
            )
            return
        }

        // With the bundle's catalog, exactly as the organic path parses. Parsing
        // a live test against an empty one resolved every design token to nil,
        // so a campaign styled with tokens arrived on the device with no colours
        // and no type — the one place a marketer looks at it before shipping.
        guard let campaign = CampaignModel.fromJson(
            campaignJson,
            designTokens: currentDesignTokens,
            devicePlatform: "ios"
        ) else {
            reporter.postFailed(
                invocation.testInvocationId, code: .templateError,
                message: "campaign object could not be parsed into a renderable campaign"
            )
            return
        }

        let supportsLiveTest: Bool
        switch campaign.config {
        case .guide, .floater, .floaterStory: supportsLiveTest = true
        case .nudge, .survey, .inline, .inlineCanvas: supportsLiveTest = true
        case .banner, .story: supportsLiveTest = false
        }
        guard supportsLiveTest else {
            reporter.postFailed(
                invocation.testInvocationId, code: .templateError,
                message:
                    "campaign type '\(campaign.campaignType)' is not supported for live testing yet"
            )
            return
        }

        if campaign.guideConfig != nil { replaceActiveLiveTestGuide() }

        let coercedVariables = invocation.variables.mapValues { "\($0)" }
        let cepCampaignId = liveTestCepId(invocation.testInvocationId)
        let payload = CEPTriggerPayload(
            cepCampaignId: cepCampaignId,
            campaignKey: campaign.campaignKey,
            cepMetadata: [:],
            variables: coercedVariables
        )

        let guideRequest: LiveTestGuideRenderRequest?
        if let guideConfig = campaign.guideConfig, guideRenderer == .reactNative,
           config?.wrapperBinding == "react_native",
           guideConfig.steps.allSatisfy({ $0.widgetConfig.layoutMode != "canvas" })
        {
            guard let campaignData = try? JSONSerialization.data(withJSONObject: campaignJson),
                  let variablesData = try? JSONSerialization.data(withJSONObject: coercedVariables),
                  let campaignJsonString = String(data: campaignData, encoding: .utf8),
                  let variablesJsonString = String(data: variablesData, encoding: .utf8)
            else {
                reporter.postFailed(
                    invocation.testInvocationId, code: .templateError,
                    message: "live-test Guide payload could not be serialized"
                )
                return
            }
            guideRequest = LiveTestGuideRenderRequest(
                testInvocationId: invocation.testInvocationId,
                cepCampaignId: cepCampaignId,
                campaignJson: campaignJsonString,
                variablesJson: variablesJsonString
            )
        } else {
            guideRequest = nil
        }

        let cleanUpLiveTestState: (Bool) -> Void = { [weak self] shown in
            self?.liveTestContexts.removeValue(forKey: cepCampaignId)
            self?.liveTestCampaigns.removeValue(forKey: cepCampaignId)
            if !shown, self?.activeExternalGuide?.payload.cepCampaignId == cepCampaignId {
                self?.activeExternalGuide = nil
            }
            self?.events.resetImpression(cepCampaignId)
        }

        let testContext = LiveTestContext(
            testInvocationId: invocation.testInvocationId,
            reporter: reporter,
            onTerminal: cleanUpLiveTestState
        )
        liveTestContexts[cepCampaignId] = testContext
        liveTestCampaigns[cepCampaignId] = campaign

        let accepted = route(
            campaign,
            payload: payload,
            context: LiveTestRoutingContext(
                testContext: testContext,
                liveTestGuideRequest: guideRequest
            )
        )
        if !accepted {
            cleanUpLiveTestState(false)
        } else if campaign.guideConfig?.isAnchorless == false {
            verifyFirstLiveTestGuideAnchorAfterLayout(
                campaign: campaign,
                payload: payload,
                testContext: testContext,
                guideRequest: guideRequest
            )
        } else if campaign.guideConfig?.isAnchorless == true {
            let seconds = Self.liveTestNoMatchTimeoutSeconds
            let graceNanoseconds = seconds * 1_000_000_000
            let maxDelayMs = (UInt64.max - graceNanoseconds) / 1_000_000
            let delayMs = min(
                UInt64(max(0, campaign.guideConfig?.steps.first?.delayInMs ?? 0)),
                maxDelayMs
            )
            Task { [weak self] in
                try? await Task.sleep(
                    nanoseconds: delayMs * 1_000_000 + graceNanoseconds)
                guard let self,
                      let context = self.liveTestContexts[cepCampaignId]
                else { return }
                context.reportFailed(
                    .renderError,
                    message: "Anchorless Spotlight host did not render within \(seconds)s"
                )
                if self.guideOrchestrator.state?.payload.cepCampaignId == cepCampaignId {
                    self.guideOrchestrator.dismiss()
                    self.guideCompletionFired = false
                }
            }
        }
    }

    private func verifyFirstLiveTestGuideAnchorAfterLayout(
        campaign: CampaignModel,
        payload: CEPTriggerPayload,
        testContext: LiveTestContext,
        guideRequest: LiveTestGuideRenderRequest?
    ) {
        guard let anchorKey = campaign.guideConfig?.steps.first?.target.anchorKey else { return }
        Task { [weak self] in
            await LiveTestFrameWaiter().wait()
            guard let self else { return }
            let isCurrentGuide = if guideRequest == nil {
                self.guideOrchestrator.state?.payload.cepCampaignId == payload.cepCampaignId
            } else {
                self.activeExternalGuide?.payload.cepCampaignId == payload.cepCampaignId
            }
            guard isCurrentGuide else { return }
            if AnchorRegistry.shared.isRegistered(anchorKey) {
                if case .unavailable(.outsideViewport) = AnchorRegistry.shared.resolution(
                    for: anchorKey
                ) {
                    AnchorRegistry.shared.scrollToVisible(anchorKey)
                }
                if case .available = AnchorRegistry.shared.resolution(for: anchorKey) {
                    if let guideRequest {
                        guard let renderLiveTestViaJs = self.onLiveTestGuideRenderRequest else {
                            self.reportLiveTestGuideFailed(
                                payload.cepCampaignId,
                                code: LiveTestFailureCode.renderError.wireValue,
                                message: "React Native live-test guide renderer is not registered"
                            )
                            return
                        }
                        renderLiveTestViaJs(guideRequest)
                    }
                    return
                }
            }
            testContext.reportFailed(
                .noMatchingScreen,
                message: "anchor '\(anchorKey)' is not on screen"
            )
            self.guideOrchestrator.dismissIfActive(payloadId: payload.cepCampaignId)
            self.guideCompletionFired = false
            if self.activeExternalGuide?.payload.cepCampaignId == payload.cepCampaignId {
                self.activeExternalGuide = nil
            }
        }
    }

    func reportLiveTestGuideShown(_ cepCampaignId: String) {
        liveTestContexts[cepCampaignId]?.reportShown()
    }

    func endLiveTestGuide(_ cepCampaignId: String) {
        if activeExternalGuide?.payload.cepCampaignId == cepCampaignId {
            activeExternalGuide = nil
        }
    }

    private func replaceActiveLiveTestGuide() {
        if let state = guideOrchestrator.state,
           isLiveTestCepId(state.payload.cepCampaignId) {
            liveTestContexts[state.payload.cepCampaignId]?.reportFailed(
                .renderError,
                message: "replaced by a newer live-test invocation"
            )
            guideOrchestrator.dismissIfActive(payloadId: state.payload.cepCampaignId)
            guideCompletionFired = false
        }
        if let guide = activeExternalGuide,
           isLiveTestCepId(guide.payload.cepCampaignId) {
            onLiveTestGuideCancelRequest?(guide.payload.cepCampaignId)
            liveTestContexts[guide.payload.cepCampaignId]?.reportFailed(
                .renderError,
                message: "replaced by a newer live-test invocation"
            )
            activeExternalGuide = nil
        }
    }

    func reportLiveTestGuideFailed(
        _ cepCampaignId: String,
        code: String,
        message: String?
    ) {
        liveTestContexts[cepCampaignId]?.reportFailed(
            LiveTestFailureCode(rawValue: code) ?? .renderError,
            message: message
        )
        if activeExternalGuide?.payload.cepCampaignId == cepCampaignId {
            activeExternalGuide = nil
        }
    }

    func onCampaignInvalidated(_ campaignID: String) {
        if activeExternalGuide?.payload.cepCampaignId == campaignID {
            activeExternalGuide = nil
        }
        if controller.activeNudge?.payload.cepCampaignId == campaignID {
            controller.dismissNudge()
        }
        if surveyOrchestrator.state?.payload.cepCampaignId == campaignID {
            surveyOrchestrator.dismiss()
        }
        if floaterStoryOrchestrator.state?.payload.cepCampaignId == campaignID {
            floaterStoryOrchestrator.dismiss(.invalidated)
        }
        if floaterOrchestrator.state?.payload.cepCampaignId == campaignID {
            floaterOrchestrator.dismiss(.invalidated)
        }
        inlineController.removeCampaign(campaignID)
        guideOrchestrator.dismissIfActive(payloadId: campaignID)
        // Forget the impression mark so a re-trigger impresses to Digia afresh.
        events.resetImpression(campaignID)
    }

    // MARK: - Survey lifecycle
    //
    // CEP plugin sees: Impressed (started), Dismissed (every teardown — closed
    // without finishing AND completed; all routed through markSurveyDismissed).
    // Internal analytics (TBD) sees: Answered, Completed.
    // Surveys are started from `routeByCampaignKey` once a `survey` campaign is
    // resolved from the store, so there is no separate `startSurvey` entry point.

    /// Fired once when the survey first becomes visible (treated as an impression).
    func reportSurveyStarted() {
        guard let state = surveyOrchestrator.state else { return }
        let config = state.config
        dwellTracker.markViewed(state.payload.cepCampaignId)
        // Bump frequency on "Digia Experience Viewed" (the moment the survey shows).
        if !isLiveTestCepId(state.payload.cepCampaignId) {
            let campaignKey = state.payload.campaignKey
            frequencyManager?.recordShow(campaignKey, campaignStore.find(campaignKey)?.frequency)
        }
        events.toBoth(
            .impressed,
            SurveyEvent.Viewed(
                itemTotal: config.questionCount,
                hasWelcome: config.hasWelcome,
                hasThanks: config.hasThanks,
                hasBranching: config.hasBranching,
                screenName: _currentScreen
            ),
            payload: state.payload
        )
    }

    /// The survey's start engagement — fired once per showing. When a welcome
    /// screen is present this is its "Start" CTA tap; when there's no welcome
    /// screen it is raised on the first continue (see `reportSurveyAnswered` /
    /// `reportSurveyQuestionSkipped`).
    func reportSurveyWelcomeStart() {
        guard let state = surveyOrchestrator.state else { return }
        if welcomeStartToken == state.token { return }
        welcomeStartToken = state.token
        events.toDigia(SurveyEvent.Clicked(elementId: "welcome_start"), payload: state.payload)
    }

    /// When no welcome screen exists, the first continue is the start engagement.
    private func ensureWelcomeStartIfNoWelcome(_ state: ActiveSurveyState) {
        if !state.config.hasWelcome { reportSurveyWelcomeStart() }
    }

    /// A survey question became visible. `itemIndex` is its 1-based shown position.
    func reportSurveyQuestionViewed(nodeId: String, itemIndex: Int) {
        guard let state = surveyOrchestrator.state else { return }
        guard let block = state.config.blockForNode(nodeId) else { return }
        if block.type.isContent { return }
        questionViewedAt[Self.questionKey(token: state.token, nodeId: nodeId)] = Date()
        let typeWire = block.type.rawValue
        events.toDigia(
            SurveyEvent.QuestionViewed(
                questionId: nodeId,
                questionTitle: Self.questionTitle(block),
                questionType: typeWire,
                itemIndex: itemIndex,
                itemTotal: state.config.questionCount,
                blockType: typeWire,
                blockId: block.id,
                isRequired: block.required
            ),
            payload: state.payload
        )
    }

    /// An eligible optional question was skipped (advanced without an answer).
    func reportSurveyQuestionSkipped(nodeId: String, itemIndex: Int) {
        guard let state = surveyOrchestrator.state else { return }
        ensureWelcomeStartIfNoWelcome(state)
        guard let block = state.config.blockForNode(nodeId) else { return }
        questionViewedAt.removeValue(forKey: Self.questionKey(token: state.token, nodeId: nodeId))
        events.toDigia(
            SurveyEvent.QuestionSkipped(
                questionId: nodeId,
                questionTitle: Self.questionTitle(block),
                itemIndex: itemIndex,
                blockType: block.type.rawValue,
                blockId: block.id),
            payload: state.payload
        )
    }

    /// Fired each time the user answers a question (one event per answered question).
    func reportSurveyAnswered(stepId: String, answer: [String: JSONValue]) {
        guard let state = surveyOrchestrator.state else { return }
        ensureWelcomeStartIfNoWelcome(state)
        let block = state.config.blockForNode(stepId)
        let values = Self.stringArray(answer["values"])
        let comment = Self.stringValue(answer["comment"])
        let viewedKey = Self.questionKey(token: state.token, nodeId: stepId)
        let timeToAnswerMs: Int64? = questionViewedAt[viewedKey].map {
            Int64(Date().timeIntervalSince($0) * 1000)
        }
        questionViewedAt.removeValue(forKey: viewedKey)
        let scaleBounds = block.flatMap(Self.scaleBounds)
        events.toDigia(
            SurveyEvent.QuestionAnswered(
                questionId: stepId,
                questionTitle: block.flatMap(Self.questionTitle),
                questionType: block?.type.rawValue,
                answerValue: values.first,
                answerText: comment ?? (values.isEmpty ? nil : values.joined(separator: ", ")),
                blockType: block?.type.rawValue,
                blockId: block?.id,
                answerLabel: block.flatMap { Self.answerLabel(block: $0, values: values) },
                answerOptions: values.count > 1 ? values : nil,
                scaleMin: scaleBounds?.min,
                scaleMax: scaleBounds?.max,
                timeToAnswerMs: timeToAnswerMs,
                answer: Self.foundation(answer)
            ),
            payload: state.payload
        )
    }

    func markSurveyCompleted(response: [String: JSONValue], answers: [String: SurveyAnswer] = [:]) {
        reportSurveyCompleted(response: response, answers: answers)
        markSurveyDismissed()
    }

    func reportSurveyCompleted(response: [String: JSONValue], answers: [String: SurveyAnswer] = [:])
    {
        guard let state = surveyOrchestrator.state else {
            logVerbose("reportSurveyCompleted: skip — no active survey state")
            return
        }
        if completedSurveyToken == state.token {
            logVerbose("reportSurveyCompleted: skip — already reported for token=\(state.token)")
            return
        }
        completedSurveyToken = state.token
        let isLiveTest = isLiveTestCepId(state.payload.cepCampaignId)

        // Permanent stop on "Digia Experience Completed" when stopOn is set.
        if !isLiveTest {
            let campaignKey = state.payload.campaignKey
            frequencyManager?.recordCompleted(
                campaignKey, campaignStore.find(campaignKey)?.frequency)
        }

        // Analytics "Completed" fires once per survey showing, regardless of
        // whether a submission is reported to the backend below.
        let answeredCount = answers.isEmpty ? response.count : answers.count
        events.toDigia(
            SurveyEvent.Completed(
                itemTotal: state.config.questionCount,
                answeredCount: answeredCount,
                timeToCompleteMs: Int64(Date().timeIntervalSince(state.startedAt) * 1000),
                response: Self.foundation(response)
            ),
            payload: state.payload
        )

        if answers.isEmpty || isLiveTest {
            logVerbose(
                "reportSurveyCompleted: skip submission — answers is empty or this is a live test")
            return
        }
        guard let config = self.config else {
            logVerbose(
                "reportSurveyCompleted: skip submission — SDK not initialized (config is nil)")
            return
        }
        guard let campaignId = campaignStore.find(state.payload.campaignKey)?.id else {
            logVerbose(
                "reportSurveyCompleted: skip submission — no campaign for key '\(state.payload.campaignKey)'"
            )
            return
        }
        logVerbose(
            "reportSurveyCompleted: submitting campaignId=\(campaignId) answers=\(answers.count)")
        SurveySubmissionReporter(config: config).report(
            campaignId: campaignId,
            survey: state.config,
            answers: answers,
            startedAt: state.startedAt,
            userId: analyticsService?.userId
        )
    }

    func dismissCompletedSurvey() {
        markSurveyDismissed()
    }

    func markSurveyDismissed(abandonedAtItem: Int? = nil, answeredCount: Int? = nil) {
        guard let state = surveyOrchestrator.state else { return }
        surveyOrchestrator.dismiss()
        events.toBoth(
            .dismissed,
            SurveyEvent.Dismissed(
                abandonedAtItem: abandonedAtItem,
                itemTotal: state.config.questionCount,
                answeredCount: answeredCount,
                dwellMs: dwellTracker.consumeDwellMs(state.payload.cepCampaignId)
            ),
            payload: state.payload
        )
        clearQuestionViewedAt(token: state.token)
    }

    private func clearQuestionViewedAt(token: Int64) {
        let prefix = "\(token):"
        questionViewedAt = questionViewedAt.filter { !$0.key.hasPrefix(prefix) }
    }

    func markInitializedForTesting(with config: DigiaConfig) {
        self.config = config
        hostActionExecutor.configure(config.actionHandlers)
    }

    func setCampaignsForTesting(_ campaigns: [CampaignModel]) {
        campaignStore.populate(campaigns)
        sdkState = .ready
    }

    func setUserId(_ userId: String) {
        analyticsService?.setUserId(userId)
    }

    func clearUserId() {
        analyticsService?.clearUserId()
    }

    /// Removes inline content (carousel/story/payload) for each key in `placementKeys`.
    func clearInlineContent(_ placementKeys: [String]) {
        for key in placementKeys {
            inlineController.dismissCampaign(key)
        }
    }

    /// Clears inline content (carousel/story/payload) across every placement.
    func clearAllInlineContent() {
        inlineController.clear()
    }

    // MARK: - Nudge lifecycle
    //
    // Impression and Dismissed go to both CEP and Digia analytics (toBoth); a
    // CTA Click is a Digia-only engagement signal (toDigia), matching
    // Android's NudgeNodeRenderer.

    func reportNudgeImpression() {
        guard let nudge = controller.activeNudge else { return }
        dwellTracker.markViewed(nudge.payload.cepCampaignId)
        // Bump frequency on "Digia Experience Viewed" (the moment the nudge shows).
        if !isLiveTestCepId(nudge.payload.cepCampaignId) {
            let campaignKey = nudge.payload.campaignKey
            frequencyManager?.recordShow(campaignKey, campaignStore.find(campaignKey)?.frequency)
        }
        events.toBoth(
            .impressed,
            NudgeEvent.Viewed(
                displayStyle: nudge.config.surface.displayType.displayStyle,
                screenName: _currentScreen
            ),
            payload: nudge.payload
        )
    }

    func emitNudgeClick(
        elementId: String? = nil,
        ctaLabel: String? = nil,
        actionType: String? = nil,
        actionUrl: String? = nil,
        ctaRole: String? = nil
    ) {
        guard let payload = controller.activeNudge?.payload else { return }
        events.toDigia(
            NudgeEvent.Clicked(
                elementId: elementId,
                ctaLabel: ctaLabel,
                actionType: actionType,
                actionUrl: actionUrl,
                ctaRole: ctaRole,
                // ms since the nudge was viewed (peek — the nudge is still open).
                timeToActionMs: dwellTracker.elapsedMs(payload.cepCampaignId)
            ),
            payload: payload
        )
    }

    /// An element on an inline canvas was tapped.
    ///
    /// Reported through the nudge conversion events rather than an inline item
    /// funnel: a canvas has no items to walk, and it converts on a widget's
    /// action exactly as a nudge does. The dashboard reads the same `nudge`
    /// block for both, so the two stay consistent by construction.
    func emitInlineCanvasClick(
        payload: CEPTriggerPayload,
        elementId: String? = nil,
        ctaLabel: String? = nil,
        actionType: String? = nil,
        actionUrl: String? = nil,
        ctaRole: String? = nil
    ) {
        events.toDigia(
            NudgeEvent.Clicked(
                elementId: elementId,
                ctaLabel: ctaLabel,
                actionType: actionType,
                actionUrl: actionUrl,
                ctaRole: ctaRole,
                timeToActionMs: dwellTracker.elapsedMs(payload.cepCampaignId)
            ),
            payload: payload
        )
    }

    /// The author's Hide action removed an inline canvas from its slot.
    ///
    /// Bypasses the stickiness that keeps inline campaigns alive across
    /// navigation: an author who put a close control on the card is asking for
    /// exactly the opposite.
    func dismissInlineCanvas(slotKey: String, payload: CEPTriggerPayload) {
        inlineController.dismissCampaign(slotKey)
        events.toBoth(
            .dismissed,
            NudgeEvent.Dismissed(dwellMs: dwellTracker.consumeDwellMs(payload.cepCampaignId)),
            payload: payload
        )
    }

    func markNudgeDismissed() {
        guard let nudge = controller.activeNudge else { return }
        controller.dismissNudge()
        events.toBoth(
            .dismissed,
            NudgeEvent.Dismissed(dwellMs: dwellTracker.consumeDwellMs(nudge.payload.cepCampaignId)),
            payload: nudge.payload
        )
    }

    // MARK: - Floater lifecycle
    //
    // Impression, Dismissed, and Completed go to both CEP and Digia analytics —
    // except Completed, which has no CEP case (`DigiaExperienceEvent` has no
    // `.completed`, matching how `reportSurveyCompleted` also only calls
    // `toDigia`). Step/chrome/CTA signals (StepViewed/StepDismissed/Clicked/
    // StepClicked) are Digia-only engagement signals (toDigia), same convention
    // as nudge's CTA click above. Called from `FloaterOrchestrator`'s
    // constructor-injected callbacks (state/metrics are the values *handed to*
    // them, never re-read from `floaterOrchestrator.state`, which is about to be
    // nulled by the time `onDismissed` runs) or directly from `FloaterSessionView`
    // for chrome taps.

    private func reportFloaterImpression(_ state: ActiveFloaterState) {
        dwellTracker.markViewed(state.payload.cepCampaignId)
        if !isLiveTestCepId(state.payload.cepCampaignId) {
            let campaignKey = state.payload.campaignKey
            frequencyManager?.recordShow(campaignKey, campaignStore.find(campaignKey)?.frequency)
        }
        events.toBoth(
            .impressed, FloaterEvent.Viewed(screenName: _currentScreen), payload: state.payload)
    }

    /// SDK chrome click: expand, collapse, mute/unmute, play/pause. **Never** the
    /// × — that routes straight to `dismissFloater`/`endFloaterExpanded` with no
    /// Clicked report (see `FloaterEvent.Clicked`'s kdoc; this exact bug already
    /// drove dismissal rate to a permanent 0% once in the Flutter build).
    /// `pipState` is derived here from the live surface, not caller-supplied, so
    /// it can never go stale relative to what actually happened.
    func reportFloaterClicked(elementId: String, actionType: String, ctaRole: String) {
        guard let state = floaterOrchestrator.state else { return }
        events.toDigia(
            FloaterEvent.Clicked(
                elementId: elementId, actionType: actionType,
                pipState: floaterOrchestrator.surface == .expanded ? "expanded" : "collapsed",
                ctaRole: ctaRole,
                timeToActionMs: dwellTracker.elapsedMs(state.payload.cepCampaignId)
            ),
            payload: state.payload
        )
    }

    /// An authored CTA tapped inside the expanded content — the real conversion, as
    /// opposed to `reportFloaterClicked`'s SDK chrome. Called from
    /// `performFloaterCanvasAction` (`floater_overlay_view.swift`), the `onAction`
    /// callback `FloaterExpandedContentView` hands to `CampaignCanvasView`.
    ///
    /// No `ctaRole` parameter, unlike `reportFloaterClicked` — every authored CTA here
    /// is a genuine conversion with no chrome/content ambiguity, so `FloaterEvent
    /// .StepClicked`'s own default (`"primary"`) applies; mirrors Android's identical
    /// `DigiaInstance.reportFloaterStepClicked` signature.
    func reportFloaterStepClicked(
        elementId: String, ctaLabel: String, actionType: String?, actionUrl: String?
    ) {
        guard let state = floaterOrchestrator.state else { return }
        events.toDigia(
            FloaterEvent.StepClicked(
                elementId: elementId, ctaLabel: ctaLabel, actionType: actionType,
                actionUrl: actionUrl,
                timeToActionMs: dwellTracker.elapsedMs(state.payload.cepCampaignId)
            ),
            payload: state.payload
        )
    }

    private func emitFloaterStepViewed(_ state: ActiveFloaterState) {
        events.toDigia(FloaterEvent.StepViewed(), payload: state.payload)
    }

    private func emitFloaterStepDismissed(_ state: ActiveFloaterState) {
        events.toDigia(FloaterEvent.StepDismissed(), payload: state.payload)
    }

    private func emitFloaterDismissed(
        _ state: ActiveFloaterState, _ reason: FloaterDismissReason, _ metrics: FloaterMetrics
    ) {
        events.toBoth(
            .dismissed,
            FloaterEvent.Dismissed(
                dismissReason: reason.wire,
                dwellMs: dwellTracker.consumeDwellMs(state.payload.cepCampaignId),
                moves: metrics.moves, expands: metrics.expands,
                engagedMs: metrics.engagedMs, lastPosition: metrics.lastPosition
            ),
            payload: state.payload
        )
    }

    private func emitFloaterCompleted(_ state: ActiveFloaterState) {
        if !isLiveTestCepId(state.payload.cepCampaignId) {
            let campaignKey = state.payload.campaignKey
            frequencyManager?.recordCompleted(
                campaignKey, campaignStore.find(campaignKey)?.frequency)
        }
        events.toDigia(FloaterEvent.Completed(), payload: state.payload)
    }

    /// The × while collapsed, and the expanded content's own dismiss action
    /// (`onDismiss` threaded through `NudgeColumnContent`) both route here —
    /// straight to dismissal, no Clicked report.
    func dismissFloater(_ reason: FloaterDismissReason) {
        floaterOrchestrator.dismiss(reason)
    }

    /// Shared handler for the expanded ×, the swipe-down strip, and any future
    /// `onBack` trigger — `expanded.onClose`/`expanded.onBack` are independent
    /// config fields, but both resolve to one of these same two outcomes.
    /// `.dismiss` ends the floater outright with no Clicked report. `.collapse`
    /// reports a secondary click, then shrinks back to the small window.
    func endFloaterExpanded(_ outcome: FloaterExpandedClose) {
        switch outcome {
        case .dismiss:
            floaterOrchestrator.dismiss(.userClose)
        case .collapse:
            reportFloaterClicked(
                elementId: "pip_close", actionType: "collapse", ctaRole: "secondary")
            floaterOrchestrator.collapse()
        }
    }

    /// Any authored action taken from the expanded content also ends the showing
    /// once it completes — floater's "CTA taken also dismisses" contract. Called
    /// directly from `performFloaterCanvasAction` (`floater_overlay_view.swift`)
    /// after its `executeActionFlow` await completes — unlike Android's
    /// fire-and-forget `launchActionFlow`, iOS's `executeActionFlow` is already
    /// `async`, so the caller can just chain this rather than needing an
    /// `onComplete` callback parameter.
    func onFloaterActionCompleted() {
        guard floaterOrchestrator.state != nil else { return }
        floaterOrchestrator.complete()
        floaterOrchestrator.dismiss(.ctaTaken)
    }

    // MARK: - Story floater lifecycle
    //
    // Reported through the PiP's own event vocabulary rather than a parallel set. Both
    // are `floater` campaigns and both answer the same questions — was the window seen,
    // was it moved, was its content opened, how long was the user inside — so one schema
    // keeps the dashboard's floater analytics reading both subtypes without a backend
    // change. "Expanded" there means "the story was open".

    private func reportFloaterStoryImpression(_ state: ActiveFloaterStoryState) {
        dwellTracker.markViewed(state.payload.cepCampaignId)
        if !isLiveTestCepId(state.payload.cepCampaignId) {
            let campaignKey = state.payload.campaignKey
            frequencyManager?.recordShow(campaignKey, campaignStore.find(campaignKey)?.frequency)
        }
        events.toBoth(
            .impressed, FloaterEvent.Viewed(screenName: _currentScreen), payload: state.payload)
    }

    /// Deliberately silent.
    ///
    /// The story's own viewer reports "Digia Step Viewed" per page, and the first of those fires as
    /// the story opens — which is exactly the moment this used to fire its property-less version.
    /// Emitting here as well would put two of the same event on the wire for one open, one of them
    /// with no page to attribute it to. The orchestrator still calls this because the *lifecycle*
    /// hook is real; only the reporting moved.
    private func emitFloaterStoryStepViewed(_ state: ActiveFloaterStoryState) {}

    /// Silent for the same reason as `emitFloaterStoryStepViewed` — the viewer reports the close
    /// with the page the viewer left on, which is the half that makes drop-off measurable.
    private func emitFloaterStoryStepDismissed(_ state: ActiveFloaterStoryState) {}

    private func emitFloaterStoryDismissed(
        _ state: ActiveFloaterStoryState, _ reason: FloaterDismissReason,
        _ metrics: FloaterMetrics
    ) {
        events.toBoth(
            .dismissed,
            FloaterEvent.Dismissed(
                dismissReason: reason.wire,
                dwellMs: dwellTracker.consumeDwellMs(state.payload.cepCampaignId),
                moves: metrics.moves, expands: metrics.expands,
                engagedMs: metrics.engagedMs, lastPosition: metrics.lastPosition
            ),
            payload: state.payload
        )
    }

    private func emitFloaterStoryCompleted(_ state: ActiveFloaterStoryState) {
        if !isLiveTestCepId(state.payload.cepCampaignId) {
            let campaignKey = state.payload.campaignKey
            frequencyManager?.recordCompleted(
                campaignKey, campaignStore.find(campaignKey)?.frequency)
        }
        events.toDigia(FloaterEvent.Completed(), payload: state.payload)
    }

    /// SDK chrome taps on the window itself — opening the story, and the ×.
    /// A tap on the window — the campaign's own surface, so an experience-level click.
    ///
    /// Covers both the SDK's chrome (opening the story, the ×) and the author's own elements. The
    /// window is not a step: a story floater's steps are the pages of the story it opens, so a
    /// button drawn on the window is a click on the experience itself. Reporting it as a step click
    /// put window taps and page taps in the same bucket, and left a campaign whose window carries a
    /// CTA with no experience clicks at all.
    func reportFloaterStoryClicked(
        elementId: String,
        actionType: String,
        ctaRole: String,
        ctaLabel: String? = nil,
        actionUrl: String? = nil
    ) {
        guard let state = floaterStoryOrchestrator.state else { return }
        events.toDigia(
            FloaterEvent.Clicked(
                elementId: elementId, actionType: actionType,
                // The window is the collapsed state; the story is the expanded one.
                pipState: floaterStoryOrchestrator.storyOpen ? "expanded" : "collapsed",
                ctaRole: ctaRole,
                timeToActionMs: dwellTracker.elapsedMs(state.payload.cepCampaignId),
                ctaLabel: ctaLabel,
                actionUrl: actionUrl
            ),
            payload: state.payload
        )
    }

    /// Runs an authored action from the window's canvas or from inside a story.
    ///
    /// Unlike a PiP's expanded CTA, this does **not** end the showing on its own. A PiP's
    /// canvas is the campaign's whole payload, so any action there is the end of it; a
    /// story floater's window keeps standing after a tap unless the author wired Hide,
    /// which the local executor's `dismiss` below handles.
    func runFloaterStoryAction(
        state: ActiveFloaterStoryState, request: CampaignCanvasActionRequest
    ) {
        // Runs the action and nothing else. Which *event* a tap is belongs to the caller, because
        // only it knows whether the tap came from the window or from a story page — and the two are
        // different levels of the funnel, not two flavours of the same one.
        Task {
            await executeActionFlow(
                request.actions, variables: state.variableContext,
                localActionExecutor: LocalActionExecutor(dismiss: { [weak self] in
                    self?.floaterStoryOrchestrator.dismiss(.userClose)
                })
            )
        }
    }

    // MARK: - Inline slot lifecycle
    //
    // CEP is Impressed + Dismissed instantly at route time (syncTemplate
    // semantics — see routeByCampaignKey). Digia's impression fires once, when
    // the slot first actually renders, deduped per campaign.

    /// Resolves the campaign for `payload`: a live test's transient entry if
    /// present, else the real store. Every campaign-by-payload lookup should go
    /// through this — a lookup that only checks `campaignStore` silently misses
    /// for any live-tested campaign, since those are deliberately never added there.
    private func findCampaign(_ payload: CEPTriggerPayload) -> CampaignModel? {
        liveTestCampaigns[payload.cepCampaignId] ?? campaignStore.find(payload.campaignKey)
    }

    func reportSlotFirstRender(_ payload: CEPTriggerPayload) {
        guard let campaign = findCampaign(payload) else { return }
        let viewed: EngageAnalyticsEvent
        switch campaign.config {
        case .inline(let cfg):
            viewed = CarouselEvent.Viewed(
                itemTotal: cfg.items.count, slotKey: cfg.slotKey, screenName: _currentScreen)
        case .banner(let cfg):
            viewed = BannerEvent.Viewed(slotKey: cfg.slotKey, screenName: _currentScreen)
        case .story(let cfg):
            viewed = StoriesEvent.Viewed(slotKey: cfg.slotKey, screenName: _currentScreen)
        case .inlineCanvas(let cfg):
            viewed = InlineCanvasEvent.Viewed(slotKey: cfg.slotKey, screenName: _currentScreen)
        default:
            return
        }
        events.digiaImpressionOnce(payload: payload, event: viewed)
    }

    /// A carousel item scrolled into view. `auto` = autoplay advance vs manual swipe.
    func reportCarouselStepViewed(
        payload: CEPTriggerPayload, itemIndex: Int, itemTotal: Int, auto: Bool
    ) {
        events.toDigia(
            CarouselEvent.StepViewed(itemIndex: itemIndex, itemTotal: itemTotal, auto: auto),
            payload: payload
        )
    }

    /// A carousel item (or its CTA) was tapped.
    func reportCarouselStepClicked(
        payload: CEPTriggerPayload, itemIndex: Int, action: EngageAction?
    ) {
        let actionType = action?.analyticsType
        let actionUrl = action?.analyticsURL
        // The first item tap also counts as an experience-level engagement click (once).
        events.digiaExperienceClickedOnce(
            payload: payload,
            event: CarouselEvent.Clicked(actionType: actionType, actionUrl: actionUrl)
        )
        events.toDigia(
            CarouselEvent.StepClicked(
                itemIndex: itemIndex,
                actionType: actionType,
                actionUrl: actionUrl
            ),
            payload: payload
        )
    }

    func reportBannerClicked(payload: CEPTriggerPayload, action: EngageAction?) {
        events.toBoth(
            .clicked(elementID: "banner"),
            BannerEvent.Clicked(
                actionType: action?.analyticsType,
                actionUrl: action?.analyticsURL
            ),
            payload: payload
        )
    }

    // MARK: - Inline story lifecycle (full-screen player)

    /// A story was opened (ring/thumbnail tapped) — drives open rate.
    func reportStoryOpened(_ payload: CEPTriggerPayload) {
        events.toDigia(StoriesEvent.Opened(), payload: payload)
    }

    /// A story frame became visible. `itemIndex` is 1-based; `itemTotal` = frames.
    func reportStoryStepViewed(_ payload: CEPTriggerPayload, itemIndex: Int, itemTotal: Int) {
        events.toDigia(
            StoriesEvent.StepViewed(itemIndex: itemIndex, itemTotal: itemTotal), payload: payload)
    }

    /// A CTA inside a story frame was tapped.
    func reportStoryStepClicked(
        _ payload: CEPTriggerPayload,
        itemIndex: Int,
        ctaLabel: String?,
        actionType: String?,
        actionUrl: String?
    ) {
        events.toDigia(
            StoriesEvent.StepClicked(
                itemIndex: itemIndex,
                ctaLabel: ctaLabel,
                actionType: actionType,
                actionUrl: actionUrl
            ),
            payload: payload
        )
    }

    /// Story closed before the last frame. `itemIndex` is the 1-based frame on close.
    func reportStoryStepDismissed(_ payload: CEPTriggerPayload, itemIndex: Int) {
        events.toDigia(StoriesEvent.StepDismissed(itemIndex: itemIndex), payload: payload)
    }

    /// Last story frame viewed. `itemTotal` = frames; `timeToCompleteMs` from open.
    func reportStoryCompleted(
        _ payload: CEPTriggerPayload, itemTotal: Int, timeToCompleteMs: Int64?
    ) {
        events.toDigia(
            StoriesEvent.Completed(itemTotal: itemTotal, timeToCompleteMs: timeToCompleteMs),
            payload: payload
        )
    }

    // MARK: - Guide lifecycle

    private func guideStateDidChange(_ state: ActiveGuideState?) {
        guard let state, let anchorKey = state.currentStep?.target.anchorKey else {
            AnchorRegistry.shared.stopTracking()
            return
        }
        AnchorRegistry.shared.track(
            key: anchorKey,
            onAvailable: { [weak self] availableKey in
                self?.logNativeGuideStage(
                    "anchor",
                    "result=ready anchor_key=\(availableKey) step_index=\(state.stepIndex + 1)"
                )
            },
            onUnavailable: { [weak self] unavailableKey, reason in
                guard let self,
                      let current = self.guideOrchestrator.state,
                      current.currentStep?.target.anchorKey == unavailableKey
                else { return }
                self.logNativeGuideStage(
                    "anchor",
                    "result=dropped anchor_key=\(unavailableKey) reason=\(reason.rawValue)"
                )
                self.reportGuideRenderFailure(
                    .invalidGeometry,
                    guideToken: current.token,
                    stepIndex: current.stepIndex
                )
            }
        )
    }

    func dismissGuide() {
        guard let state = guideOrchestrator.state else { return }
        let payload = state.payload
        let total = state.steps.count
        let elapsed = dwellTracker.consumeDwellMs(payload.cepCampaignId)
        let isAnchorless = state.currentStep?.target.anchorlessTarget != nil
        if guideCompletionFired, isAnchorless, total > 1 {
            events.toCep(.clicked(), payload: payload)
        } else if !guideCompletionFired, total > 1 {
            events.toDigia(
                GuideEvent.StepDismissed(itemIndex: state.stepIndex + 1),
                payload: payload
            )
        }
        guideOrchestrator.dismiss()
        events.toBoth(
            .dismissed,
            GuideEvent.Dismissed(
                abandonedAtItem: state.stepIndex + 1,
                itemTotal: total,
                dwellMs: elapsed
            ),
            payload: payload
        )
        guideCompletionFired = false
    }

    func advanceGuide(completesOnLast: Bool = true) {
        guard let state = guideOrchestrator.state else { return }
        if state.hasNext {
            if isLiveTestCepId(state.payload.cepCampaignId),
               let nextIndex = availableGuideStepIndex(in: state, after: state.stepIndex) {
                guideOrchestrator.move(to: nextIndex)
            } else if !isLiveTestCepId(state.payload.cepCampaignId) {
                guideOrchestrator.advance()
            } else {
                dismissGuide()
            }
        } else {
            if completesOnLast, state.steps.count > 1 { reportGuideCompletedIfNeeded(state) }
            dismissGuide()
        }
    }

    func previousGuide() {
        guard let state = guideOrchestrator.state else { return }
        if isLiveTestCepId(state.payload.cepCampaignId),
           let previousIndex = availableGuideStepIndex(in: state, before: state.stepIndex) {
            guideOrchestrator.move(to: previousIndex)
        } else if !isLiveTestCepId(state.payload.cepCampaignId) {
            guideOrchestrator.previous()
        }
    }

    private func availableGuideStepIndex(
        in state: ActiveGuideState,
        after stepIndex: Int
    ) -> Int? {
        state.steps.indices.first {
            $0 > stepIndex && isGuideStepAvailable(state.steps[$0])
        }
    }

    private func availableGuideStepIndex(
        in state: ActiveGuideState,
        before stepIndex: Int
    ) -> Int? {
        state.steps.indices.reversed().first {
            $0 < stepIndex && isGuideStepAvailable(state.steps[$0])
        }
    }

    private func isGuideStepAvailable(_ step: GuideStepModel) -> Bool {
        guard let anchorKey = step.target.anchorKey else { return true }
        if case .unavailable(.outsideViewport) = AnchorRegistry.shared.resolution(for: anchorKey) {
            AnchorRegistry.shared.scrollToVisible(anchorKey)
        }
        if case .available = AnchorRegistry.shared.resolution(for: anchorKey) { return true }
        return false
    }

    func reportGuideShown() {
        guard let state = guideOrchestrator.state else { return }
        if state.currentStep?.target.anchorKey != nil {
            logNativeGuideStage(
                "render",
                "result=shown campaign_key=\(state.payload.campaignKey) step_index=\(state.stepIndex + 1)"
            )
        }
        let payload = state.payload
        let total = state.steps.count
        if isLiveTestCepId(payload.cepCampaignId) {
            liveTestContexts[payload.cepCampaignId]?.reportShown()
        }
        if state.stepIndex == 0, dwellTracker.elapsedMs(payload.cepCampaignId) == nil {
            dwellTracker.markViewed(payload.cepCampaignId)
            if !isLiveTestCepId(payload.cepCampaignId) {
                frequencyManager?.recordShow(
                    payload.campaignKey,
                    findCampaign(payload)?.frequency
                )
            }
            events.toBoth(
                .impressed,
                GuideEvent.Viewed(
                    displayStyle: state.currentStep?.displayStyle ?? "spotlight",
                    itemTotal: total,
                    screenName: _currentScreen
                ),
                payload: payload
            )
        }
        if total > 1 || state.currentStep?.target.anchorlessTarget != nil {
            events.toDigia(
                GuideEvent.StepViewed(
                    itemIndex: state.stepIndex + 1,
                    itemTotal: total,
                    anchorKey: state.currentStep?.target.anchorKey,
                    displayStyle: state.currentStep?.displayStyle
                ),
                payload: payload
            )
        }
    }

    func reportGuideRenderFailure(
        _ failure: AnchorlessFailure?,
        guideToken: Int64? = nil,
        stepIndex: Int? = nil
    ) {
        guard let state = guideOrchestrator.state,
              (guideToken == nil || guideToken == state.token),
              (stepIndex == nil || stepIndex == state.stepIndex)
        else { return }
        if state.currentStep?.target.anchorKey != nil {
            logNativeGuideStage(
                "render",
                "result=failed campaign_key=\(state.payload.campaignKey) reason=\(failure?.rawValue ?? "image_load")"
            )
        }
        if isDebugBuild, state.currentStep?.target.anchorKey == nil {
            DigiaLog.warning(
                "[Anchorless] render failed: \(failure?.rawValue ?? "image load failed")"
                    + " step=\(state.stepIndex + 1)",
                tag: "Digia"
            )
        }
        let payload = state.payload
        if dwellTracker.elapsedMs(payload.cepCampaignId) == nil {
            guideOrchestrator.dismiss()
            events.toCep(.dismissed, payload: payload)
            guideCompletionFired = false
        } else {
            dismissGuide()
        }
        let code: LiveTestFailureCode = switch failure {
        case .pageKeyMismatch: .noMatchingScreen
        case .invalidTarget: .templateError
        case .unsupportedLayout, .invalidGeometry, nil: .renderError
        }
        liveTestContexts[payload.cepCampaignId]?.reportFailed(
            code,
            message: failure?.rawValue ?? "Anchorless Spotlight image could not be loaded"
        )
    }

    func reportGuideStepClicked(
        actionType: String?,
        actionUrl: String?,
        ctaLabel: String?,
        action: EngageAction? = nil,
        elementId: String? = nil
    ) {
        guard let state = guideOrchestrator.state, let step = state.currentStep else { return }
        events.toDigia(
            GuideEvent.StepClicked(
                itemIndex: state.stepIndex + 1,
                elementId: elementId ?? step.target.anchorKey,
                ctaLabel: ctaLabel,
                actionType: actionType,
                actionUrl: actionUrl
            ),
            payload: state.payload
        )
        if !state.hasNext,
           action != .previous {
            reportGuideCompletedIfNeeded(state)
        }
    }

    func fireGuideEvent(_ eventName: String) {
        guard let state = guideOrchestrator.state else { return }
        events.toCep(.clicked(elementID: eventName), payload: state.payload)
    }

    private func reportGuideCompletedIfNeeded(_ state: ActiveGuideState) {
        guard !guideCompletionFired else { return }
        guideCompletionFired = true
        if !isLiveTestCepId(state.payload.cepCampaignId) {
            frequencyManager?.recordCompleted(
                state.payload.campaignKey,
                findCampaign(state.payload)?.frequency
            )
        }
        events.toDigia(
            GuideEvent.Completed(
                itemTotal: state.steps.count,
                timeToCompleteMs: state.currentStep?.target.anchorlessTarget == nil
                    ? nil
                    : dwellTracker.elapsedMs(state.payload.cepCampaignId)
            ),
            payload: state.payload
        )
    }

    private func logNativeGuideStage(_ stage: String, _ details: String) {
        guard config?.wrapperBinding == "react_native" else { return }
        DigiaLog.verbose("guide_native_stage=\(stage) \(details)")
    }

    /// Public analytics entry point for JS-rendered RN campaigns (guides). The JS
    /// layer fires each lifecycle event by its Engage matrix `eventName` with
    /// wire-keyed `props`; this maps it to the typed analytics event and records
    /// it to Digia. CEP forwarding for JS-rendered campaigns is handled JS-side.
    func captureAnalyticsEvent(campaignKey: String, eventName: String, props: [String: Any]) {
        guard let event = guideEventFor(eventName: eventName, props: props) else {
            logVerbose(
                "captureAnalyticsEvent: unsupported event '\(eventName)' for key '\(campaignKey)' — skipped"
            )
            return
        }
        let campaign = campaignStore.find(campaignKey)
        // Native frequency capping for RN-rendered guides: bump on Viewed, apply
        // the permanent stop on Completed (when the policy opts into stopOn).
        switch eventName {
        case "Digia Experience Viewed":
            frequencyManager?.recordShow(campaignKey, campaign?.frequency)
        case "Digia Experience Completed":
            frequencyManager?.recordCompleted(campaignKey, campaign?.frequency)
        default:
            break
        }
        let payloadID = props["payload_id"] as? String
        let externalPayload = activeExternalGuide?.payload
        let payload = externalPayload?.cepCampaignId == payloadID
            ? externalPayload
            : nil
        events.toDigia(
            event,
            payload: payload ?? CEPTriggerPayload(
                cepCampaignId: campaign?.id ?? campaignKey,
                campaignKey: campaignKey,
                cepMetadata: [:]
            )
        )
        if (eventName == "Digia Experience Dismissed"
            || eventName == "Digia Experience Completed")
            && activeExternalGuide?.payload.cepCampaignId == payloadID
        {
            activeExternalGuide = nil
        }
    }

    private func guideEventFor(eventName: String, props: [String: Any]) -> EngageAnalyticsEvent? {
        func str(_ key: String) -> String? { props[key] as? String }
        func int(_ key: String) -> Int? {
            (props[key] as? NSNumber)?.intValue ?? (props[key] as? Int)
        }
        switch eventName {
        case "Digia Experience Viewed":
            return GuideEvent.Viewed(
                displayStyle: str("display_style") ?? "",
                itemTotal: int("step_total") ?? 0,
                screenName: _currentScreen)
        case "Digia Step Viewed":
            return GuideEvent.StepViewed(
                itemIndex: int("step_index") ?? 0,
                itemTotal: int("step_total") ?? 0,
                anchorKey: str("anchor_key"),
                displayStyle: str("display_style")
            )
        // Guides only have Step Clicked in the matrix; map both click variants to it.
        case "Digia Step Clicked", "Digia Experience Clicked":
            return GuideEvent.StepClicked(
                itemIndex: int("step_index") ?? 0,
                elementId: str("element_id"),
                ctaLabel: str("cta_label"),
                actionType: str("action_type"),
                actionUrl: str("action_url")
            )
        case "Digia Step Dismissed":
            return GuideEvent.StepDismissed(itemIndex: int("step_index") ?? 0)
        case "Digia Experience Dismissed":
            return GuideEvent.Dismissed(
                abandonedAtItem: int("abandoned_at_step") ?? int("step_index"),
                itemTotal: int("step_total"))
        case "Digia Experience Completed":
            return GuideEvent.Completed(itemTotal: int("step_total"))
        default:
            return nil
        }
    }

    /// Converts a `JSONValue` map to a Foundation map for JSON serialization,
    /// dropping `null` entries.
    private static func foundation(_ map: [String: JSONValue]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in map {
            if let any = value.anyValue { result[key] = any }
        }
        return result
    }

    private static func stringArray(_ value: JSONValue?) -> [String] {
        guard case .array(let arr)? = value else { return [] }
        return arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }

    private static func stringValue(_ value: JSONValue?) -> String? {
        if case .string(let s)? = value { return s }
        return nil
    }

    /// The block's title text, or nil when empty (blank titles are not worth
    /// shipping over the wire).
    private static func questionTitle(_ block: SurveyBlock) -> String? {
        let title = block.title.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// Comma-joined labels for the selected option ids on a choice block.
    /// Returns nil when the block has no options or no selection matches —
    /// (e.g. rating/nps/text inputs whose answer values aren't option ids).
    private static func answerLabel(block: SurveyBlock, values: [String]) -> String? {
        guard !values.isEmpty, !block.options.isEmpty else { return nil }
        let labels = values.compactMap { id in
            block.options.first { $0.id == id }?.label
        }
        guard !labels.isEmpty else { return nil }
        return labels.joined(separator: ", ")
    }

    /// Numeric scale bounds for scored blocks (Rating 1–5, NPS 0–10). Other
    /// block types have no scale.
    private static func scaleBounds(_ block: SurveyBlock) -> (min: Int, max: Int)? {
        switch block.type {
        case .rating: return (1, 5)
        case .nps, .npsEmoji, .npsSmiley: return (0, 10)
        default: return nil
        }
    }

    /// Stable per-question key for `questionViewedAt`. Scoped by survey token
    /// so a re-show of the same survey doesn't reuse a stale viewed-at.
    private static func questionKey(token: Int64, nodeId: String) -> String {
        "\(token):\(nodeId)"
    }

    func resetForTesting() {
        activePlugin?.teardown()
        activePlugin = nil
        _currentScreen = nil
        analyticsService?.clear()
        analyticsService = nil
        frequencyManager = nil
        config = nil
        hostActionExecutor.clearHandlers()
        sdkState = .notInitialized
        isHostMounted = false
        font = DigiaFont()
        currentDesignTokens = .empty
        guideRenderer = .reactNative
        onLiveTestGuideRenderRequest = nil
        guideHostActionHandler = nil
        campaignStore.clear()
        controller.dismissNudge()
        controller.dismissStoryOverlay()
        inlineController.clear()
        surveyOrchestrator.dismiss()
        guideOrchestrator.dismiss()
        AnchorRegistry.shared.resetForTesting()
        floaterOrchestrator.dispose()
        floaterStoryOrchestrator.dispose()
        activeExternalGuide = nil
        events.clearImpressions()
        dwellTracker.clear()
        completedSurveyToken = nil
        welcomeStartToken = nil
        questionViewedAt.removeAll()
        liveTestService.stop()
        liveTestContexts.removeAll()
        liveTestCampaigns.removeAll()
    }

}

@MainActor
private final class LiveTestFrameWaiter: NSObject {
    private var continuation: CheckedContinuation<Void, Never>?
    private var displayLink: CADisplayLink?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let displayLink = CADisplayLink(target: self, selector: #selector(frameDidRender))
            displayLink.add(to: .main, forMode: .common)
            self.displayLink = displayLink
        }
    }

    @objc private func frameDidRender() {
        displayLink?.invalidate()
        displayLink = nil
        continuation?.resume()
        continuation = nil
    }
}

struct CaptureDebugPage: Identifiable {
    let pageKey: String
    let assetId: String
    let capturedAt: String
    var id: String { pageKey }
}

// MARK: - Survey config metrics (Engage matrix props)

extension SurveyConfigModel {
    /// Configured questions = graph nodes whose block is an actual prompt (not
    /// content chrome like welcome / text-media / result pages).
    fileprivate var questionCount: Int {
        nodes.filter { node in
            guard let block = blockFor(node) else { return false }
            return !block.type.isContent
        }.count
    }

    fileprivate var hasWelcome: Bool { welcomeBlock() != nil }

    fileprivate var hasThanks: Bool { blocks.contains { $0.type == .resultPage } }

    fileprivate var hasBranching: Bool { nodes.contains { $0.branching.type != .linear } }

    fileprivate func blockForNode(_ nodeId: String) -> SurveyBlock? {
        nodeById(nodeId).flatMap { blockFor($0) }
    }
}
