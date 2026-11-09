import Combine
import Foundation
import UIKit

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

@MainActor
final class SDKInstance: ObservableObject, DigiaCEPHost {
    static let shared: SDKInstance = {
        let instance = SDKInstance(
            defaults: UserDefaults(suiteName: "tech.digia.engage") ?? .standard,
            legacyDefaults: .standard,
            makeNetworkClient: { currentSession in
                URLSessionNetworkClient(
                    sessionIdProvider: { currentSession.sessionId },
                    headerProvider: { currentSession.requestHeaders }
                )
            },
            makeAnalyticsQueue: { legacyStorage in
                SQLiteAnalyticsQueue(
                    opener: AnalyticsDatabaseOpener(),
                    legacyImport: LegacyQueueImport(source: legacyStorage)
                )
            },
            makeNetworkMonitor: { PathNetworkMonitor() }
        )
        // Only the production instance: a test's own instance must not take
        // over the process-wide registry's hook.
        AnchorRegistry.shared.setAnchorSeenHandler { [weak instance] key in
            instance?.recordAnchorSeen(key)
        }
        return instance
    }()

    struct ExternalGuide {
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
    @Published private(set) var sdkState: SDKState = .notInitialized {
        didSet {
            guard sdkState != oldValue, let plugin = activePlugin, plugin !== pendingAttach else { return }
            if sdkState == .ready { plugin.onHostReady() }
            if sdkState == .failed { plugin.onHostInitFailed() }
        }
    }
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
        onCancelSurface: { [weak self] payload in
            self?.dismissSurfaces(for: payload)
        }
    )
    private let hostActionExecutor = HostActionExecutor()
    private lazy var actionExecutor = EngageActionExecutor(
        hostActionExecutor: hostActionExecutor
    )
    var font = DigiaFont()
    /// Mirrors Android's `ScreenTracker`: the last screen name reported via
    /// `Digia.setCurrentScreen`, forwarded to the active plugin and read into
    /// analytics events (`screenName`).
    private var _currentScreen: String?
    internal var currentScreenForAnchorless: String? { _currentScreen }
    /// Whether the host app asked campaign overlays to stay off screen
    /// (`Digia.setCampaignsSuppressed`). In memory only and `false` on cold
    /// start; settable before `initialize()` and untouched by
    /// `setUserId`/`clearUserId`. While set, overlay deliveries (nudge, guide,
    /// floater, survey) drop as `host_suppressed` — inline keeps rendering and
    /// anything already showing is left alone.
    private(set) var campaignsSuppressed = false
    var activeExternalGuide: ExternalGuide?
    private var screenUpdateRevision = 0
    private var captureInFlight = false
    /// The design tokens the current campaign bundle was parsed with.
    ///
    /// Held because live test parses a campaign that never came through the
    /// bundle, and it has to resolve the same tokens the bundle's campaigns do.
    private var currentDesignTokens = DesignTokenCatalog.empty
    private var currentTimeAnchor: TrustedTimeAnchor?

    /// Built once in `initialize(_:)`, after the storage migration ran (D1).
    /// Nil before that: anything needed earlier is owned directly below.
    private(set) var services: SDKServices?

    var anonymousId: String { services?.identityManager.deviceId ?? "" }

    // Pre-init collaborators: `SDKInstance`-owned buffers used before
    // `initialize()` (anchor buffering, the debug screens, capture toggles),
    // so they live here rather than in `services` (D1). `init` is their
    // composition root: the only place outside `SDKServices` that scopes
    // storage or builds a collaborator. The services themselves take storage
    // as given and have no fallbacks (D6).
    private let storage: LocalStorage
    private let healthSink: HealthSink
    /// Owns the analytics database file for the life of the process. Lives
    /// here rather than in ``SDKServices`` so a retried `initialize()` reuses
    /// it: a second queue on the same file would interleave with the first.
    private let analyticsQueue: any AnalyticsQueueProtocol
    /// One per services graph: its analytics service stops it on teardown.
    private let makeNetworkMonitor: () -> any NetworkMonitor
    /// The capture toggles `SDKInstance` itself persists.
    private let captureStorage: LocalStorage
    let networkClient: any NetworkClient
    /// Where `networkClient` reads `X-Digia-Session-Id` from, per request.
    private let currentSession = CurrentSessionRef()
    let campaignStore: CampaignStore
    let componentRegistry: ComponentRegistryService
    let liveTestService: LiveTestService

    /// A `setUserId` / `clearUserId` that arrived before `services` existed.
    /// Only the last one matters; it is applied once, when services are built.
    private enum PendingUserChange {
        case set(String)
        case clear
    }
    private var pendingUserChange: PendingUserChange?

    // DMC: the Digia-decided campaign engine and the state its wiring keeps
    // (see SDKInstance+DMC.swift). Stored here because extensions cannot.
    /// Decides which Digia-owned campaign each rule signal shows.
    lazy var engine = makeDecisionEngine()
    /// The app is not on screen.
    var inBackground = false
    /// Whether the process started while the app was not on screen. A seam so
    /// a test can launch in the background.
    var launchedInBackground: @MainActor () -> Bool = {
        UIApplication.shared.applicationState == .background
    }

    /// The clock waits are stored on. A seam so a test can move time by hand.
    var waitClock: () -> Int = MonotonicClock.nowMs
    /// The process started in the background, so `app_opened` waits for the
    /// first return to the foreground.
    var appOpenedDue = false
    /// Cold starts on this phone, the `device.app_opens` rule fact.
    var appOpens = AppOpensCounter()
    /// Anchor and slot keys that already sent their signal this session.
    var visibleSent: Set<String> = []
    /// Firings of Digia-decided campaigns, so each gets its own `cepCampaignId`.
    var selfTriggerCount = 0
    private let defaults: UserDefaults
    private let legacyDefaults: UserDefaults
    /// The session clock handed to `SDKServices`. Only tests replace it.
    private let clock: () -> Int64

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
    /// Every place a campaign can occupy the screen, asked in this order. Only
    /// the occupant order depends on it: it is the order a live test supersedes
    /// occupants in, and which of two blockers in one column is reported.
    lazy var surfaces: [any CampaignSurface] = [
        nudgeSurface, surveySurface, guideSurface, pipSurface, floaterStorySurface, inlineSurface,
    ]
    lazy var nudgeSurface = NudgeCampaignSurface(self)
    lazy var surveySurface = SurveySurface(self)
    lazy var guideSurface = GuideSurface(self)
    lazy var pipSurface = PipSurface(self)
    lazy var floaterStorySurface = FloaterStorySurface(self)
    lazy var inlineSurface = InlineSurface(self)

    /// What every surface's reporter reads from the SDK.
    ///
    /// Hooks are closures, not tear-offs, so building an orchestrator does not
    /// build the reporter that reads it.
    lazy var surfaceContext = SurfaceContext(sdk: self)

