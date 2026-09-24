import Combine
import Foundation
import UIKit

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

@MainActor
final class SDKInstance: ObservableObject, DigiaCEPHost {
    static let shared = SDKInstance()

    private struct ExternalGuide {
        let campaign: CampaignModel
        let payload: CEPTriggerPayload
    }

    var requestHeaders: [String: String] { services?.requestHeaders ?? [:] }
    @Published private(set) var config: DigiaConfig?

    var sdkVersion: String? {
        guard let config else { return nil }
        return buildSdkVersion(
            binding: config.wrapperBinding ?? "native",
            platform: "ios",
            wrapperVersion: config.wrapperVersion,
            core: DigiaSdkVersion.value
        )
    }
    @Published private(set) var sdkState: SDKState = .notInitialized
    /// A delivery that arrived before the campaign bundle. See `bufferUntilReady`.
    private var pendingPresentation: PresentationController?
    @Published private(set) var isHostMounted = false
    @Published private(set) var captureModeEnabled: Bool
    @Published private(set) var captureTextEnabled: Bool
    @Published private(set) var captureMediaEnabled: Bool
    @Published private(set) var captureStructureEnabled: Bool
    @Published private(set) var capturedPages: [CaptureDebugPage] = []
    @Published private(set) var captureStatusMessage: String?
    @Published private(set) var captureFlashRevision = 0
    var isCaptureSupported: Bool { config?.wrapperBinding == "react_native" }

    private var activePlugin: DigiaCEPPlugin?

    /// Mints presentation ids. Injected so a test can make them deterministic;
    /// production needs them UUID-grade, because the id is also the first-party
    /// analytics dedup key and must not collide across sessions or devices.
    var idGenerator: () -> String = { UUID().uuidString }

    /// The single writer of presentation state. Every live presentation in the
    /// SDK is opened, indexed and settled here — see ``PresentationCoordinator``.
    lazy var coordinator = PresentationCoordinator(
        // Read through, not captured: the coordinator is built lazily on first
        // delivery, and a test that sets `idGenerator` afterwards would
        // otherwise be silently ignored.
        idGenerator: { [weak self] in self?.idGenerator() ?? UUID().uuidString },
        onCancelSurface: { [weak self] cepCampaignId in
            self?.dismissSurfaces(forCepCampaignId: cepCampaignId)
        }
    )
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
    private var lastReportedGuideStep: (token: Int64, index: Int)?
    /// The design tokens the current campaign bundle was parsed with.
    ///
    /// Held because live test parses a campaign that never came through the
    /// bundle, and it has to resolve the same tokens the bundle's campaigns do.
    private var currentDesignTokens = DesignTokenCatalog.empty
    private var currentTimeAnchor: TrustedTimeAnchor?

    /// Built once in `initialize(_:)`, after the storage migration ran (D1).
    /// Nil before that: anything needed earlier is owned directly below.
    private(set) var services: SDKServices?

    // Pre-init collaborators: used before `initialize()` (anchor buffering,
    // the debug screens, capture toggles), so they live here rather than in
    // `services`.
    private let storage: LocalStorage
    let networkClient: any NetworkClient
    let campaignStore: CampaignStore
    let componentRegistry: ComponentRegistryService
    let liveTestService: LiveTestService

    var analyticsService: AnalyticsService? {
        services?.analyticsService
    }
    var frequencyManager: FrequencyManager? {
        services?.frequencyManager
    }
    var identityManager: IdentityManager? {
        services?.identityManager
    }

    private let pendingLock = NSLock()
    private var pendingUserId: String? = nil
    private var pendingClearUserId: Bool = false

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
    /// Whether the floating "Digia" debug bubble is shown. See
    /// `DigiaDebugOverlayController`.
    private let debugOverlayController: DigiaDebugOverlayController
    /// Live-test campaigns, parsed on the spot — never added to `campaignStore`.
    private var liveTestCampaigns: [String: CampaignModel] = [:]
    /// In-flight live test invocations, keyed by synthetic `cepCampaignId`.
    private var liveTestContexts: [String: LiveTestContext] = [:]
    /// Whether the host app is a debug build, resolved once at `initialize`.
    /// Gates the component registry and `DigiaDebugSettingsView`.
    private(set) var isDebugBuild = false

    /// Set by the RN bridge. When non-nil the SDK is RN-driven: guides render in
    /// JS, so on a guide trigger native only applies frequency capping and (if
    /// allowed) invokes this hook to ask JS to render, instead of rendering the
    /// guide natively. Nil in pure-native apps, where guides render natively.
    ///
    /// The second argument is the presentation id the coordinator minted for
    /// this delivery — the same id a later
    /// ``reportExternalGuideLifecycle(presentationId:event:)`` call must use to
    /// settle the real presentation the CEP's hold is on, rather than some
    /// second, disconnected one the caller minted itself.
    var onGuideRenderRequest: ((GuideRenderRequest) -> Void)?

    // Event system (mirrors Android): a fan-out emitter over two sinks — the
    // coarse CEP channel (`toCep`) and Digia's rich analytics (`toDigia`).
    // Campaign id/type are resolved from the store inside the Digia sink.
    private let dwellTracker = DwellTracker()
    private var events: EngageEventEmitter!