    // Each surface reports its own lifecycle; renderers reach it through these.
    lazy var nudgeOrchestrator = NudgeOrchestrator(surfaceContext)
    lazy var surveyReporter = SurveyReporter(surfaceContext, surveyOrchestrator)
    lazy var pipReporter = PipReporter(surfaceContext, floaterOrchestrator)
    lazy var floaterStoryReporter = FloaterStoryReporter(surfaceContext, floaterStoryOrchestrator)
    lazy var inlineReporter = InlineReporter(surfaceContext, inlineController)
    lazy var storyReporter = StoryReporter(surfaceContext)
    /// Wired to `floaterOrchestrator.setAppForegrounded` in `init()` — matches
    /// Android's `DigiaInstance.kt` `ProcessLifecycleOwner` `ON_START`/`ON_STOP`
    /// observer, pausing/resuming the floater's video when the app backgrounds.
    private var appBackgroundObserver: NSObjectProtocol?
    private var appForegroundObserver: NSObjectProtocol?

    /// Whether the floating "Digia" debug bubble is shown. See
    /// `DigiaDebugOverlayController`.
    private let debugOverlayController: DigiaDebugOverlayController
    /// Live-test campaigns, parsed on the spot — never added to `campaignStore`.
    var liveTestCampaigns: [String: CampaignModel] = [:]
    /// In-flight live test invocations, keyed by synthetic `cepCampaignId`.
    var liveTestContexts: [String: LiveTestContext] = [:]
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
    let dwellTracker = DwellTracker()
    var events: EngageEventEmitter!

    /// `shared` is the only production instance. Tests build their own with
    /// isolated defaults, a fake network client and, to simulate time, a clock.
    init(
        defaults: UserDefaults,
        legacyDefaults: UserDefaults,
        makeNetworkClient: (CurrentSessionRef) -> any NetworkClient,
        clock: @escaping () -> Int64 = SessionManager.systemClock,
        makeAnalyticsQueue: (_ legacyStorage: LocalStorage) -> any AnalyticsQueueProtocol = { _ in
            MemoryAnalyticsQueue()
        },
        makeNetworkMonitor: @escaping () -> any NetworkMonitor = { AlwaysOnlineNetworkMonitor() },
        healthSink: HealthSink = .shared
    ) {
        self.makeNetworkMonitor = makeNetworkMonitor
        self.healthSink = healthSink
        self.defaults = defaults
        self.legacyDefaults = legacyDefaults
        self.clock = clock
        LocalStorageMigrator.migrateIfNeeded(targetDefaults: defaults, standardDefaults: legacyDefaults)
        let defaultStorage = UserDefaultsLocalStorage(defaults: defaults)
        // After the migrator, which moves the legacy queue into this suite.
        self.analyticsQueue = makeAnalyticsQueue(defaultStorage.scoped("analytics"))
        let defaultNetworkClient = makeNetworkClient(currentSession)
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
            ackReporter: LiveTestAckReporter(networkClient: defaultNetworkClient),
            networkClient: defaultNetworkClient
        )

        let captureStorage = defaultStorage.scoped("capture")
        self.captureStorage = captureStorage
        self.captureModeEnabled = captureStorage.bool(forKey: "enabled")
        self.captureTextEnabled = captureStorage.bool(forKey: "include_text")
        self.captureMediaEnabled = captureStorage.bool(forKey: "include_media")
        self.captureStructureEnabled = captureStorage.bool(forKey: "include_structure")

        events = EngageEventEmitter(
            cep: PresentationSink { [weak self] in self?.coordinator },
            digia: DigiaAnalyticsSink(
                getAnalyticsService: { [weak self] in self?.services?.analyticsService },
                getCampaign: { [weak self] key in self?.campaignStore.find(key) }
            ),
            onLiveTestShown: { [weak self] cepCampaignId in
                self?.liveTestContexts[cepCampaignId]?.reportShown()
            },
            onLiveTestDismissed: { [weak self] cepCampaignId, reason, completed in
                self?.relayLiveTestDismissal(cepCampaignId, reason: reason, completed: completed)
            }
        )
        inlineController.onCampaignRemoved = { [weak self] payload, reason in
            // Removed before its impression: delivery detail says what actually
            // happened.
            if reason != .superseded, let presentation = self?.coordinator.ownerOf(payload),
               presentation.state == .pending
            {
                presentation.noteDropDetail("cancel_cause", "slot_removed")
            }
            self?.events.inlineRemoved(payload, reason: reason)
        }
        floaterOrchestrator = FloaterOrchestrator(
            onDismissed: { [weak self] state, reason, metrics, wasVisible in
                self?.pipReporter.emitFloaterDismissed(state, reason, metrics, wasVisible)
            },
            onCompleted: { [weak self] state in self?.pipReporter.emitFloaterCompleted(state) },
            onStepViewed: { [weak self] state in self?.pipReporter.emitFloaterStepViewed(state) },
            onStepDismissed: { [weak self] state in self?.pipReporter.emitFloaterStepDismissed(state) },
            onVisible: { [weak self] state in self?.pipReporter.reportFloaterImpression(state) }
        )
        guideOrchestrator.surfaceContext = surfaceContext
        guideOrchestrator.onStateChanged = { [weak self] state in
            self?.guideStateDidChange(state)
        }
        floaterStoryOrchestrator = FloaterStoryOrchestrator(
            onDismissed: { [weak self] state, reason, metrics, wasVisible in
                self?.floaterStoryReporter.emitFloaterStoryDismissed(state, reason, metrics, wasVisible)
            },
            onCompleted: { [weak self] state in self?.floaterStoryReporter.emitFloaterStoryCompleted(state) },
            onStepViewed: { [weak self] state in self?.floaterStoryReporter.emitFloaterStoryStepViewed(state) },
            onStepDismissed: { [weak self] state in self?.floaterStoryReporter.emitFloaterStoryStepDismissed(state) },
            onVisible: { [weak self] state in self?.floaterStoryReporter.reportFloaterStoryImpression(state) }
        )
        // SR07: a floater under a nudge, survey or guide cannot open over it.
        let coveredByBlocking: () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.controller.activeNudge != nil || self.surveyOrchestrator.state != nil
                || self.guideOrchestrator.state != nil
        }
        floaterOrchestrator.isCoveredByBlockingCampaign = coveredByBlocking
        floaterStoryOrchestrator.isCoveredByBlockingCampaign = coveredByBlocking

        appBackgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.floaterOrchestrator.setAppForegrounded(false)
                self?.floaterStoryOrchestrator.setAppForegrounded(false)
                self?.coordinator.noteAppLeftForeground()
                self?.dwellTracker.pause()
                self?.appDidEnterBackground()
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
                self?.coordinator.noteAppEnteredForeground()
                self?.dwellTracker.resume()
                self?.appWillEnterForeground()
            }
        }
    }

    /// How long `initialize()` may keep its caller waiting, measured from the call
    /// (startup plan SP2). The fetch itself is never cut short: if the cap fires
    /// first, it finishes in the background.
    static let initializeCapNanoseconds: UInt64 = 2_000_000_000

    /// Returns when the campaign fetch has settled the SDK state (ready or failed)
    /// or `initializeCapNanoseconds` after the call, whichever comes first. Never
    /// throws on a fetch failure: the SDK is left `failed` (SP4).
    func initialize(_ config: DigiaConfig) async throws {
        let calledAt = DispatchTime.now().uptimeNanoseconds
        LocalStorageMigrator.migrateIfNeeded(targetDefaults: defaults, standardDefaults: legacyDefaults)
        DigiaImagePipeline.configureIfNeeded()
        hostActionExecutor.configure(config.actionHandlers)
        if sdkState == .failed {
            // A retry after a failed fetch (SP4). Services, identity and the
            // health sink were built by the first call and are kept: only the
            // fetch runs again, with the first call's config.
            log.i("Retrying the campaign fetch after a failed initialization", stage: .fetch)
            noteAppOpened()
            startCampaignFetch()
            await awaitCampaignFetch(calledAt: calledAt)
            return
        }
        guard self.config == nil else {
            log.w("initialize() ignored — already initialized")
            return
        }
        self.config = config
        // Pending mode (SP10): allowlisted records from here until `activate`
        // below are queued, not lost.
        healthSink.beginPending()
        DigiaLogger.configure(config.logLevel)
        DigiaEndpoints.configure(config)
        let services = SDKServices(
            config: config,
            storage: storage,
            networkClient: networkClient,
            clock: clock,
            analyticsQueue: analyticsQueue,
            networkMonitor: makeNetworkMonitor()
        )
        self.services = services
        currentSession.set(services.sessionManager, identity: services.identityManager, requestHeaders: services.requestHeaders)
        // The startup session is reported before the buffered user change
        // below can rotate it.
        services.sessionIdentityWiring.reportStartup()

        // Before the bundle can be ready, so a held `app_opened` sees its open.
        appOpens.attach(storage)
        services.sessionManager.addRotationListener { [weak self] in self?.sessionDidRotate() }

        // Apply the user change buffered before services existed. The user
        // context is configured from the resulting identity once the bundle
        // lands, so this change needs no refresh of its own.
        switch pendingUserChange {
        case let .set(userId):
            applyUserId(services, userId, refreshContext: false)
        case .clear:
            applyUserId(services, nil, refreshContext: false)
        case nil:
            break
        }
        pendingUserChange = nil

        services.submissionReporter.configure(config: config)
        isDebugBuild = DigiaDebugDetection.isDebugBuild()
        font = DigiaFont(fontFamily: config.fontFamily)
        CampaignCanvasTheme.shared.update(config.themeMode)

        // Pre-init buffers are handed over now, before the fetch: the component
        // registry needs only services, and anchors that mounted before this
        // point wait on it.
        configureComponentRegistry(config: config, services: services)

        // The cached SDK config applies in this same synchronous step, before any event.
        // A first install has none: health events wait for the config call to answer.
        let configStore = SdkConfigStore(storage: storage.scoped("sdk_config"), projectKey: config.apiKey)
        if let cached = configStore.cached {
            applySdkConfig(cached)
            activateHealthSink()
        }
        startSdkConfigFetch(configStore)

        // The moment the app is on screen, whatever the bundle's progress.
        beginAppOpen()

        // `completeInitialization` marks the SDK ready once the bundle lands. A
        // trigger that arrives before then is dropped, never held (SP5).
        startCampaignFetch()
        await awaitCampaignFetch(calledAt: calledAt)
    }

    /// Waits for the running fetch, but no later than the cap measured from
    /// `calledAt` (SP2). Only the wait ends at the cap: the fetch is an
    /// unstructured task, so it keeps running when this returns.
    private func awaitCampaignFetch(calledAt: UInt64) async {
        guard let fetchTask else { return }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- calledAt
        guard elapsed < Self.initializeCapNanoseconds else { return }
        let remaining = Self.initializeCapNanoseconds - elapsed
        // Not a task group: a group waits for every child before it returns,
        // and the fetch child cannot be cancelled. Whichever finishes first
        // resumes; the other finds the continuation already spent.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            let resumeOnce = { @MainActor in
                guard !resumed else { return }
                resumed = true
                continuation.resume()
            }
            Task { @MainActor in
                await fetchTask.value
                resumeOnce()
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: remaining)
                resumeOnce()
            }
        }
    }

    /// Moves to `initializing` and fetches the campaign bundle in the background.
    private func startCampaignFetch() {
        sdkState = .initializing
        let generation = initGeneration
        fetchTask = Task { @MainActor [weak self, networkClient] in
            let fetched: Result<CampaignBundle, Error>
            do {
                fetched = .success(try await CampaignFetcher(networkClient: networkClient).fetch())
            } catch {
                fetched = .failure(error)
            }
            // A reset while the fetch was in flight owns the state now.
            guard let self, self.initGeneration == generation else { return }
            self.fetchTask = nil
            self.applyFetchResult(fetched)
            if case .success(let bundle) = fetched {
                await self.openDecisionEngine(policy: bundle.appEventUploadPolicy, generation: generation)
            }
        }
    }

    /// Increments on reset so a fetch started before it cannot land after it.
    var initGeneration = 0
    private var fetchTask: Task<Void, Never>?
    /// Exposed for tests to await.
    private(set) var sdkConfigFetchTask: Task<Void, Never>?

    /// Not awaited. A failed call changes nothing, except that a first install with no
    /// cached config runs on the defaults from here, which also sends the held health events.
    private func startSdkConfigFetch(_ store: SdkConfigStore) {
        let generation = initGeneration
        sdkConfigFetchTask = Task { @MainActor [weak self, networkClient] in
            let fetched = await store.fetch(using: networkClient)
            guard let self, self.initGeneration == generation else { return }
            let firstInstall = store.cached == nil
            guard let config = fetched ?? (firstInstall ? SdkConfig.defaults : nil) else { return }
            self.applySdkConfig(config)
            self.activateHealthSink()
        }
    }

    private func applySdkConfig(_ config: SdkConfig) {
        healthSink.applyConfig(enabled: config.healthEnabled, sessionCap: config.healthSessionCap)
    }

    private func applyFetchResult(_ fetched: Result<CampaignBundle, Error>) {
        var campaigns: [CampaignModel] = []
        switch fetched {
        case .success(let bundle):
            campaigns = bundle.campaigns
            currentDesignTokens = bundle.designTokens
            currentTimeAnchor = bundle.timeAnchor
        case .failure(let error):
            currentTimeAnchor = nil
            // A rejected key is the one fetch failure a customer can fix
            // themselves, so it is worth its own row rather than being filed
            // under "network".
            let fetchFailure = error as? CampaignFetchError
            log.e(
                "Campaign fetch failed",
                error: error,
                stage: .fetch,
                reason: Self.fetchFailureReason(fetchFailure),
                extras: fetchFailure?.statusCode.map { ["http_status": String($0)] }
            )
            // Not ready with an empty store (SP7): every trigger drops
            // `initialization_failed` until the host calls `initialize()` again.
            sdkState = .failed
            engine.close()
            return
        }
        needsPlugin = !campaigns.isEmpty
        completeInitialization(campaigns)
    }

    /// Lets queued health records flow, once a config has been applied.
    private func activateHealthSink() {
        guard let analytics = services?.analyticsService, analytics.isEnabled else {
            // Nothing can send, so dedup and cap must not be spent.
            healthSink.deactivate()
            return
        }
        healthSink.activate { [weak self] payload in
            Task { @MainActor [weak self] in
                self?.services?.analyticsService?.captureHealth(
                    campaignKey: payload.campaignKey,
                    reason: payload.reason,
                    stage: payload.stage,
                    detail: payload.detail,
                    buildMode: payload.buildMode
                )
            }
        }
    }

    /// Configures the component registry and hands it the anchors buffered
    /// before `initialize()`.
    private func configureComponentRegistry(config: DigiaConfig, services: SDKServices) {
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
        // SwiftUI tree renders before `initialize()` runs.
        componentRegistry.attachPendingAnchors(to: _currentScreen)
    }

    func executeActionFlow(
        _ actions: [EngageAction],
        variables: VariableContext?,
        campaignKey: String?,
        localActionExecutor: LocalActionExecutor
    ) async {
        await actionExecutor.executeActionFlow(
            actions,
            variables: variables,
            campaignKey: campaignKey,
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
            // A JS reload re-runs this whole method (RN calls
            // `populateCampaignBundle` again), which re-configures the
            // service below. Without this, any live-test invocation still
            // in flight from before the reload keeps its watchdog running
            // against post-reload state — a leak, not a failure, so it is
            // cancelled rather than ACKed.
            clearLiveTestState()
            liveTestService.configure(
                config: config,
                deviceId: services.identityManager.deviceId,
                isDebugBuild: isDebugBuild,
                onCampaignTest: { [weak self] invocation in self?.handleLiveTestCampaign(invocation)
                }
            )
        }
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

    func logVerbose(_ message: String) {
        log.d(message)
    }

    private func logError(_ message: String) {
        log.e(message)
    }

    /// Which fetch failure a campaign creator is looking at.
    ///
    /// A rejected key is the one init failure a customer can fix themselves.
    private static func fetchFailureReason(_ failure: CampaignFetchError?) -> TimelineReason {
        if failure?.statusCode == 401 || failure?.statusCode == 403 { return .fetchFailedAuth }
        switch failure?.category {
        case .httpStatus, .invalidResponse: return .fetchFailedResponse
        default: return .fetchFailedNetwork
        }
    }

    func register(_ plugin: DigiaCEPPlugin) {
        if let outgoing = activePlugin {
            // G6 — settle everything the outgoing plugin owns *before* calling
            // `detach()`, so its own outcome handlers run while its bridge is
            // still alive. Reversing these two lines is the leak itself.
            coordinator.detach(owner: outgoing.id)
            // One still waiting for its attach hop was never attached.
            if outgoing !== pendingAttach { outgoing.detach() }
        }
        pendingAttach = nil
        activePlugin = plugin
        log.i(
            "Plugin registered (plugin=\(plugin.id))",
            stage: .session,
            reason: TimelineReason.pluginRegistered,
            extras: ["plugin": plugin.id]
        )
        guard config == nil else {
            attachActive(plugin)
            return
        }
        // `initialize()` hasn't started. A host that wrote
        // `Task { try await Digia.initialize(config) }; Digia.register(plugin)`
        // has an init Task queued on the main actor but not yet run. One hop
        // lets it run first and reach `initializing`, so the replays `attach`
        // delivers synchronously drop `not_ready` (logged and reported), not
        // `not_initialized` (R2-S03).
        pendingAttach = plugin
        Task { @MainActor [weak self] in
            self?.attachActive(plugin)
        }
    }

    /// The plugin `register` accepted before `initialize()` started, until its
    /// attach hop runs.
    private var pendingAttach: DigiaCEPPlugin?

    private func attachActive(_ plugin: DigiaCEPPlugin) {
        // A later `register` (or a reset) replaced it during the hop.
        guard activePlugin === plugin else { return }
        if pendingAttach === plugin { pendingAttach = nil }
        plugin.attach(host: self)
        if sdkState == .failed { plugin.onHostInitFailed() }
        if let screen = _currentScreen {
            plugin.onScreenChanged(screen)
        }
    }

    // MARK: - DigiaCEPHost

    var isReady: Bool { sdkState == .ready }

    /// Delivers a CEP trigger into the Digia engine.
    ///
    /// Total and synchronous: it never fails, always returns a handle, and a
    /// rejection comes back as an *already settled* presentation so the caller
    /// has one code path either way. A trigger that arrives before the SDK is
    /// ready is dropped at once, never held (`routeOrDrop`). Never make this
    /// `async` — spec §10.3.
    func deliver(_ trigger: CEPTriggerPayload) -> CampaignPresentation {
        let driver = CepDriver(pluginId: activePlugin?.id ?? "")
        let controller = coordinator.open(trigger, owner: driver.owner)
        // Before routing, so a trigger that is turned away still shows up on
        // the timeline as having arrived. "Nothing happened at all" and "it
        // arrived and we turned it away" are the two answers a campaign creator
        // most needs to tell apart.
        observeDelivery(controller)
        // A CEP must not show a campaign that Digia decides itself.
        if sdkState == .ready, campaignStore.find(trigger.campaignKey)?.rule != nil {
            controller.settle(.dropped(reason: .digiaManaged, detail: "Digia decides this campaign"))
            return controller.presentation
        }
        routeOrDrop(controller, driver: driver)
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
        // A host that triggers campaigns itself runs without a CEP, so a missing plugin is expected.
        hostTriggersCampaigns = true
        let driver = HostDriver()
        let controller = coordinator.open(trigger, owner: driver.owner)
        observeDelivery(controller)
        routeOrDrop(controller, driver: driver)
        return controller.presentation
    }

    /// The state gate `deliver` and `triggerCampaign` share, as Flutter and Android: route when
    /// ready, otherwise settle at once as dropped so the CEP gets its slot back. Core never
    /// holds a trigger (SP5); the reason says which of the not-ready states it met.
    func routeOrDrop(_ controller: PresentationController, driver: CampaignDriver) {
        let drop: (DropReason, String)
        switch sdkState {
        case .ready:
            routeNow(controller, driver: driver)
            return
        case .notInitialized:
            drop = (.notInitialized, "Digia.initialize() has not been called")
        case .initializing:
            drop = (.notReady, "Campaigns are still loading; trigger dropped")
        case .failed:
            drop = (.initializationFailed, "Campaign fetch failed; trigger dropped")
        }
        log.w("Dropped — \(drop.1)", campaign: controller.trigger.campaignKey)
        controller.settle(.dropped(reason: drop.0, detail: drop.1))
    }

    /// The `trigger_source` of a delivery: the CEP's id, or `host` when the host
    /// app asked for the campaign itself.
    private static func deliverySource(_ driver: CampaignDriver) -> String {
        driver.kind == .host ? "host" : driver.owner
    }

    /// Routes a delivery against the store as it stands right now.
    private func routeNow(_ controller: PresentationController, driver: CampaignDriver) {
        recordDelivery(controller, source: Self.deliverySource(driver))
        // Routing must see the stamped payload: it is the instance every render
        // surface stores and hands back, and the only thing that leads an event
        // back to this presentation.
        switch routeOrganicTrigger(controller.trigger, driver: driver) {
        case .accepted(let payload, let kind):
            let campaign = findCampaign(payload)
            let dueDelay = Self.firstAppearanceDelay(campaign)
            coordinator.accept(
                controller, kind: kind, dueDelay: dueDelay,
                surfaceKind: campaign.flatMap(Self.healthSurfaceKind))
            if awaitsAnchorLayout(payload) {
                coordinator.awaitAnchor(
                    payload, dueDelay: dueDelay,
                    anchorKey: campaign?.guideConfig?.steps.first?.target.anchorKey)
            }
        case .dropped(let reason, let detail, let cause, var extras, let deliveryDetail):
            if let cause { extras["cause"] = cause }
            if !extras.isEmpty { controller.dropExtras = extras }
            if !deliveryDetail.isEmpty { controller.dropDeliveryDetail = deliveryDetail }
            if let cause { controller.noteDropDetail("cause", cause) }
            controller.settle(.dropped(reason: reason, detail: detail))
        }
    }

    /// Records `Digia Experience Triggered` for a trigger whose campaign is in
    /// the bundle, and `Digia Experience Dropped` if it later settles dropped.
    ///
    /// Keyed on the settled outcome rather than on each drop site, so every
    /// later drop is counted. A trigger whose campaign is unknown sends neither —
    /// there is no campaign id to attribute it to
    /// (ai_docs/campaign-delivery-events.md). The id is passed explicitly: the
    /// coordinator forgets the presentation at settle.
    private func recordDelivery(_ controller: PresentationController, source: String) {
        guard let analytics = services?.analyticsService,
            let campaign = campaignStore.find(Self.routingKey(controller.trigger))
        else { return }
        let trigger = controller.trigger
        analytics.capture(
            DeliveryEvent.Triggered(triggerSource: source, screenName: _currentScreen),
            payload: trigger, campaignId: campaign.id, campaignType: campaign.campaignType,
            impressionId: controller.id)
        Task { @MainActor [weak self] in
            guard case .dropped(let reason, _) = await controller.presentation.outcome.value
            else { return }
            // The screen at the drop, not at the trigger (they differ for a
            // `cancelled` / `screen_exit`).
            analytics.capture(
                DeliveryEvent.Dropped(
                    dropReason: reason.value, triggerSource: source,
                    screenName: self?._currentScreen,
                    detail: controller.dropDeliveryDetail ?? [:]),
                payload: trigger, campaignId: campaign.id, campaignType: campaign.campaignType,
                impressionId: controller.id)
        }
    }

    /// Whether this campaign cannot appear until a named anchor resolves — the
    /// anchor watchdog's one arming condition.
    private func awaitsAnchorLayout(_ payload: CEPTriggerPayload) -> Bool {
        guard let guide = findCampaign(payload)?.guideConfig else { return false }
        // A3 (SR63): an anchorless guide also waits on something that may never
        // come (its page and image); `reportGuideShown` resolves it.
        if guide.isAnchorless { return true }
        return guide.steps.first?.target.anchorKey != nil
    }

    /// The authored wait before a campaign is due to appear (R3-D9): a guide's
    /// first-step `delayInMs`, a survey's start delay. Added to the watchdog
    /// windows so they count from the due time.
    private static func firstAppearanceDelay(_ campaign: CampaignModel?) -> TimeInterval {
        switch campaign?.config {
        case .guide(let guide)?:
            return TimeInterval(max(0, guide.steps.first?.delayInMs ?? 0)) / 1_000
        case .survey(let survey)?:
            return TimeInterval(max(0, survey.timeDelayMs)) / 1_000
        default:
            return 0
        }
    }

    private static func isInlineKind(_ campaign: CampaignModel) -> Bool {
        switch campaign.config {
        case .inline, .banner, .inlineCanvas, .story: return true
        default: return false
        }
    }

    /// The `surface_kind` a `timeout` drop sends to HealthSink (R3-D10).
    private static func healthSurfaceKind(_ campaign: CampaignModel) -> String? {
        switch campaign.config {
        case .nudge: return "nudge"
        case .survey: return "survey"
        case .guide: return "guide"
        case .floater, .floaterStory:
            return campaign.floaterStoryConfig != nil ? "story_floater" : "pip"
        case .inline, .banner, .inlineCanvas, .story: return nil
        case .unsupported: return nil
        }
    }

    /// The ordered teardown a cancelled or timed-out presentation runs — the
    /// same surfaces `onCampaignInvalidated` used to take down under v1, now
    /// reached through ``CampaignPresentation/cancel()``.
    ///
    /// A stamped payload matches only its own delivery (its `presentationId`),
    /// so a watchdog firing late can't take down a newer delivery of the same
    /// CEP campaign (SR60). An unstamped one (a live test) matches by id.
    private func dismissSurfaces(for payload: CEPTriggerPayload) {
        for surface in surfaces {
            surface.dismiss(payload)
        }
    }

    /// The fetch returned campaigns, and the first screen change has not yet checked for a plugin.
    private var needsPlugin = false
    private var hostTriggersCampaigns = false

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
        // Digia-owned rules need no plugin.
        engine.send(.screenViewed(screenName))
        // Checked at a screen change, not at fetch: hosts may register after `initialize()`.
        if needsPlugin, sdkState == .ready {
            needsPlugin = false
            guard activePlugin == nil, !hostTriggersCampaigns else { return }
            log.w(
                "No CEP plugin registered — triggered campaigns cannot show",
                stage: .session,
                reason: TimelineReason.pluginNotRegistered
            )
        }
    }

    func setCaptureModeEnabled(_ enabled: Bool) {
        guard !enabled || (isDebugBuild && isCaptureSupported) else { return }
        captureModeEnabled = enabled
        captureStorage.set(enabled, forKey: "enabled")
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
        guard config != nil, let pageKey = _currentScreen, !pageKey.isEmpty,
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
                sdkVersion: sdkVersion ?? "",
                profile: profile,
                traversal: traversal,
                nodes: nodes
            )

            let upload = await URLSessionCaptureUploader(networkClient: networkClient).upload(
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
            sdkVersion: sdkVersion ?? "",
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
                dismiss: { self.nudgeOrchestrator.markNudgeDismissed(reason: .screenExit) }
            )
        }

        if let survey = surveyOrchestrator.state {
            dismissForScreenChangeIfNeeded(
                campaignKey: survey.payload.campaignKey,
                campaignType: "survey",
                campaign: campaignStore.find(survey.payload.campaignKey),
                dismiss: {
                    // The fields a user close sends, from the renderer (R3-11).
                    let progress = self.surveyOrchestrator.progress()
                    self.surveyReporter.markSurveyDismissed(
                        abandonedAtItem: progress?.abandonedAtItem,
                        answeredCount: progress?.answeredCount,
                        reason: .screenExit
                    )
                }
            )
        }

        // Every guide, anchored or anchorless, ends on any real screen change, whatever its
        // targetScreenNames, as on Android and Flutter: its steps point at the screen it opened on.
        // An empty allowlist means "every screen" for a nudge, and read that way it kept a guide up
        // over a screen it no longer belonged to. `setCurrentScreen` only calls this on a real
        // change, so re-setting the same screen leaves the guide up.
        if let guide = guideOrchestrator.state {
            log.d("Dismissed — screen changed (type=guide, currentScreen=\(_currentScreen ?? "<unset>"))",
                  campaign: guide.campaign.campaignKey)
            liveTestContexts[guide.payload.cepCampaignId]?.reportFailed(
                DropReason.screenNotTargeted,
                message: "screen changed before the Guide was shown"
            )
            guideOrchestrator.dismissGuide(reason: .screenExit)
        }

        if let guide = activeExternalGuide {
            // Same rule for a guide the host renders itself.
            log.d("Dismissed — screen changed (type=guide, currentScreen=\(_currentScreen ?? "<unset>"))",
                  campaign: guide.campaign.campaignKey)
            activeExternalGuide = nil
            events.toCep(.dismissed(reason: .screenExit), payload: guide.payload)
        }

        // Floater and Floater Story orchestrators evaluate screen changes against their
        // campaign's targetScreenNames allowlist via their own onScreenChanged methods.
        floaterOrchestrator.onScreenChanged(_currentScreen ?? "")
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

    /// Called each time an anchor key appears (`AnchorRegistry.register`). An
    /// anchor that leaves and comes back is a new exposure, so it signals again.
    func recordAnchorSeen(_ anchorKey: String) {
        componentRegistry.recordAnchor(anchorKey, screenName: _currentScreen)
        // After the frame that mounted it, so routing sees the finished layout.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.engine.send(.anchorVisible(anchorKey)) }
        }
    }

    /// Called the first time a placement key appears (`DigiaSlot`).
    func recordSlotSeen(_ placementKey: String) {
        componentRegistry.recordSlot(placementKey, screenName: _currentScreen)
        sendVisibleOnce("slot:\(placementKey)", .slotVisible(placementKey))
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
    func routeOrganicTrigger(_ payload: CEPTriggerPayload, driver: CampaignDriver) -> RoutingVerdict {
        logVerbose(
            "deliver cepCampaignId='\(payload.cepCampaignId)' "
                + "campaignKey='\(payload.campaignKey)'")
        let resolvedKey = Self.routingKey(payload)
        guard !resolvedKey.isEmpty, let campaign = campaignStore.find(resolvedKey) else {
            logError(
                "campaign dropped — no campaign for key '\(resolvedKey)' knownKeys=[\(campaignStore.keys.joined(separator: ", "))]"
            )
            // Only reached once ready: `routeOrDrop` settles earlier states.
            return .dropped(
                reason: .unknownCampaignKey,
                detail: "no campaign for key '\(resolvedKey)'"
            )
        }
        return route(campaign, payload: payload, driver: driver)
    }

    /// The store key a trigger routes by. Route purely by the campaignKey
    /// resolved from the store (mirrors Android) — fall back to cepCampaignId
    /// when no campaignKey was supplied.
    private static func routingKey(_ payload: CEPTriggerPayload) -> String {
        let key = payload.campaignKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty
            ? payload.cepCampaignId.trimmingCharacters(in: .whitespacesAndNewlines)
            : key
    }

    /// Every campaign routing accepted that has not settled yet (SR03), read
    /// from the surfaces at the moment of routing. A floater animating out
    /// has already ended and is not an occupant. An RN classic guide
    /// (`activeExternalGuide`) is a guide occupant (plan §2.4, owner decision).
    private func surfaceOccupants() -> [SurfaceOccupant] {
        surfaces.flatMap { $0.occupants }
    }

    func occupant(
        _ kind: SurfaceKind, _ payload: CEPTriggerPayload, priority: Double? = nil
    ) -> SurfaceOccupant {
        // Inline counts as displayed once it impressed; every other kind once its
        // dwell started, which is at its impression.
        let displayed: Bool
        if case .inline = kind {
            displayed = events.hasImpressed(payload.cepCampaignId)
        } else {
            displayed = dwellTracker.elapsedMs(payload.cepCampaignId) != nil
        }
        return SurfaceOccupant(
            kind: kind,
            campaignKey: payload.campaignKey,
            cepCampaignId: payload.cepCampaignId,
            isLiveTest: isLiveTestCepId(payload.cepCampaignId),
            hasDisplayed: displayed,
            presentationId: payload.presentationId,
            priority: priority
        )
    }

    /// Takes an occupant off the surface, settling it `superseded` — which
    /// releases a real campaign's CEP slot, and reports an earlier live test
    /// that never showed as superseded on its dashboard row. The one helper
    /// every displacement goes through (SR06).
    ///
    /// `incoming`, `campaignKey`, `isLiveTest`: the arrival that displaced it,
    /// for the occupant's delivery detail.
    private func settleSuperseded(
        _ occupant: SurfaceOccupant, by incoming: SurfaceKind, campaignKey: String, isLiveTest: Bool
    ) {
        let id = occupant.cepCampaignId
        if let presentation = occupant.presentationId.flatMap(coordinator.controller(forPresentationId:)) {
            if isLiveTest {
                presentation.noteDropDetail("superseded_by_live_test", true)
            } else {
                presentation.noteDropDetail("superseded_by_campaign_key", campaignKey)
                if let newer = campaignStore.find(campaignKey)?.id {
                    presentation.noteDropDetail("superseded_by_campaign_id", newer)
                }
            }
            presentation.noteDropDetail("superseded_by_kind", incoming.wire)
        }
        // First (SR46): a test's dashboard row gets `failed: superseded`, never
        // a relayed `dismissed` from the teardown below. As Flutter and Android.
        supersedeLiveTest(id)
        // D5 (SR44): the CEP hears `superseded` once; Digia's dismiss event,
        // with that type's usual fields, only for one that was displayed
        // (its dwell started at the impression). `hasDisplayed` is inline-only.
        for surface in surfaces {
            surface.supersede(occupant)
        }
    }

    /// Runs one campaign through the router's gates and, if they all pass,
    /// starts it. `driver` is who asked; only its ``SourcePolicy`` changes what
    /// the gates do.
    private func route(
        _ campaign: CampaignModel,
        payload: CEPTriggerPayload,
        driver: CampaignDriver
    ) -> RoutingVerdict {
        let router = CampaignRouter(
            occupants: { [unowned self] in surfaceOccupants() },
            supersede: { [unowned self] occupant, incoming, request in
                settleSuperseded(
                    occupant, by: incoming, campaignKey: request.campaign.campaignKey,
                    isLiveTest: request.driver.kind == .liveTest)
            },
            start: { [unowned self] in startCampaign($0) },
            currentScreen: { [unowned self] in _currentScreen },
            capReason: { [unowned self] in
                services?.frequencyManager.blockReason(campaignKey: $0.campaignKey, policy: $0.frequency)
            },
            campaignsSuppressed: { [unowned self] in campaignsSuppressed },
            campaignId: { [unowned self] in campaignStore.find($0)?.id },
            reportMissing: { [unowned self] in reportMissingCampaignVariables($0.campaign, payload: $0.payload) },
            configCheck: { [unowned self] in checkGuideCanvasContent($0) }
        )
        logVerbose("routeByCampaignKey key='\(campaign.campaignKey)' type='\(campaign.campaignType)'")
        return router.route(CampaignRequest(driver: driver, campaign: campaign, payload: payload))
    }

    private func reportMissingCampaignVariables(_ campaign: CampaignModel, payload: CEPTriggerPayload) {
        reportMissingVariables(campaign.variableSchemas, payload: payload)
    }

    /// A native guide keeps only the steps that carry a canvas, so a guide with
    /// none is dropped before the surface rule and a test with no content leaves
    /// the screen as it was (§2.2). A classic guide handed to the RN renderer is
    /// not filtered.
    private func checkGuideCanvasContent(_ request: CampaignRequest) -> RoutingVerdict? {
        guard let guide = request.campaign.guideConfig, !isClassicRNGuide(guide),
            !guide.steps.contains(where: { $0.widgetConfig.canvas != nil })
        else { return nil }
        return request.invalidConfig("campaign has no valid Canvas guide content", cause: "empty_content")
    }

    func isClassicRNGuide(_ guide: GuideConfigModel) -> Bool {
        !guide.isAnchorless
            && config?.wrapperBinding == "react_native"
            && !guide.steps.isEmpty
            && guide.steps.allSatisfy { $0.widgetConfig.layoutMode != "canvas" }
    }

    /// Starts a campaign every gate has passed.
    private func startCampaign(_ request: CampaignRequest) -> RoutingVerdict {
        switch request.campaign.config {
        case .inline(let cfg):
            return inlineSurface.startCarousel(request, cfg)
        case .banner(let cfg):
            return inlineSurface.startBanner(request, cfg)
        case .inlineCanvas(let cfg):
            return inlineSurface.startCanvas(request, cfg)
        case .story(let cfg):
            return inlineSurface.startStory(request, cfg)
        case .guide(let cfg):
            return guideSurface.start(request, cfg)
        case .nudge(let cfg):
            return nudgeSurface.start(request, cfg)
        case .survey(let cfg):
            return surveySurface.start(request, cfg)
        // Both floater subtypes route through the same gate — a collapsed window of
        // either kind is the same third, non-blocking lane.
        case .floater, .floaterStory:
            // Two template shapes under one campaign type, each with its own
            // orchestrator — see `CampaignConfigModel.floaterStory`.
            if request.campaign.floaterStoryConfig != nil {
                return floaterStorySurface.start(request)
            }
            return pipSurface.start(request)
        case .unsupported(let config):
            request.driver.policy.onDropped(TimelineReason.campaignUnsupported, config.reason)
            log.e(
                "Dropped — unsupported config (reason=\(config.reason))",
                campaign: request.campaign.campaignKey)
            return .dropped(reason: .invalidConfig, detail: config.reason)
        }
    }

    /// Handles one `campaign_test` SSE event.
    ///
    /// The `catch` is the outermost half of "every invocation ends in a
    /// terminal ACK". This runs on an SSE callback with nothing above it, so
    /// without it a throw anywhere in parsing or routing would escape into
    /// the stream handler and the dashboard row would simply stop moving.
    /// Internal (not private) so routing tests can drive a live test.
    func handleLiveTestCampaign(_ invocation: LiveTestInvocation) {
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
        // A live test is a PM's preview, so its parse and route must not reach fleet health.
        let parsed = HealthSink.$muted.withValue(true) {
            try? CampaignModel.fromJson(
                campaignJson,
                designTokens: currentDesignTokens,
                devicePlatform: "ios",
                timeAnchor: currentTimeAnchor
            )
        }
        guard let campaign = parsed else {
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
        case .unsupported: supportsLiveTest = false
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
           !guideConfig.steps.isEmpty,
           guideConfig.steps.allSatisfy({ $0.widgetConfig.layoutMode != "canvas" })
        {
            reporter.postFailed(
                invocation.testInvocationId,
                code: TimelineReason.campaignUnsupported,
                message: "Classic Guides cannot be tested on a device"
            )
            return
        }

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

        let verdict = HealthSink.$muted.withValue(true) {
            route(campaign, payload: payload, driver: LiveTestDriver(context: testContext))
        }
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
        // Re-armed at acceptance for every kind (R3-10). A live test shows a
        // guide at once (no step delay); a survey still waits out its start
        // delay, so the window counts from then (R3-D11). Inline tests get 10 s
        // (R4-D4).
        testContext.delayWatchdog(
            by: campaign.guideConfig == nil ? Self.firstAppearanceDelay(campaign) : 0,
            window: Self.isInlineKind(campaign) ? LiveTestContext.inlineWatchdogTimeout : nil
        )
        // The context's own per-invocation watchdog (armed in its initializer)
        // gives up if nothing ever draws the test; this adds the teardown that
        // firing implies (R3-D11, SR65): a test that silently never appeared
        // must not linger on the surface.
        testContext.onWatchdogFired = { [weak self] in
            guard let self else { return }
            if self.guideOrchestrator.state?.payload.cepCampaignId == cepCampaignId {
                self.guideOrchestrator.guideCompletionFired = false
            }
            self.dismissSurfaces(for: payload)
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
            if AnchorRegistry.shared.isRegistered(anchorKey),
               AnchorRegistry.shared.isOnScreenScrollingIfNeeded(anchorKey) {
                return
            }
            testContext.reportFailed(
                DropReason.anchorNotRegistered,
                message: "anchor '\(anchorKey)' is not on screen"
            )
            self.guideOrchestrator.dismissIfActive(payloadId: payload.cepCampaignId)
            self.guideOrchestrator.guideCompletionFired = false
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

    func markInitializedForTesting(with config: DigiaConfig) {
        self.config = config
        hostActionExecutor.configure(config.actionHandlers)
    }

    /// Whether a live-test invocation is still waiting for its terminal ACK.
    func isLiveTestPendingForTesting(_ testInvocationId: String) -> Bool {
        liveTestContexts[liveTestCepId(testInvocationId)] != nil
    }

    func setCampaignsForTesting(_ campaigns: [CampaignModel]) {
        campaignStore.populate(campaigns)
        sdkState = .ready
    }

    func setUserId(_ userId: String) {
        guard let services else {
            // A blank ID is ignored here exactly as `IdentityManager` ignores
            // it after init, so it can't overwrite a buffered clear.
            guard !userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            pendingUserChange = .set(userId)
            return
        }
        applyUserId(services, userId)
    }

    func clearUserId() {
        guard let services else {
            pendingUserChange = .clear
            return
        }
        applyUserId(services, nil)
    }

    /// Suppresses campaign overlays while the host app shows its own UI (e.g. a
    /// modal), and restores them when it closes. See
    /// `Digia.setCampaignsSuppressed`.
    func setCampaignsSuppressed(_ suppressed: Bool) {
        guard campaignsSuppressed != suppressed else { return }
        campaignsSuppressed = suppressed
        log.d("Campaign overlays \(suppressed ? "suppressed" : "restored") by host")
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
            pipReporter.reportFloaterClicked(
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
                campaignKey: state.payload.campaignKey,
                // A dismiss authored on a CTA is the CTA taken, not the user closing it (the
                // window's × stays .userClose), as on the PiP.
                localActionExecutor: LocalActionExecutor(dismiss: { [weak self] in
                    self?.floaterStoryOrchestrator.dismiss(.ctaTaken)
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
    func findCampaign(_ payload: CEPTriggerPayload) -> CampaignModel? {
        liveTestCampaigns[payload.cepCampaignId] ?? campaignStore.find(payload.campaignKey)
    }

    // MARK: - Guide lifecycle

    private func guideStateDidChange(_ state: ActiveGuideState?) {
        guard let state, let anchorKey = state.currentStep?.target.anchorKey else {
            AnchorRegistry.shared.stopTracking()
            return
        }
        AnchorRegistry.shared.track(
            key: anchorKey,
            // A live test shows at once, as on Android.
            delayMs: isLiveTestCepId(state.payload.cepCampaignId)
                ? 0 : state.currentStep?.delayInMs ?? 0,
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
                self.guideOrchestrator.reportGuideRenderFailure(
                    .invalidGeometry,
                    guideToken: current.token,
                    stepIndex: current.stepIndex
                )
            },
            onRemoved: { [weak self] removedKey in
                guard let self,
                      let current = self.guideOrchestrator.state,
                      current.token == state.token,
                      current.currentStep?.target.anchorKey == removedKey
                else { return }
                self.logNativeGuideStage("anchor", "result=removed anchor_key=\(removedKey)")
                self.dismissGuideForRemovedAnchor(current)
            }
        )
    }

    /// The anchor hosting the current step left the screen. Same events as
    /// Flutter (`guide_showcase_manager.dart` `dismiss()` / `_finish`):
    /// - not shown yet (still in the first step's delay): the CEP alone is told
    ///   `dismissed` with the caller's reason, or `target_lost` (as Android) when
    ///   the anchor went away; Digia records nothing for an unseen guide.
    /// - shown: a lost target in place, a screen exit after a host screen change.
    ///   On the last step of a multi-step guide that is a completion: Digia
    ///   Completed, CEP `completed`, no Digia dismiss (R4-D2, ADR-004).
    private func dismissGuideForRemovedAnchor(_ state: ActiveGuideState, reason: DismissReason? = nil) {
        guard dwellTracker.elapsedMs(state.payload.cepCampaignId) != nil else {
            guideOrchestrator.dismiss()
            if let anchorKey = state.currentStep?.target.anchorKey {
                coordinator.ownerOf(state.payload)?.noteDropDetail("anchor_key", anchorKey)
            }
            // As Android: the anchor it was pinned to went away (the
            // coordinator turns this into `cancelled`, cancel_cause `target_lost`).
            events.toCep(.dismissed(reason: reason ?? .targetLost), payload: state.payload)
            guideOrchestrator.guideCompletionFired = false
            guideOrchestrator.pendingGuideDismissReason = nil
            return
        }
        // As Flutter (`guide_showcase_manager.dart:787-813`): the completion
        // carries the guide's dwell and doesn't count toward frequency.
        if state.steps.count > 1, !state.hasNext {
            guideOrchestrator.reportGuideCompletedIfNeeded(state, anchorLeft: true)
        }
        guideOrchestrator.pendingGuideDismissReason =
            reason ?? ((_currentScreen == guideOrchestrator.screenAtGuideStep) ? .targetLost : .screenExit)
        // A completion (just above, or an earlier CTA) wins (R4-D2): the CEP
        // hears `completed` and no Digia dismiss follows.
        guideOrchestrator.dismissGuide()
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
                guideOrchestrator.dismissGuide()
            }
        } else {
            if completesOnLast, state.steps.count > 1 { guideOrchestrator.reportGuideCompletedIfNeeded(state) }
            if !completesOnLast {
                // Scrim/outside tap off the last step, as Flutter's scrimTap.
                guideOrchestrator.pendingGuideDismissReason = .scrimTap
            }
            guideOrchestrator.dismissGuide()
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
        return AnchorRegistry.shared.isOnScreenScrollingIfNeeded(anchorKey)
    }

    func logNativeGuideStage(_ stage: String, _ details: String) {
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
            services?.frequencyManager.recordShow(campaignKey, campaign?.frequency)
        case "Digia Experience Completed":
            services?.frequencyManager.recordCompleted(campaignKey, campaign?.frequency)
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
        // A terminal report frees the surface even when no live presentation matches.
        if case .settled = event, activeExternalGuide?.payload.presentationId == presentationId {
            activeExternalGuide = nil
        }
        guard let controller = coordinator.controller(forPresentationId: presentationId) else {
            log.d(
                "reportExternalGuideLifecycle: no-op — unknown or already-settled presentation",
                presentationId: presentationId
            )
            return
        }
        switch event {
        case .displaying:
            // Through the impression path, keyed by this guide's own
            // presentation, so the acceptance watchdog is disarmed even when
            // `activeExternalGuide` has already moved on (SR91).
            coordinator.handle(.impressed, payload: controller.trigger)
        case .clicked(let elementId):
            controller.emitClicked(elementId: elementId)
        case .settled(let outcome):
            // An external renderer reports over an async bridge, so its
            // ordering is not trustworthy: a guide torn down before its first
            // frame (anchor off-screen, host torn down) reports `dismissed`
            // with no prior `displaying` — the exact sequence
            // `PresentationBacking.settle` traps on. Route a dismissal
            // through the coordinator like every other surface: one that never
            // displayed settles as a drop, never a trap.
            switch outcome {
            case .dismissed(let reason, let completed):
                coordinator.handle(
                    .dismissed(reason: reason, completed: completed), payload: controller.trigger)
            case .dropped(let reason, let detail):
                controller.settle(.dropped(reason: reason, detail: detail))
            }
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
                dismissReason: str("dismiss_reason") ?? DismissReason.userClose.value,
                abandonedAtItem: int("abandoned_at_step") ?? int("step_index"),
                itemTotal: int("step_total"))
        case "Digia Experience Completed":
            return GuideEvent.Completed(itemTotal: int("step_total"))
        default:
            return nil
        }
    }

    private static func stringValue(_ value: JSONValue?) -> String? {
        if case .string(let s)? = value { return s }
        return nil
    }

    func resetForTesting() {
        DigiaEndpoints.resetForTest()
        ActionPlatform.current = .live
        (networkClient as? URLSessionNetworkClient)?.overrideForTesting = nil
        resetDecisionStateForTesting()
        if let plugin = activePlugin {
            coordinator.detach(owner: plugin.id)
            plugin.detach()
        }
        activePlugin = nil
        pendingAttach = nil
        _currentScreen = nil
        campaignsSuppressed = false
        initGeneration &+= 1
        fetchTask?.cancel()
        fetchTask = nil
        sdkConfigFetchTask?.cancel()
        sdkConfigFetchTask = nil
        services?.tearDown()
        services = nil
        currentSession.set(nil, requestHeaders: [:])
        campaignStore.clear()
        liveTestService.stop()
        // Else a test that resets without initializing inherits the last config and ACKs past the cleared override.
        liveTestService.ackReporter.resetForTesting()
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
        surveyReporter.resetForTesting()
        coordinator.resetForTesting()
        clearLiveTestState()
        pendingUserChange = nil
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
    var questionCount: Int {
        nodes.filter { node in
            guard let block = blockFor(node) else { return false }
            return !block.type.isContent
        }.count
    }

    var hasWelcome: Bool { welcomeBlock() != nil }

    var hasThanks: Bool { blocks.contains { $0.type == .resultPage } }

    var hasBranching: Bool { nodes.contains { $0.branching.type != .linear } }

    func blockForNode(_ nodeId: String) -> SurveyBlock? {
        nodeById(nodeId).flatMap { blockFor($0) }
    }
}