    private init() {
        LocalStorageMigrator.migrateIfNeeded()
        let defaultStorage = UserDefaultsLocalStorage()
        let defaultNetworkClient = URLSessionNetworkClient()
        let defaultDebugOverlay = DigiaDebugOverlayController(storage: defaultStorage.scoped("debug"))
        self.debugOverlayController = defaultDebugOverlay
        self.storage = defaultStorage
        self.networkClient = defaultNetworkClient
        self.campaignStore = CampaignStore()
        self.componentRegistry = ComponentRegistryService(
            storage: defaultStorage.scoped("registry"),
            networkClient: defaultNetworkClient,
            debugOverlay: defaultDebugOverlay
        )
        self.liveTestService = LiveTestService(
            storage: defaultStorage.scoped("live_test"),
            networkClient: defaultNetworkClient
        )

        let captureStorage = defaultStorage.scoped("capture")
        self.captureModeEnabled = captureStorage.bool(forKey: "enabled")
        self.captureTextEnabled = captureStorage.bool(forKey: "include_text")
        self.captureMediaEnabled = captureStorage.bool(forKey: "include_media")
        self.captureStructureEnabled = captureStorage.bool(forKey: "include_structure")

        events = EngageEventEmitter(
            cep: PresentationSink { [weak self] in self?.coordinator },
            digia: DigiaAnalyticsSink(
                getAnalyticsService: { [weak self] in self?.analyticsService },
                getCampaign: { [weak self] key in self?.campaignStore.find(key) }
            ),
            onLiveTestShown: { [weak self] cepCampaignId in
                self?.liveTestContexts[cepCampaignId]?.reportShown()
            },
            onLiveTestDismissed: { [weak self] cepCampaignId, reason, completed in
                self?.relayLiveTestDismissal(cepCampaignId, reason: reason, completed: completed)
            }
        )
        inlineController.onCampaignRemoved = { [weak self] payload in
            self?.events.inlineRemoved(payload)
        }
        floaterOrchestrator = FloaterOrchestrator(
            onDismissed: { [weak self] state, reason, metrics, wasVisible in
                self?.emitFloaterDismissed(state, reason, metrics, wasVisible)
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
            onDismissed: { [weak self] state, reason, metrics, wasVisible in
                self?.emitFloaterStoryDismissed(state, reason, metrics, wasVisible)
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
        LocalStorageMigrator.migrateIfNeeded()
        DigiaImagePipeline.configureIfNeeded()
        hostActionExecutor.configure(config.actionHandlers)
        guard self.config == nil else { return }
        self.config = config
        DigiaLogger.configure(config.logLevel)
        DigiaEndpoints.configure(config)
        let services = SDKServices(config: config, storage: storage, networkClient: networkClient)
        self.services = services
        services.sessionReporter.report()

        // Flush pending user ID buffering
        let (flushClear, flushUserId) = pendingLock.withLock {
            let clear = pendingClearUserId
            let user = pendingUserId
            pendingClearUserId = false
            pendingUserId = nil
            return (clear, user)
        }

        if flushClear {
            services.identityManager.clearUserId()
            analyticsService?.clearUserId()
        } else if let flushUserId {
            services.identityManager.setUserId(flushUserId)
            analyticsService?.setUserId(flushUserId)
        }

        services.submissionReporter.configure(config: config)
        isDebugBuild = DigiaDebugDetection.isDebugBuild()
        // Sink #4 joins the registry here and nowhere else: it sends through
        // the pipeline that was just configured, and there was nothing to
        // send with before this line. It joins *before* the campaign bundle
        // is fetched on purpose — `fetch_failed_auth` is one of the failures
        // it exists to report, so waiting for a successful fetch would blind
        // it to the fetch that failed. The bundle's kill switch and cap land
        // in `HealthSink.applyBundleConfig` a moment later.
        HealthSink.shared.activate { [weak self] payload in
            Task { @MainActor [weak self] in
                self?.analyticsService?.captureHealth(
                    campaignKey: payload.campaignKey,
                    reason: payload.reason,
                    stage: payload.stage,
                    detail: payload.detail,
                    buildMode: payload.buildMode
                )
            }
        }

        font = DigiaFont(fontFamily: config.fontFamily)
        CampaignCanvasTheme.shared.update(config.themeMode)

        var campaigns: [CampaignModel] = []
        do {
            let bundle = try await CampaignFetcher(
                networkClient: networkClient,
                requestHeaders: requestHeaders
            ).fetch()
            // Applied as soon as the bundle answers — the earliest point this
            // core can reach, though `fetch()` has already parsed every
            // campaign (and so already fired this bundle's own parse-stage
            // health reasons) by the time it returns here; see the platform
            // note on `CampaignBundle.create`.
            HealthSink.shared.applyBundleConfig(
                enabled: bundle.healthEnabled, sessionCap: bundle.healthSessionCap)
            campaigns = bundle.campaigns
            currentDesignTokens = bundle.designTokens
            currentTimeAnchor = bundle.timeAnchor
        } catch {
            // Campaign fetch failure must not block SDK readiness.
            currentTimeAnchor = nil
            // A rejected key is the one fetch failure a customer can fix
            // themselves, so it is worth its own row rather than being filed
            // under "network". Init still reaches ready either way — the SDK
            // comes up, it just has nothing to show.
            let fetchFailure = error as? CampaignFetchError
            log.e(
                "Campaign fetch failed",
                error: error,
                stage: .fetch,
                reason: Self.fetchFailureReason(fetchFailure),
                extras: fetchFailure?.statusCode.map { ["http_status": String($0)] }
            )
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
            // The most common answer to "my campaign never showed": it is not
            // live. A success with nothing in it is not a failure, and reads
            // very differently from one.
            log.i(
                "No campaigns fetched — the store is empty",
                stage: .fetch,
                reason: TimelineReason.bundleEmpty
            )
        } else {
            log.i(
                "Campaigns fetched (count=\(campaigns.count))",
                stage: .fetch,
                reason: TimelineReason.bundleFetched,
                extras: ["count": String(campaigns.count)]
            )
            log.d("Campaign store populated (entries=[\(campaignStore.debugSummary)])")
        }

        let wasReady = sdkState == .ready
        sdkState = .ready
        // The first line a support ticket needs, and the answer to most
        // "nothing shows up" reports: which build, which environment, and what
        // verbosity is actually in force — with whether the app chose it. Once
        // per process: on the RN path this method runs again for every bundle
        // JS hands us.
        if let config, !wasReady {
            let version = sdkVersion ?? buildSdkVersion(
                binding: config.wrapperBinding ?? "native",
                platform: "ios",
                wrapperVersion: config.wrapperVersion,
                core: DigiaSdkVersion.value
            )
            log.i(
                "Digia SDK \(version) initialized "
                    + "(env=\(config.environment.name), "
                    + "apiKey=\(maskSecret(config.apiKey)), "
                    + "logLevel=\(config.logLevel.name) "
                    + "(\(config.isLogLevelExplicit ? "explicit" : "default")))",
                stage: .session,
                reason: TimelineReason.sdkInitialized,
                // No apiKey, masked or otherwise: extras are readable on the
                // device and are what a support ticket screenshots.
                extras: [
                    "version": version,
                    "sdkVersion": version,
                    "environment": config.environment.name,
                ]
            )
        }
        if let config, let services {
            componentRegistry.configure(
                config: config,
                deviceId: services.identityManager.deviceId,
                isDebugBuild: isDebugBuild
            )
            if captureModeEnabled, isCaptureSupported {
                componentRegistry.setEnabled(true)
            } else if captureModeEnabled {
                setCaptureModeEnabled(false)
            }
            // Anchors that mounted before this point were buffered: an RN or
            // SwiftUI tree renders while the bundle is still being fetched.
            componentRegistry.attachPendingAnchors(to: _currentScreen)
            // A JS reload re-runs this whole method (RN calls
            // `populateCampaignBundle` again), which re-configures the
            // service below. Without this, any live-test invocation still
            // in flight from before the reload keeps its watchdog running
            // against post-reload state — a leak, not a failure, so it is
            // cancelled rather than ACKed.
            clearLiveTestState()
            liveTestService.configure(
                config: config,
                requestHeaders: requestHeaders,
                deviceId: services.identityManager.deviceId,
                isDebugBuild: isDebugBuild,
                onCampaignTest: { [weak self] invocation in self?.handleLiveTestCampaign(invocation)
                }
            )
        }

        // Last: the buffered delivery is routed against a populated store, a live
        // frequencyManager and a real screen — none of which existed when it arrived.
        flushPendingPayloadIfAny()
    }

    /// Retired RN entrypoint, kept only so an older `@digia-engage/core` bundle running
    /// against this core does not fail its own `initialize()`.
    ///
    /// Native now fetches the campaign bundle on every binding — see `initialize` — so
    /// accepting a second bundle here would re-run `completeInitialization` and swap the
    /// campaign store out from under whatever is already on screen. It does nothing; the
    /// fetch native already ran is the one that counts.
    func populateCampaignBundle(_ bundleJson: String) {
        log.d(
            "populateCampaignBundle() ignored — native owns the campaign fetch on every "
                + "binding (bundle bytes=\(bundleJson.utf8.count))"
        )
    }

    func setThemeMode(_ mode: DigiaThemeMode) { CampaignCanvasTheme.shared.update(mode) }

    private func logVerbose(_ message: String) {
        log.d(message)
    }

    private func logError(_ message: String) {
        log.e(message)
    }

    /// Which fetch failure a campaign creator is looking at.
    ///
    /// A rejected key is the one init failure a customer can fix themselves.
    private static func fetchFailureReason(_ failure: CampaignFetchError?) -> TimelineReason {
        failure?.statusCode == 401 || failure?.statusCode == 403
            ? .fetchFailedAuth
            : .fetchFailedNetwork
    }

    func register(_ plugin: DigiaCEPPlugin) {
        if let outgoing = activePlugin {
            // G6 — settle everything the outgoing plugin owns *before* calling
            // `detach()`, so its own outcome handlers run while its bridge is
            // still alive. Reversing these two lines is the leak itself.
            coordinator.detach(owner: outgoing.id)
            outgoing.detach()
        }
        activePlugin = plugin
        plugin.attach(host: self)
        log.i(
            "Plugin registered (plugin=\(plugin.id))",
            stage: .session,
            reason: TimelineReason.pluginRegistered,
            extras: ["plugin": plugin.id]
        )
        if let screen = _currentScreen {
            plugin.onScreenChanged(screen)
        }
    }

    // MARK: - DigiaCEPHost

    /// Delivers a CEP trigger into the Digia engine.
    ///
    /// Total and synchronous: it never fails, always returns a handle, and a
    /// rejection comes back as an *already settled* presentation so the caller
    /// has one code path either way. Never make this `async` — spec §10.3.
    func deliver(_ trigger: CEPTriggerPayload) -> CampaignPresentation {
        let controller = coordinator.open(trigger, owner: activePlugin?.id ?? "")
        // Before routing, so a trigger that is turned away still shows up on
        // the timeline as having arrived. "Nothing happened at all" and "it
        // arrived and we turned it away" are the two answers a campaign creator
        // most needs to tell apart.
        observeDelivery(controller)
        routeNow(controller)
        return controller.presentation
    }

    /// Delivers the campaign published under `campaignKey`, with no CEP involved.
    ///
    /// The Swift twin of Kotlin's `DigiaInstance.triggerCampaign`. Same machinery a plugin
    /// delivery gets — one presentation, the same state gate, the same routing, the same
    /// watchdogs — because the difference between "CleverTap asked for this" and "the app
    /// asked for this" ends at who supplied the trigger.
    ///
    /// The host is not a CEP and holds no slot, so it mints its own `cepCampaignId`: a
    /// presentation still needs one for analytics dedup and for the logs to be readable, and
    /// an id that collided across triggers would make two firings of the same campaign look
    /// like one.
    func triggerCampaign(_ campaignKey: String, variables: [String: String]?)
        -> CampaignPresentation
    {
        let trigger = CEPTriggerPayload(
            cepCampaignId: "host:\(UUID().uuidString)",
            campaignKey: campaignKey.trimmingCharacters(in: .whitespacesAndNewlines),
            cepMetadata: [:],
            variables: variables
        )
        let controller = coordinator.open(trigger, owner: Self.hostOwner)
        observeDelivery(controller)
        if sdkState == .ready {
            routeNow(controller)
        } else {
            bufferUntilReady(controller)
        }
        return controller.presentation
    }

    /// Owner recorded for a delivery the host app asked for itself, with no CEP involved.
    private static let hostOwner = "<host>"

    /// Routes a delivery against the store as it stands right now.
    private func routeNow(_ controller: PresentationController) {
        // Routing must see the stamped payload: it is the instance every render
        // surface stores and hands back, and the only thing that leads an event
        // back to this presentation.
        switch routeOrganicTrigger(controller.trigger) {
        case .accepted(let payload, let kind):
            coordinator.accept(controller, kind: kind)
            if awaitsAnchorLayout(payload) { coordinator.awaitAnchor(payload) }
        case .dropped(let reason, let detail):
            controller.settle(.dropped(reason: reason, detail: detail))
        }
    }

    /// Holds a trigger that arrived before the campaign bundle.
    ///
    /// Only one is held, matching Kotlin: a second trigger before the fetch resolves wins, and
    /// the older presentation *settles* rather than being forgotten, so whoever is holding a
    /// slot for it gets it back instead of holding it for the session.
    ///
    /// **Only `triggerCampaign` routes through this today.** `deliver` still refuses a
    /// pre-bundle trigger outright with `notInitialized`, where Kotlin buffers it — a real
    /// divergence, and a real bug now that native owns the fetch and the window is a live
    /// second or two of CEP deliveries. It is left alone here on purpose: iOS has two tests
    /// that pin the refusing behaviour as a contract (`deliver is total …`, `a trigger before
    /// the bundle lands is not_initialized …`) plus nine more that populate the store without
    /// marking the SDK ready, so changing `deliver` is its own pass, not a rider on this one.
    private func bufferUntilReady(_ controller: PresentationController) {
        if let displaced = pendingPresentation {
            log.w(
                "Buffered trigger displaced (by=\(controller.trigger.campaignKey))",
                campaign: displaced.trigger.campaignKey
            )
            displaced.settle(
                .dropped(
                    reason: .superseded,
                    detail: "a newer trigger arrived while the SDK was still initializing"
                )
            )
        }
        log.d(
            "Queued — the SDK is still initializing "
                + "(cepCampaignId=\(controller.trigger.cepCampaignId))",
            campaign: controller.trigger.campaignKey
        )
        pendingPresentation = controller
    }

    /// Routes whatever was held while the bundle was in flight. Called once the store is
    /// populated, which is the first moment the screen and frequency gates mean anything.
    private func flushPendingPayloadIfAny() {
        guard let pending = pendingPresentation else { return }
        pendingPresentation = nil
        routeNow(pending)
    }

    /// Whether this campaign cannot appear until a named anchor resolves — the
    /// anchor watchdog's one arming condition.
    private func awaitsAnchorLayout(_ payload: CEPTriggerPayload) -> Bool {
        guard let guide = findCampaign(payload)?.guideConfig, !guide.isAnchorless else {
            return false
        }
        return guide.steps.first?.target.anchorKey != nil
    }

    /// The ordered teardown a cancelled or timed-out presentation runs — the
    /// same surfaces `onCampaignInvalidated` used to take down under v1, now
    /// reached through ``CampaignPresentation/cancel()``.
    private func dismissSurfaces(forCepCampaignId campaignID: String) {
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

    func setCurrentScreen(_ name: String) {
        screenUpdateRevision += 1
        let revision = screenUpdateRevision
        let screenName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousScreen = _currentScreen
        _currentScreen = screenName.isEmpty ? nil : screenName
        // Pushed rather than pulled: staged records are emitted from threads
        // that cannot read main-actor state. See `DigiaLogger.currentScreenName`.
        DigiaLogger.currentScreenName = _currentScreen
        log.d("Current screen set (screen=\(_currentScreen ?? "<unset>"))")
        componentRegistry.recordPage(screenName)
        componentRegistry.attachPendingAnchors(to: _currentScreen)
        if previousScreen != _currentScreen {
            dismissActiveCampaignsNotTargetingCurrentScreen()
        }
        if screenUpdateRevision == revision {
            activePlugin?.onScreenChanged(screenName)
        }
    }

    func setCaptureModeEnabled(_ enabled: Bool) {
        guard !enabled || (isDebugBuild && isCaptureSupported) else { return }
        captureModeEnabled = enabled
        storage.scoped("capture").set(enabled, forKey: "enabled")
        componentRegistry.setEnabled(enabled)
        if enabled { debugOverlayController.setVisible(true) }
    }

    func setCaptureProfile(
        includeText: Bool? = nil,
        includeMedia: Bool? = nil,
        includeStructure: Bool? = nil
    ) {
        let captureStorage = storage.scoped("capture")
        if let includeText {
            captureTextEnabled = includeText
            captureStorage.set(includeText, forKey: "include_text")
        }
        if let includeMedia {
            captureMediaEnabled = includeMedia
            captureStorage.set(includeMedia, forKey: "include_media")
        }
        if let includeStructure {
            captureStructureEnabled = includeStructure
            captureStorage.set(includeStructure, forKey: "include_structure")
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

            let upload = await URLSessionCaptureUploader(apiKey: config.apiKey, networkClient: networkClient).upload(
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
                dismiss: { markNudgeDismissed(reason: .screenExit) }
            )
        }

        if let survey = surveyOrchestrator.state {
            dismissForScreenChangeIfNeeded(
                campaignKey: survey.payload.campaignKey,
                campaignType: "survey",
                campaign: campaignStore.find(survey.payload.campaignKey),
                dismiss: { markSurveyDismissed(reason: .screenExit) }
            )
        }

        if let guide = guideOrchestrator.state {
            if let pageKey = guide.steps.first?.target.anchorlessTarget?.pageKey,
               pageKey != _currentScreen {
                liveTestContexts[guide.payload.cepCampaignId]?.reportFailed(
                    DropReason.screenNotTargeted,
                    message: "screen changed before the Guide was shown"
                )
                dismissGuide(reason: .screenExit)
            } else {
                dismissForScreenChangeIfNeeded(
                    campaignKey: guide.campaign.campaignKey,
                    campaignType: "guide",
                    campaign: guide.campaign,
                    dismiss: {
                        self.liveTestContexts[guide.payload.cepCampaignId]?.reportFailed(
                            DropReason.screenNotTargeted,
                            message: "screen changed before the Guide was shown"
                        )
                        self.dismissGuide(reason: .screenExit)
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
                events.toCep(.dismissed(reason: .screenExit), payload: guide.payload)
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
        log.d(
            "Dismissed — screen changed (type=\(campaignType), "
                + "currentScreen=\(_currentScreen ?? "<unset>"), targets=\(targets))",
            campaign: campaignKey
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

    /// Cancels every in-flight live-test watchdog and drops its bookkeeping,
    /// without posting an ACK — an abandoned invocation is not a failed one,
    /// and the dashboard's own `no_response` alarm is what accounts for it
    /// from here. Called whenever the live-test service is (re)configured, so
    /// an RN JS reload can never leave a stale context's watchdog running
    /// against post-reload state.
    private func clearLiveTestState() {
        liveTestContexts.values.forEach { $0.invalidate() }
        liveTestContexts.removeAll()
        liveTestCampaigns.removeAll()
    }

    /// Exposes bubble visibility to `RecordingBadgeView` and `DigiaDebugSettingsView`.
    func debugOverlayControllerSnapshot() -> DigiaDebugOverlayController {
        debugOverlayController
    }

    func onHostMounted() {
        isHostMounted = true
    }

    func onHostUnmounted() {
        isHostMounted = false
    }

    /// Routes an organically delivered trigger and answers what happened to it.
    ///
    /// The verdict — not a boolean — is what a plugin holding a CEP slot needs:
    /// `unknown_campaign_key` and `frequency_capped` are the same "false" to a
    /// caller that can only see accepted/not, and only one of them is a bug.
    @discardableResult
    func routeOrganicTrigger(_ payload: CEPTriggerPayload) -> RoutingVerdict {
        lastCampaignDropReason = nil
        logVerbose(
            "deliver cepCampaignId='\(payload.cepCampaignId)' "
                + "campaignKey='\(payload.campaignKey)'")
        // Route purely by the campaignKey resolved from the store (mirrors
        // Android) — fall back to cepCampaignId when no campaignKey was supplied.
        let key = payload.campaignKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedKey =
            key.isEmpty
            ? payload.cepCampaignId.trimmingCharacters(in: .whitespacesAndNewlines)
            : key
        guard !resolvedKey.isEmpty, let campaign = campaignStore.find(resolvedKey) else {
            lastCampaignDropReason = "no native campaign for key '\(resolvedKey)'"
            logError(
                "campaign dropped — no campaign for key '\(resolvedKey)' knownKeys=[\(campaignStore.keys.joined(separator: ", "))]"
            )
            // An empty store before the bundle lands is not an unknown key — it
            // is a trigger that arrived before there was anything to look it up
            // in, and the two want different fixes from whoever reads the drop.
            let missedInit = sdkState != .ready && campaignStore.keys.isEmpty
            return .dropped(
                reason: missedInit ? .notInitialized : .unknownCampaignKey,
                detail: missedInit
                    ? "trigger arrived before the campaign bundle (state=\(sdkState))"
                    : "no campaign for key '\(resolvedKey)'"
            )
        }
        return route(
            campaign, payload: payload,
            context: OrganicRoutingContext(frequencyManager: frequencyManager))
    }

    /// Abstracts the two points where `route` otherwise diverges between an
    /// organic trigger and a live test — frequency capping, and how a
    /// routed/dropped campaign reports back — so the routing switch itself never
    /// branches on which one this is.
    @MainActor
    private protocol RoutingContext {
        func isFrequencyCapped(campaignKey: String, policy: FrequencyPolicy?) -> Bool
        func onInlineRouted(payload: CEPTriggerPayload)
        func onDropped(_ code: DiagnosticReason, message: String)
    }

    @MainActor
    private struct OrganicRoutingContext: RoutingContext {
        let frequencyManager: FrequencyManager?

        func isFrequencyCapped(campaignKey: String, policy: FrequencyPolicy?) -> Bool {
            guard
                let reason = frequencyManager?.blockReason(campaignKey: campaignKey, policy: policy)
            else {
                return false
            }
            log.d(
                "Dropped — frequency capped (rule=\(reason), "
                    + "policy=\(String(describing: policy)))",
                campaign: campaignKey
            )
            return true
        }

        func onInlineRouted(payload: CEPTriggerPayload) {
            // Inline impressions are reported when the slot first renders.
        }

        func onDropped(_ code: DiagnosticReason, message: String) {
            // Nothing to report organically — the caller already logged why.
        }
    }

    @MainActor
    private final class LiveTestRoutingContext: RoutingContext {
        private let testContext: LiveTestContext

        init(testContext: LiveTestContext) {
            self.testContext = testContext
        }

        func isFrequencyCapped(campaignKey: String, policy: FrequencyPolicy?) -> Bool { false }

        func onInlineRouted(payload: CEPTriggerPayload) {
            // No synchronous way to know a matching DigiaSlot exists anywhere
            // in the app, so the invocation's own watchdog stands in for the
            // anchor check a guide gets — this only narrows its verdict to
            // the inline one. reportSlotFirstRender's shown ACK wins the race
            // if a slot renders first (LiveTestContext is idempotent).
            testContext.expectSlotToMount()
        }

        func onDropped(_ code: DiagnosticReason, message: String) {
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
    ) -> RoutingVerdict {
        let key = campaign.campaignKey
        if !campaign.targetScreenNames.isEmpty
            && !campaign.targetScreenNames.contains(_currentScreen ?? "")
        {
            lastCampaignDropReason =
                "screen not targeted: currentScreen=\(_currentScreen ?? "<unset>") targetScreenNames=\(campaign.targetScreenNames)"
            log.d(
                "Dropped — screen not targeted (current=\(_currentScreen ?? "<unset>"), "
                    + "targets=\(campaign.targetScreenNames))",
                campaign: key
            )
            context.onDropped(DropReason.screenNotTargeted, message: "screen not targeted")
            return .dropped(
                reason: .screenNotTargeted,
                detail:
                    "currentScreen=\(_currentScreen ?? "<unset>") targetScreenNames=\(campaign.targetScreenNames)"
            )
        }

        logVerbose("routeByCampaignKey key='\(key)' type='\(campaign.campaignType)'")
        switch campaign.config {
        case .inline(let cfg):
            logVerbose(
                "routeByCampaignKey INLINE slotKey='\(cfg.slotKey)' items=\(cfg.items.count)")
            inlineController.setCarouselConfig(cfg.slotKey, config: cfg)
            inlineController.setCampaign(cfg.slotKey, payload: payload)
            context.onInlineRouted(payload: payload)
            return .accepted(payload: payload, kind: .inline)
        case .banner(let cfg):
            inlineController.setBannerConfig(cfg.slotKey, config: cfg)
            inlineController.setCampaign(cfg.slotKey, payload: payload)
            context.onInlineRouted(payload: payload)
            return .accepted(payload: payload, kind: .inline)
        case .inlineCanvas(let cfg):
            logVerbose("routeByCampaignKey INLINE CANVAS slotKey='\(cfg.slotKey)'")
            if let runtime = cfg.statefulTimer, runtime.resolve(payload.variables) == nil {
                let reason = "inline timer campaign has invalid runtime variables"
                lastCampaignDropReason = reason
                log.e("Dropped — \(reason)", campaign: key)
                context.onDropped(DropReason.invalidConfig, message: reason)
                return .dropped(reason: .invalidConfig, detail: reason)
            }
            inlineController.setCanvasConfig(cfg.slotKey, config: cfg)
            inlineController.setCampaign(cfg.slotKey, payload: payload)
            context.onInlineRouted(payload: payload)
            return .accepted(payload: payload, kind: .inline)
        case .story(let cfg):
            inlineController.setStoryConfig(cfg.slotKey, config: cfg)
            inlineController.setCampaign(cfg.slotKey, payload: payload)
            context.onInlineRouted(payload: payload)
            return .accepted(payload: payload, kind: .inline)
        case .guide(let guideConfig):
            if !guideConfig.isAnchorless,
               config?.wrapperBinding == "react_native",
               guideConfig.steps.allSatisfy({ $0.widgetConfig.layoutMode != "canvas" })
            {
                guard let renderViaJs = onGuideRenderRequest else {
                    let message = "React Native guide renderer is not registered"
                    lastCampaignDropReason = message
                    context.onDropped(DropReason.hostNotMounted, message: message)
                    logNativeGuideStage("route", "result=dropped reason=js_renderer_missing campaign_key=\(key)")
                    return .dropped(reason: .hostNotMounted, detail: message)
                }
                if context.isFrequencyCapped(campaignKey: key, policy: campaign.frequency) {
                    lastCampaignDropReason = "frequency capped"
                    return .dropped(reason: .frequencyCapped, detail: nil)
                }
                activeExternalGuide = ExternalGuide(campaign: campaign, payload: payload)
                // `payload` was stamped by `coordinator.open()` before routing
                // ever saw it, so this is only ever empty for a delivery that
                // bypassed that stamp — a live test's synthesised payload. The
                // fallback is a harmless dead id rather than a crash: it simply
                // never resolves in `reportExternalGuideLifecycle`.
                renderViaJs(
                    GuideRenderRequest(
                        payload: payload,
                        presentationId: payload.presentationId ?? "",
                        campaignId: campaign.id,
                        templateConfigJson: campaign.guideTemplateJson
                    )
                )
                return .accepted(payload: payload, kind: .modal)
            }
            if context.isFrequencyCapped(campaignKey: key, policy: campaign.frequency) {
                lastCampaignDropReason = "frequency capped"
                logNativeGuideStage("route", "result=dropped reason=frequency_capped campaign_key=\(key)")
                return .dropped(reason: .frequencyCapped, detail: nil)
            }
            guard guideConfig.steps.allSatisfy({ $0.widgetConfig.canvas != nil }) else {
                let message = "campaign has no valid Canvas guide content"
                lastCampaignDropReason = message
                context.onDropped(DropReason.invalidConfig, message: message)
                log.e("Dropped — \(message)", campaign: key)
                return .dropped(reason: .invalidConfig, detail: message)
            }
            if guideOrchestrator.state != nil, !guideConfig.steps.isEmpty { dismissGuide() }
            guard guideOrchestrator.start(campaign, payload: payload) else {
                lastCampaignDropReason = "another guide is already on screen"
                context.onDropped(DropReason.surfaceBusy, message: "another guide is already on screen")
                logNativeGuideStage("route", "result=dropped reason=guide_active campaign_key=\(key)")
                return .dropped(reason: .surfaceBusy, detail: "another guide is already on screen")
            }
            guideCompletionFired = false
            logNativeGuideStage("route", "result=accepted campaign_key=\(key)")
            return .accepted(payload: payload, kind: .modal)
        case .nudge(let nudgeConfig):
            if context.isFrequencyCapped(campaignKey: key, policy: campaign.frequency) {
                lastCampaignDropReason = "frequency capped"
                return .dropped(reason: .frequencyCapped, detail: nil)
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
            return .accepted(payload: payload, kind: .modal)
        case .survey(let cfg):
            if context.isFrequencyCapped(campaignKey: key, policy: campaign.frequency) {
                lastCampaignDropReason = "frequency capped"
                return .dropped(reason: .frequencyCapped, detail: nil)
            }
            let activeSurveyCepId = surveyOrchestrator.state?.payload.cepCampaignId
            let replaceActiveLiveTestCanvasSurvey =
                cfg.canvasSurvey != nil
                && isLiveTestCepId(payload.cepCampaignId)
                && activeSurveyCepId.map(isLiveTestCepId) == true
            if replaceActiveLiveTestCanvasSurvey {
                markSurveyDismissed()
                // Safe on anything, including a survey that already showed —
                // reportFailed is idempotent, so this only actually changes
                // the outcome of a test displaced before it ever appeared.
                supersedeLiveTest(activeSurveyCepId)
            }
            let started = surveyOrchestrator.start(
                payload: payload,
                config: cfg,
                allowActiveReplacement: replaceActiveLiveTestCanvasSurvey
            )
            if !started {
                lastCampaignDropReason = "another survey is already on screen"
                logVerbose("survey campaign dropped: another survey is on screen: \(key)")
                context.onDropped(DropReason.surfaceBusy, message: "another survey is already on screen")
                return .dropped(reason: .surfaceBusy, detail: "another survey is already on screen")
            }
            return .accepted(payload: payload, kind: .modal)
        // Both floater subtypes route through the same gate — a collapsed window of
        // either kind is the same third, non-blocking lane.
        case .floater, .floaterStory:
            if context.isFrequencyCapped(campaignKey: key, policy: campaign.frequency) {
                lastCampaignDropReason = "frequency capped"
                return .dropped(reason: .frequencyCapped, detail: nil)
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
                    DropReason.surfaceBusy,
                    message: "a nudge, survey, or expanded floater is already on screen")
                return .dropped(
                    reason: .surfaceBusy,
                    detail: "a nudge, survey, or expanded floater is already on screen")
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
                context.onDropped(DropReason.surfaceBusy, message: "another floater is already on screen")
                return .dropped(reason: .surfaceBusy, detail: "another floater is already on screen")
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
                    log.d(
                        "Dropped — story floater not started "
                            + "(reason=\(floaterStoryOrchestrator.lastStartFailureReason ?? "unknown"))",
                        campaign: key
                    )
                    context.onDropped(
                        DropReason.invalidConfig, message: "another floater is already on screen")
                    return .dropped(
                        reason: .invalidConfig,
                        detail: floaterStoryOrchestrator.lastStartFailureReason
                            ?? "story floater start failed")
                }
                return .accepted(payload: payload, kind: .floating)
            }
            let started = floaterOrchestrator.start(
                campaign, payload: payload, screenName: _currentScreen)
            if !started {
                lastCampaignDropReason =
                    floaterOrchestrator.lastStartFailureReason ?? "floater start failed"
                log.d(
                    "Dropped — floater not started (currentScreen=\(_currentScreen ?? "<unset>"), "
                        + "reason=\(floaterOrchestrator.lastStartFailureReason ?? "unknown"))",
                    campaign: key
                )
                context.onDropped(DropReason.invalidConfig, message: "another floater is already on screen")
                return .dropped(
                    reason: .invalidConfig,
                    detail: floaterOrchestrator.lastStartFailureReason ?? "floater start failed")
            }
            return .accepted(payload: payload, kind: .floating)
        }
    }

    /// Handles one `campaign_test` SSE event.
    ///
    /// The `catch` is the outermost half of "every invocation ends in a
    /// terminal ACK". This runs on an SSE callback with nothing above it, so
    /// without it a throw anywhere in parsing or routing would escape into
    /// the stream handler and the dashboard row would simply stop moving.
    private func handleLiveTestCampaign(_ invocation: LiveTestInvocation) {
        do {
            try routeLiveTestCampaign(invocation)
        } catch {
            log.e("Live test failed — routing threw", error: error)
            // Through the context when one exists, so the single-fire guard
            // holds and the watchdog is disarmed; directly otherwise, because
            // a throw before the context was built still owes the dashboard
            // an answer.
            let cepCampaignId = liveTestCepId(invocation.testInvocationId)
            if let context = liveTestContexts[cepCampaignId] {
                context.reportFailed(DropReason.error, message: "\(error)")
            } else {
                liveTestService.ackReporter.postFailed(
                    invocation.testInvocationId, code: DropReason.error, message: "\(error)")
            }
        }
    }

    private func routeLiveTestCampaign(_ invocation: LiveTestInvocation) throws {
        let reporter = liveTestService.ackReporter
        reporter.postReceived(invocation.testInvocationId)

        guard sdkState == .ready else {
            reporter.postFailed(
                invocation.testInvocationId, code: DropReason.notInitialized,
                message: "SDK not ready (state=\(sdkState))"
            )
            return
        }

        guard let campaignJson = invocation.campaign else {
            reporter.postFailed(
                invocation.testInvocationId, code: TimelineReason.malformedCampaignSkipped,
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
            devicePlatform: "ios",
            timeAnchor: currentTimeAnchor
        ) else {
            reporter.postFailed(
                invocation.testInvocationId, code: TimelineReason.malformedCampaignSkipped,
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
                invocation.testInvocationId, code: TimelineReason.campaignUnsupported,
                message:
                    "campaign type '\(campaign.campaignType)' is not supported for live testing yet"
            )
            return
        }

        if let guideConfig = campaign.guideConfig,
           guideConfig.steps.allSatisfy({ $0.widgetConfig.layoutMode != "canvas" })
        {
            reporter.postFailed(
                invocation.testInvocationId,
                code: TimelineReason.campaignUnsupported,
                message: "Classic Guides cannot be tested on a device"
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

        let cleanUpLiveTestState: () -> Void = { [weak self] in
            self?.liveTestContexts.removeValue(forKey: cepCampaignId)
            self?.liveTestCampaigns.removeValue(forKey: cepCampaignId)
            self?.events.resetImpression(cepCampaignId)
        }

        let testContext = LiveTestContext(
            testInvocationId: invocation.testInvocationId,
            reporter: reporter,
            onTerminal: cleanUpLiveTestState
        )
        liveTestContexts[cepCampaignId] = testContext
        liveTestCampaigns[cepCampaignId] = campaign

        let verdict = route(
            campaign,
            payload: payload,
            context: LiveTestRoutingContext(testContext: testContext)
        )
        guard verdict.isAccepted else {
            cleanUpLiveTestState()
            return
        }
        if campaign.guideConfig?.isAnchorless == false {
            verifyFirstLiveTestGuideAnchorAfterLayout(
                campaign: campaign,
                payload: payload,
                testContext: testContext
            )
        }
        if campaign.guideConfig != nil {
            // No per-kind timer here any more — the context's own
            // per-invocation watchdog (armed in its initializer) is what
            // gives up if the guide host never renders it, and this just
            // adds the guide-specific teardown that firing implies: a guide
            // that silently never appeared must not linger in
            // `guideOrchestrator.state`.
            testContext.onWatchdogFired = { [weak self] in
                guard let self, self.guideOrchestrator.state?.payload.cepCampaignId == cepCampaignId
                else { return }
                self.guideOrchestrator.dismiss()
                self.guideCompletionFired = false
            }
        }
    }

    private func verifyFirstLiveTestGuideAnchorAfterLayout(
        campaign: CampaignModel,
        payload: CEPTriggerPayload,
        testContext: LiveTestContext
    ) {
        guard let anchorKey = campaign.guideConfig?.steps.first?.target.anchorKey else { return }
        Task { [weak self] in
            await LiveTestFrameWaiter().wait()
            guard let self else { return }
            guard self.guideOrchestrator.state?.payload.cepCampaignId == payload.cepCampaignId
            else { return }
            if AnchorRegistry.shared.isRegistered(anchorKey) {
                if case .unavailable(.outsideViewport) = AnchorRegistry.shared.resolution(
                    for: anchorKey
                ) {
                    AnchorRegistry.shared.scrollToVisible(anchorKey)
                }
                if case .available = AnchorRegistry.shared.resolution(for: anchorKey) {
                    return
                }
            }
            testContext.reportFailed(
                DropReason.anchorNotRegistered,
                message: "anchor '\(anchorKey)' is not on screen"
            )
            self.guideOrchestrator.dismissIfActive(payloadId: payload.cepCampaignId)
            self.guideCompletionFired = false
        }
    }

    /// Ends the live test that owned `cepCampaignId`, if it was one. Every
    /// pre-emption should funnel through here so a test displaced by a newer
    /// one can never be the row that just stops ACKing.
    ///
    /// Safe to call on anything: not-a-live-test returns immediately, and
    /// `LiveTestContext` is single-fire, so a test that already reported
    /// `shown` keeps that answer. This only catches the ones displaced before
    /// they ever appeared.
    private func supersedeLiveTest(_ cepCampaignId: String?) {
        guard let cepCampaignId, isLiveTestCepId(cepCampaignId) else { return }
        liveTestContexts[cepCampaignId]?.reportFailed(
            DropReason.superseded,
            message: "superseded by a newer live test"
        )
    }

    private func replaceActiveLiveTestGuide() {
        if let state = guideOrchestrator.state,
           isLiveTestCepId(state.payload.cepCampaignId) {
            supersedeLiveTest(state.payload.cepCampaignId)
            guideOrchestrator.dismissIfActive(payloadId: state.payload.cepCampaignId)
            guideCompletionFired = false
        }
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

    func reportSurveyStartClicked() {
        guard let state = surveyOrchestrator.state else { return }
        events.clicked(payload: state.payload, elementId: "welcome_start")
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

        if answers.isEmpty {
            logVerbose("reportSurveyCompleted: skip submission — no answers")
            return
        }
        if isLiveTest {
            relayLiveTestSubmission(state: state, answers: answers)
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
        services?.submissionReporter.report(
            campaignId: campaignId,
            survey: state.config,
            answers: answers,
            startedAt: state.startedAt,
            userId: analyticsService?.userId
        )
    }

    /// Sends a live-tested survey's answers to the dashboard that asked for
    /// the test, through the live-only event passthrough (§2.3) rather than
    /// the real submission endpoint — one person pressing buttons during a
    /// test is not a respondent, and nothing here is stored.
    ///
    /// Built by the *same* `buildBody` the real submission uses, so what a PM
    /// reads during a test is the structure analytics would have recorded —
    /// not a second shape that can quietly drift from it.
    private func relayLiveTestSubmission(state: ActiveSurveyState, answers: [String: SurveyAnswer]) {
        guard let invocationId = testInvocationIdOf(state.payload.cepCampaignId) else { return }
        // Live-test campaigns are parsed on the spot and never added to
        // `campaignStore` — its own `id` (not the store's) is the only one in
        // scope here.
        guard let campaign = liveTestCampaigns[state.payload.cepCampaignId] else { return }
        let body = SurveySubmissionReporter.buildBody(
            campaignId: campaign.id,
            survey: state.config,
            answers: answers,
            startedAt: state.startedAt,
            now: Date(),
            userId: nil
        )
        guard let payload = body["payload"], let computed = body["computed"] else { return }
        logVerbose(
            "Live test submission relayed (answers=\(answers.count), invocationId=\(invocationId))")
        liveTestService.ackReporter.postEvent(
            invocationId,
            type: "survey_submission",
            payload: ["payload": payload, "computed": computed]
        )
    }

    /// Tells the dashboard how a live-tested experience ended. Not an ACK —
    /// `shown` is already terminal, and the invocation's state machine closing
    /// exactly once is the property the whole ACK contract is built on. This
    /// is live-only colour relayed through the passthrough event endpoint —
    /// nothing is stored anywhere.
    private func relayLiveTestDismissal(
        _ cepCampaignId: String, reason: DismissReason, completed: Bool
    ) {
        guard let invocationId = testInvocationIdOf(cepCampaignId) else { return }
        liveTestService.ackReporter.postEvent(
            invocationId,
            type: "dismissed",
            payload: ["reason": reason.wire, "completed": completed]
        )
    }

    func dismissCompletedSurvey() {
        markSurveyDismissed()
    }

    func markSurveyDismissed(
        abandonedAtItem: Int? = nil,
        answeredCount: Int? = nil,
        reason: DismissReason = .userClose
    ) {
        guard let state = surveyOrchestrator.state else { return }
        let completed = completedSurveyToken == state.token
        surveyOrchestrator.dismiss()
        events.toBoth(
            .dismissed(reason: completed ? .completed : reason, completed: completed),
            SurveyEvent.Dismissed(
                abandonedAtItem: completed ? nil : abandonedAtItem,
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
        let (hasAnalytics, _) = pendingLock.withLock { () -> (Bool, Void) in
            if analyticsService == nil {
                pendingClearUserId = false
                pendingUserId = userId
            }
            return (analyticsService != nil, ())
        }
        services?.identityManager.setUserId(userId)
        services?.sessionManager.reset()
        if hasAnalytics {
            analyticsService?.setUserId(userId)
        }
    }

    func clearUserId() {
        let (hasAnalytics, _) = pendingLock.withLock { () -> (Bool, Void) in
            if analyticsService == nil {
                pendingUserId = nil
                pendingClearUserId = true
            }
            return (analyticsService != nil, ())
        }
        services?.identityManager.clearUserId()
        services?.sessionManager.reset()
        if hasAnalytics {
            analyticsService?.clearUserId()
        }
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
        controller.startNudgeAutoDismiss()
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

    func reportPrimaryCTAClick(
        payload: CEPTriggerPayload? = nil, elementId: String, isPrimary: Bool
    ) {
        guard isPrimary, let payload = payload ?? controller.activeNudge?.payload else { return }
        events.clicked(payload: payload, elementId: elementId)
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
        ctaRole: String? = nil,
        timerContext: TimerEventContext? = nil
    ) {
        var event: EngageAnalyticsEvent = NudgeEvent.Clicked(
            elementId: elementId,
            ctaLabel: ctaLabel,
            actionType: actionType,
            actionUrl: actionUrl,
            ctaRole: ctaRole,
            timeToActionMs: dwellTracker.elapsedMs(payload.cepCampaignId)
        )
        if let timerContext { event = TimerAnalyticsEvent(event: event, timer: timerContext) }
        events.toDigia(event, payload: payload)
    }

    /// The author's Hide action removed an inline canvas from its slot.
    ///
    /// Bypasses the stickiness that keeps inline campaigns alive across
    /// navigation: an author who put a close control on the card is asking for
    /// exactly the opposite.
    func dismissInlineCanvas(
        slotKey: String,
        payload: CEPTriggerPayload,
        timerContext: TimerEventContext? = nil
    ) {
        if inlineController.getCampaign(slotKey) != payload { return }
        inlineController.dismissCampaign(slotKey)
        var event: EngageAnalyticsEvent = NudgeEvent.Dismissed(
            dwellMs: dwellTracker.consumeDwellMs(payload.cepCampaignId)
        )
        if let timerContext { event = TimerAnalyticsEvent(event: event, timer: timerContext) }
        events.toDigia(event, payload: payload)
    }

    func markNudgeDismissed(reason: DismissReason = .userClose) {
        guard let nudge = controller.activeNudge else { return }
        controller.dismissNudge()
        events.toBoth(
            .dismissed(reason: reason),
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
        _ state: ActiveFloaterState, _ reason: FloaterDismissReason, _ metrics: FloaterMetrics,
        _ wasVisible: Bool
    ) {
        if !wasVisible {
            events.toCep(.dismissed(reason: reason.presentationReason), payload: state.payload)
            return
        }
        events.toBoth(
            .dismissed(reason: reason.presentationReason),
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
        _ metrics: FloaterMetrics, _ wasVisible: Bool
    ) {
        if !wasVisible {
            events.toCep(.dismissed(reason: reason.presentationReason), payload: state.payload)
            return
        }
        events.toBoth(
            .dismissed(reason: reason.presentationReason),
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
                }, showStory: { [weak self] index in
                    self?.floaterStoryOrchestrator.openStory(initialIndex: index)
                })
            )
        }
    }

    // MARK: - Inline slot lifecycle
    //
    // Inline impressions fire at first render; dismissal fires at final removal.

    /// Resolves the campaign for `payload`: a live test's transient entry if
    /// present, else the real store. Every campaign-by-payload lookup should go
    /// through this — a lookup that only checks `campaignStore` silently misses
    /// for any live-tested campaign, since those are deliberately never added there.
    private func findCampaign(_ payload: CEPTriggerPayload) -> CampaignModel? {
        liveTestCampaigns[payload.cepCampaignId] ?? campaignStore.find(payload.campaignKey)
    }

    func reportSlotFirstRender(_ payload: CEPTriggerPayload) {
        guard let campaign = findCampaign(payload) else { return }
        if case .inlineCanvas(let cfg) = campaign.config, inlineController.getCampaign(cfg.slotKey) != payload { return }
        var timerState: ResolvedTimerCanvas?
        if case .inlineCanvas(let cfg) = campaign.config, let runtime = cfg.statefulTimer {
            guard let resolved = runtime.resolve(payload.variables), resolved.canvas != nil else { return }
            timerState = resolved
        }
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
            viewed = InlineCanvasEvent.Viewed(
                slotKey: cfg.slotKey,
                screenName: _currentScreen
            )
        default:
            return
        }
        if let resolved = timerState {
            events.digiaTimerStateImpressionOnce(
                payload: payload,
                stateID: resolved.stateID,
                event: TimerAnalyticsEvent(event: viewed, timer: resolved.analyticsContext)
            )
        } else {
            events.digiaImpressionOnce(payload: payload, event: viewed)
        }
    }

    func reportInlineTimerStateRender(
        payload: CEPTriggerPayload,
        config: InlineCanvasConfig,
        resolved: ResolvedTimerCanvas
    ) {
        guard config.statefulTimer != nil, inlineController.getCampaign(config.slotKey) == payload else { return }
        events.digiaTimerStateImpressionOnce(
            payload: payload,
            stateID: resolved.stateID,
            event: TimerAnalyticsEvent(
                event: InlineCanvasEvent.Viewed(
                    slotKey: config.slotKey,
                    screenName: _currentScreen
                ),
                timer: resolved.analyticsContext
            )
        )
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

    func reportClassicCarouselContainerClicked(_ payload: CEPTriggerPayload) {
        events.clicked(payload: payload, elementId: "carousel_container")
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
        events.toDigia(
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

    func reportClassicStoryOpened(_ payload: CEPTriggerPayload) {
        events.clicked(payload: payload, elementId: "story_thumbnail")
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

    func dismissGuide(reason: DismissReason = .userClose) {
        guard let state = guideOrchestrator.state else { return }
        let payload = state.payload
        let total = state.steps.count
        let elapsed = dwellTracker.consumeDwellMs(payload.cepCampaignId)
        if !guideCompletionFired, total > 1 {
            events.toDigia(
                GuideEvent.StepDismissed(itemIndex: state.stepIndex + 1),
                payload: payload
            )
        }
        guideOrchestrator.dismiss()
        events.toBoth(
            .dismissed(
                reason: guideCompletionFired ? .completed : reason,
                completed: guideCompletionFired
            ),
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
        let stepWasReported = lastReportedGuideStep.map {
            $0.token == state.token && $0.index == state.stepIndex
        } ?? false
        if state.currentStep?.target.anchorKey != nil {
            logNativeGuideStage(
                "render",
                "result=shown campaign_key=\(state.payload.campaignKey) step_index=\(state.stepIndex + 1)"
            )
        }
        let payload = state.payload
        let total = state.steps.count
        // The anchor produced a layout — that is exactly what the anchor
        // watchdog was waiting for.
        coordinator.anchorResolved(payload)
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
        if !stepWasReported && (total > 1 || state.currentStep?.target.anchorlessTarget != nil) {
            lastReportedGuideStep = (state.token, state.stepIndex)
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
            log.e(
                "Anchorless step render failed — \(failure?.rawValue ?? "image load failed") "
                    + "(step=\(state.stepIndex + 1))"
            )
        }
        let payload = state.payload
        if dwellTracker.elapsedMs(payload.cepCampaignId) == nil {
            guideOrchestrator.dismiss()
            // It never displayed, so this is a drop — and unlike a dismissal it
            // still knows *why*. Going through the lifecycle channel would
            // flatten every render failure to `cancelled`.
            coordinator.drop(
                payload,
                reason: Self.dropReason(for: failure),
                detail: failure?.rawValue ?? "Anchorless Spotlight image could not be loaded"
            )
            guideCompletionFired = false
        } else {
            dismissGuide(reason: .autoTimeout)
        }
        // Same mapping the organic drop two lines up just used — keeping a
        // second, live-test-only mapping beside it is exactly the two
        // spellings of one reason the shared vocabulary exists to prevent.
        liveTestContexts[payload.cepCampaignId]?.reportFailed(
            Self.dropReason(for: failure),
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

    /// The honest drop reason for a guide that failed to produce a frame.
    ///
    /// The live-test path maps the same failures onto its own codes a few lines
    /// below; these are the ones a plugin and the analytics backend see.
    private static func dropReason(for failure: AnchorlessFailure?) -> DropReason {
        switch failure {
        case .pageKeyMismatch: return .screenNotTargeted
        case .invalidTarget, .invalidGeometry: return .anchorNotRegistered
        case .unsupportedLayout: return .invalidConfig
        case nil: return .error
        }
    }

    private func logNativeGuideStage(_ stage: String, _ details: String) {
        guard config?.wrapperBinding == "react_native" else { return }
        log.d("Guide stage: \(stage) \(details)")
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
        // The presentation is native even when the guide is not: under v2 the
        // CEP's hold belongs to core, so a JS-rendered guide's lifecycle has to
        // reach the coordinator or its plugin never learns the showing ended.
        if let payload {
            switch eventName {
            case "Digia Experience Viewed":
                events.toCep(.impressed, payload: payload)
            case "Digia Experience Dismissed":
                events.toCep(.dismissed(reason: .userClose), payload: payload)
            case "Digia Experience Completed":
                events.toCep(
                    .dismissed(reason: .completed, completed: true), payload: payload)
            default:
                break
            }
        }
        if (eventName == "Digia Experience Dismissed"
            || eventName == "Digia Experience Completed")
            && activeExternalGuide?.payload.cepCampaignId == payloadID
        {
            activeExternalGuide = nil
        }
    }

    /// Drives the real presentation an externally-rendered guide's render
    /// surface (the RN bridge) is reporting lifecycle for.
    ///
    /// `presentationId` unknown, or already settled, is a silent no-op: the
    /// coordinator forgets a presentation's id the moment it settles, so a
    /// stale id — a Metro reload reporting against a presentation native
    /// already settled on its own, e.g. through a screen change or the
    /// acceptance watchdog — simply resolves to nothing here. That is a
    /// designed race, never an error, so it never traps.
    func reportExternalGuideLifecycle(presentationId: String, event: ExternalGuideLifecycleEvent) {
        guard let controller = coordinator.controller(forPresentationId: presentationId) else {
            log.d(
                "reportExternalGuideLifecycle: no-op — unknown or already-settled presentation",
                presentationId: presentationId
            )
            return
        }
        switch event {
        case .displaying:
            controller.markDisplaying()
        case .clicked(let elementId):
            controller.emitClicked(elementId: elementId)
        case .settled(let outcome):
            controller.settle(outcome)
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
        if let plugin = activePlugin {
            coordinator.detach(owner: plugin.id)
            plugin.detach()
        }
        activePlugin = nil
        _currentScreen = nil
        services?.tearDown()
        services = nil
        campaignStore.clear()
        liveTestService.stop()
        config = nil
        hostActionExecutor.clearHandlers()
        sdkState = .notInitialized
        isHostMounted = false
        font = DigiaFont()
        currentDesignTokens = .empty
        currentTimeAnchor = nil
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
        coordinator.resetForTesting()
        clearLiveTestState()
        pendingLock.withLock {
            pendingUserId = nil
            pendingClearUserId = false
        }
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
