import Foundation
import UIKit

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

/// Crash kill-switch: a renderer that dies while the app is in the
/// foreground turns off that one skin version for the rest of the process.
/// Other skins keep opening, and a fresh launch tries again; nothing persists.
/// A kill while backgrounded is the OS reclaiming memory, not the skin, so it
/// does not count.
@MainActor
enum GameAvailability {
    private static var crashedSkins = Set<String>()

    static func isEnabled(skinId: String, skinVersion: Int) -> Bool {
        !crashedSkins.contains("\(skinId)@\(skinVersion)")
    }

    static func markCrashed(skinId: String, skinVersion: Int) {
        guard UIApplication.shared.applicationState != .background else { return }
        crashedSkins.insert("\(skinId)@\(skinVersion)")
    }
}

/// Sends one validated skin `http` call: the method and path the intake
/// accepted and the encoded body (nil for `GET`). Production sends through
/// `GameHttpBridge` with the shared client; see `GamePresentation.httpSend`.
/// Main-actor bound so tests can hand a non-`Sendable` answer back.
typealias GameHttpSend = @MainActor (_ method: String, _ path: String, _ body: Data?) async -> Result<
    GameHttpBridge.Success, GameHttpBridge.Failure
>

/// The live game session the overlay controller holds. Owns the bridge, the
/// cached entry the web view loads, and the exactly-once close/failure
/// callbacks. Answers every bridge request: generic `http`, `event`,
/// `log`, `haptics`, `sensor`, `storage`, and `action`.
@MainActor
final class GamePresentation: Identifiable, ObservableObject {
    /// The close reason when the coordinator cancels the game's presentation.
    static let cancelledReason = "cancelled"

    /// The campaign key. One game owns the surface at a time, so this is unique.
    let id: String
    /// Swapped once by `release(with:)` when a prewarmed game is adopted.
    private(set) var request: GameOpenRequest
    let entryFile: URL
    let bundleRoot: URL
    let bridge = GameBridge()

    /// Set when `ready` arrives; the game is presented only after this.
    private(set) var isReady = false

    /// True from the first close request until the exit animation ends and the
    /// session settles; the container animates out on it.
    @Published private(set) var isClosing = false
    /// Muted sends `device.soundAllowed = false`, so the skin goes quiet.
    @Published private(set) var isMuted = false

    private var didFinish = false
    private let haptics = GameHaptics()
    private let motion = GameMotionSource()
    private let storage: GameSkinStorage
    /// Skin `error` logs reported this open; capped, so a noisy skin cannot spam analytics.
    private var skinErrorCount = 0
    private static let maxSkinErrorsPerOpen = 5
    /// The one `init` for this session: built from the open request and the
    /// live facts, re-sent unchanged on a repeated `ready`.
    private var initMessage: [String: Any]
    private var lastViewport: (width: Double, height: Double, safeArea: GameSafeArea, keyboardBottom: Double)?
    /// The docked keyboard's overlap with the game, in points; 0 when hidden.
    private var keyboardBottom: Double = 0
    /// The keyboard's last end frame in screen coordinates; nil when hidden.
    /// Kept so a frame seen before the game view is in a window still counts
    /// once it is.
    private var keyboardEndFrame: CGRect?
    private var lastDevicePush: [String: Any]?
    private var observers: [NSObjectProtocol] = []
    /// The slow device-facts re-collect while the game is open. Cancelled
    /// with the observers when the session settles.
    private var devicePollTask: Task<Void, Never>?
    /// Why the game is closing (`user`, `skin` or `cta`): set by `dismiss`,
    /// read by `didClose` for the funnel's Dismissed reason.
    private var closeReason = "user"

    /// Every in-flight skin `http` call, by skin request id; cancelled at
    /// close so a call the user closed on stops instead of running on (row 21).
    private var httpTasks: [String: Task<Void, Never>] = [:]
    private var httpWatchdogs: [String: Task<Void, Never>] = [:]
    /// When each watched call started, for the `game_rewards_failed` duration.
    private var httpWatchdogStarted: [String: Date] = [:]
    /// Skin request ids whose watchdog already fired: late answers are dropped.
    private var httpTimedOutIds = Set<String>()
    /// How long one watched `http` call may hang before the game closes.
    /// Tests shorten it so the watchdog fires without waiting out the delay.
    var httpWatchdogSeconds: TimeInterval = GameBridge.httpWatchdogSeconds
    /// Sends one validated skin `http` call. Production sends through
    /// `GameHttpBridge` with the shared client; tests inject a hang or a
    /// canned answer so the watchdog is drivable without a socket.
    var httpSend: GameHttpSend = { method, path, body in
        await GameHttpBridge.send(
            client: SDKInstance.shared.networkClient,
            baseUrl: DigiaEndpoints.baseUrl,
            headers: SDKInstance.shared.requestHeaders,
            method: method, path: path, body: body)
    }

    init?(request: GameOpenRequest) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: request.entryFile.path, isDirectory: &isDirectory), !isDirectory.boolValue
        else { return nil }
        self.request = request
        self.id = request.campaignKey
        self.entryFile = request.entryFile
        self.bundleRoot = request.bundleRoot
        self.storage = GameSkinStorage(
            defaults: Self.storageDefaults,
            namespace: GameSkinStorage.namespace(
                projectId: request.projectId, skinId: request.skinId, identity: request.userId))
        self.initMessage = Self.initMessage(for: request)
        bridge.onReady = { [weak self] version in
            // Every `ready` gets `init`, the first included (Android parity): a
            // skin whose listener was not attached at didFinish would otherwise
            // never get it and sit visible but dead.
            self?.sendInit()
            self?.didBecomeReady(version: version)
        }
        bridge.onRepeatedReady = { [weak self] _ in
            self?.sendInit()
            // A skin re-announcing itself on an open game gets the current
            // state again, like Android's ready-on-open init-then-resume.
            if self?.bridge.state == .idle { self?.pushLifecycle("resumed") }
        }
        bridge.onRequest = { [weak self] request in self?.handle(request) }
        bridge.onSend = { [weak self] script in self?.evaluate(script) }
        bridge.onClosed = { [weak self] in self?.didClose() }
        bridge.onFailed = { [weak self] reason in self?.didFail(reason) }
        bridge.onDropped = { [weak self] reason, type in self?.reportBridgeDrop(reason: reason, type: type) }
        observeDeviceSignals()
    }

    private var health: GameHealthContext {
        GameHealthContext(
            campaignId: request.campaignId, skinId: request.skinId,
            skinVersion: request.skinVersion, entry: request.entry)
    }

    private func reportBridgeDrop(reason: String, type: String?) {
        SDKInstance.shared.events.toDigia(
            GameBridgeDroppedEvent(health: health, reason: reason, type: type),
            payload: request.payload)
    }

    /// A prewarmed game (`GamePrewarmer`): the page loads hidden up to
    /// finished, but `init` is held back, skin messages are dropped and no
    /// timer runs until `release(with:)` adopts it on the tap or grant.
    private(set) var isHeld = false
    /// The page finished while held; `release` sends the held-back `init`.
    private var pageFinished = false
    /// The page failed to load while held: the tap discards it (`replaced`)
    /// and opens normally.
    private(set) var heldLoadFailed = false

    /// The web view's owner, created once in `preload()` and reused by the
    /// container once the game is shown.
    private(set) var webCoordinator: GameWebCoordinator?

    /// Loads the skin before anything is shown. The web view sits in the key
    /// window fully transparent and ignoring touches, so the host app stays
    /// usable; `ready` presents the game. A page that does not commit within
    /// 15 s, or sends no `ready` within 5 s of the commit, closes silently.
    func preload(held: Bool = false) {
        isHeld = held
        let engine = GamePrewarmer.takeEngine()
        if request.timing.warm == nil { request.timing.warm = engine != nil ? "engine" : "none" }
        let coordinator = GameWebCoordinator(
            game: self, entryFile: entryFile, bundleRoot: bundleRoot,
            engine: engine)
        webCoordinator = coordinator
        let view = coordinator.view
        view.alpha = 0
        view.isUserInteractionEnabled = false
        // `keyWindow()` already falls back to the foreground scene's visible
        // window when none is key (RN hosts). With no window at all the page
        // still loads detached; `ready` hands the view to the container.
        if let window = ViewControllerUtil.keyWindow() {
            view.frame = window.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            window.addSubview(view)
        }
        if !didCommitPage { request.timing.stage = GameOpenTiming.stageCommit }
        coordinator.start()
        if !held { armOpenWatchdog() }
    }

    /// The overall deadline for an open that is not a direct campaign: the
    /// presentation coordinator's acceptance window (15 s, the same watchdog
    /// that takes a stuck nudge off), counted in wall clock from the open to
    /// `ready` across every phase and across background time. A direct game
    /// is already watched by the coordinator, whose timeout closes it through
    /// `GamificationSurface.dismiss`, so it arms nothing here. Entry and
    /// rewards opens have no coordinator presentation, so this is theirs. A
    /// game that is ready, finished or held is left alone.
    private func armOpenWatchdog() {
        guard request.entry != GamificationEntryKind.direct.rawValue else { return }
        let seconds = PresentationCoordinator.defaultAcceptanceTimeout
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + seconds) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.didFinish, !self.isReady, !self.isHeld else { return }
                log.w("Game not shown within \(Int(seconds)) s — cancelled",
                      campaign: self.request.campaignKey)
                self.finish(report: { [request = self.request] in request.onFailure?(.openTimeout) })
                self.bridge.close()
            }
        }
    }

    /// True once the page committed: the load timer is done and the ready
    /// timer owns the wait for `ready`.
    private var didCommitPage = false
    /// Foreground seconds left in the current phase's budget; nil until the
    /// phase first arms.
    private var phaseRemaining: TimeInterval?
    /// Uptime when the running timer was armed; nil while none runs.
    private var phaseArmedAt: TimeInterval?

    /// Charges the running timer's foreground time to the phase budget.
    private func spendPhaseBudget() {
        guard let armedAt = phaseArmedAt, let remaining = phaseRemaining else { return }
        phaseRemaining = max(0, remaining - (MonotonicClock.nowSeconds() - armedAt))
        phaseArmedAt = nil
    }

    /// Arms the timer for the phase the load is in: 15 s to the page commit,
    /// then 5 s to `ready`. The budgets count foreground time only, like
    /// Android: a re-arm after the app returns gets what is left, never a full
    /// budget, so repeated backgrounding cannot keep a load (and the busy slot)
    /// alive forever. Each arm carries a fresh bridge generation, so re-arming
    /// (or `cancelReadyTimer`) makes any earlier timer a stale no-op. Runs only
    /// while loading and in the foreground.
    func armLoadTimer() {
        guard !didFinish, !isHeld, bridge.state == .loading,
              UIApplication.shared.applicationState == .active
        else { return }
        spendPhaseBudget()
        let committed = didCommitPage
        let seconds = phaseRemaining
            ?? (committed ? GameBridge.readyTimeoutSeconds : GameBridge.loadTimeoutSeconds)
        phaseRemaining = seconds
        phaseArmedAt = MonotonicClock.nowSeconds()
        let generation = bridge.beginLoading()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            Task { @MainActor [weak self] in
                if committed {
                    self?.bridge.readyTimeoutFired(generation: generation)
                } else {
                    self?.bridge.loadTimeoutFired(generation: generation)
                }
            }
        }
    }

    /// The page committed: the load timer gives way to the 5 s ready timer.
    func pageDidCommit() {
        guard !didCommitPage else { return }
        didCommitPage = true
        request.timing.stage = GameOpenTiming.stageReady
        // The ready phase starts with its own full budget.
        phaseRemaining = nil
        phaseArmedAt = nil
        armLoadTimer()
    }

    /// Sends the session's `init`: once after the page loads, and again on
    /// every `ready`. Each `init` fully resets the skin.
    func sendInit() {
        pageFinished = true
        guard !isHeld else { return }
        // `initMessage` is built once, but the keyboard can open or close
        // before a (repeated) `init`: send its live overlap.
        refreshKeyboardBottom()
        var payload = initMessage
        if var viewport = payload["viewport"] as? [String: Any] {
            viewport["keyboardInset"] = ["bottom": keyboardBottom]
            payload["viewport"] = viewport
        }
        send(["type": "init", "payload": payload])
        // `init` is built unmuted; a skin that re-announces itself while muted
        // gets the muted facts right after it.
        if isMuted, let lastDevicePush { send(["type": "device", "payload": lastDevicePush]) }
    }

    /// Adopts a prewarmed game for `request` (the tap's, or the grant's with
    /// its chance): rebuilds `init` from it, sends `init` if the page already
    /// finished, and starts the 5 s ready timer, the page having committed.
    func release(with request: GameOpenRequest) {
        guard isHeld, !didFinish else { return }
        self.request = request
        request.timing.warm = "game"
        request.timing.stage = didCommitPage ? GameOpenTiming.stageReady : GameOpenTiming.stageCommit
        initMessage = Self.initMessage(for: request)
        lastDevicePush = GameDeviceInfo.current(sdkVersion: sdkVersion).pushPayload
        isHeld = false
        armOpenWatchdog()
        // A held `ready` is replayed below and answered with `init` there.
        if pageFinished, heldReady == nil { sendInit() }
        armLoadTimer()
        // A skin that booted while held already sent its one `ready`.
        if let ready = heldReady {
            heldReady = nil
            bridge.receive(ready)
        }
    }

    /// Destroys a held game without a word: no callback, no analytics.
    func discardWarm() {
        guard isHeld, !didFinish else { return }
        didFinish = true
        motion.stopAll()
        removeObservers()
        webCoordinator?.view.removeFromSuperview()
        webCoordinator?.teardown()
    }

    /// A skin message from the web view. Dropped while held, a held game
    /// answering nothing, except `ready`: skins send it once on boot without
    /// waiting for `init`, so it is kept and replayed by `release(with:)`.
    func receive(_ body: Any) {
        guard !isHeld else {
            if let text = body as? String, text.contains("\"ready\""),
               let data = text.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["type"] as? String == "ready"
            {
                heldReady = text
            }
            return
        }
        bridge.receive(body)
    }

    /// The skin's boot `ready`, received while held.
    private var heldReady: String?

    func toggleMute() {
        isMuted.toggle()
        pushDeviceIfChanged()
    }

    // MARK: - Skin requests

    private func handle(_ message: GameBridgeRequest) {
        switch message {
        case .http(let id, let method, let path, let body):
            performHttp(id: id, method: method, path: path, body: body)
        case .log(_, let level, let message):
            emitSkinLog(level: level, message: message)
        case .haptics(_, let style):
            // Unknown styles never reach here: the intake drops them, so the
            // sink is never invoked for one.
            if !haptics.play(style) {
                log.d("Game haptic dropped (style=\(style.rawValue))", campaign: self.request.campaignKey)
            }
        case .storageGet(let id, let key):
            guard GameSkinStorage.isValidKey(key) else {
                bridge.fail(id: id, code: .badRequest, message: "invalid key")
                return
            }
            if let value = storage.get(key) {
                bridge.answer(id: id, payload: ["value": value])
            } else {
                bridge.answer(id: id, payload: ["value": NSNull()])
            }
        case .storageSet(let id, let key, let value):
            if let reason = storage.set(key, value: value) {
                bridge.fail(id: id, code: .badRequest, message: reason)
            } else {
                bridge.answer(id: id)
            }
        case .storageRemove(let id, let key):
            guard GameSkinStorage.isValidKey(key) else {
                if let id { bridge.fail(id: id, code: .badRequest, message: "invalid key") }
                return
            }
            storage.remove(key)
            if let id { bridge.answer(id: id) }
        case .actionCopy(let id, let text):
            runSkinAction(id: id, action: .copyToClipboard(text), op: "copy")
        case .actionOpenLink(let id, let op, let url):
            // The container closes first, then the host opens the link.
            if let id { bridge.answer(id: id, payload: ["ok": true]) }
            request.onCta?(op, url.absoluteString)
            dismiss(reason: "cta")
            runSkinActionAfterClose(action: .openUrl(url.absoluteString))
        case .actionOpenDeeplink(let id, let url):
            if let id { bridge.answer(id: id, payload: ["ok": true]) }
            request.onCta?("deeplink", nil)
            dismiss(reason: "cta")
            runSkinActionAfterClose(action: .openDeeplink(url.absoluteString))
        case .actionShare(let id, let text):
            runSkinAction(id: id, action: .share(text), op: "share")
        case .actionCustomKV(let id, let payload):
            runSkinAction(id: id, action: .customKV(payload), op: "customKV")
        case .actionClose(let id, let reason):
            if let reason, !reason.isEmpty {
                log.d("Game closed by skin (reason=\(reason))", campaign: self.request.campaignKey)
            }
            if let id { bridge.answer(id: id, payload: ["ok": true]) }
            // A close before `ready` never showed the game: it is an open failure.
            guard isReady else {
                didFail(reason == "unsupported" ? .bridgeVersionUnsupported : .closedBeforeReady)
                bridge.close()
                return
            }
            dismiss(reason: "skin")
        case .motionSubscribe(let id, let sensors, let hz):
            // Availability resolves for every sensor before any of them
            // streams, so a missing sensor fails the whole subscribe —
            // like Android, never a started subset plus `unsupported`.
            let started = motion.startAll(sensors: sensors, hz: hz) { [weak self] event in
                guard let self else { return }
                self.pushSensor(event)
            }
            if started {
                bridge.answer(id: id)
            } else {
                bridge.fail(id: id, code: .unsupported, message: "sensor unavailable")
            }
        case .motionUnsubscribe(let id, let sensors):
            for sensor in sensors { motion.stop(sensor: sensor) }
            bridge.answer(id: id)
        case .actionPassthrough(let id, let op, let action):
            // Any campaign action the canvas parser knows (e.g. requestReview)
            // runs through the same executor. One that leaves the game closes
            // the container first, like the named link ops.
            switch action {
            case .openUrl, .openDeeplink:
                if let id { bridge.answer(id: id, payload: ["ok": true]) }
                request.onCta?(op, nil)
                dismiss(reason: "cta")
                runSkinActionAfterClose(action: action)
            default:
                runSkinAction(id: id, action: action, op: op)
            }
        }
    }

    /// Runs one skin `action` op through the same executor the canvas uses, so
    /// host handlers behave exactly as for any other campaign action. Answered
    /// only once the action has run — or not at all, when the skin sent no id
    /// or the game closed mid-execution. A run fires `onCta`, like Android's,
    /// including id-less runs, which still tapped.
    private func runSkinAction(id: String?, action: EngageAction, op: String) {
        Task { @MainActor [weak self] in
            guard let self, self.bridge.state != .closed else { return }
            await SDKInstance.shared.executeActionFlow(
                [action], variables: nil, campaignKey: self.request.campaignKey,
                localActionExecutor: LocalActionExecutor(
                    dismiss: { [weak self] in self?.dismiss(reason: "skin") }))
            guard self.bridge.state != .closed else { return }
            if let id { self.bridge.answer(id: id, payload: ["ok": true]) }
            self.request.onCta?(op, nil)
        }
    }

    /// Runs one skin `action` after the surface already closed (the openLink /
    /// openDeeplink path): no reply is owed, and the closed bridge must not
    /// swallow the host-ward side effect. Captures the request, not the
    /// session, so teardown cannot cancel the open.
    private func runSkinActionAfterClose(action: EngageAction) {
        let campaignKey = self.request.campaignKey
        Task { @MainActor in
            await SDKInstance.shared.executeActionFlow(
                [action], variables: nil, campaignKey: campaignKey,
                localActionExecutor: LocalActionExecutor(
                    dismiss: { GamePresenter.dismiss() }))
        }
    }

    /// One generic skin backend call. The method and path ride verbatim from
    /// the intake: a missing one, a denied path, or anything but exact
    /// `GET`/`POST` answers `bad_request` — each with its `game_http_failed`,
    /// like Android's session — before the call below runs. 2xx and 4xx
    /// answer `{status, body}`; anything else answers by kind.
    private func performHttp(id: String, method: String, path: String, body: [String: Any]?) {
        let start = Date()
        func reject(code: GameBridgeErrorCode) {
            bridge.fail(id: id, code: code, message: self.httpErrorMessage(code))
            let failed = GameHttpBridge.rejectedCall(method: method, path: path, code: code)
            SDKInstance.shared.events.toDigia(
                GameHttpFailedEvent(
                    health: self.health, method: failed.method, path: failed.path,
                    code: failed.code.rawValue, status: failed.status,
                    durationMs: Int(Date().timeIntervalSince(start) * 1000)),
                payload: self.request.payload)
        }
        guard !method.isEmpty, !path.isEmpty else {
            reject(code: .badRequest)
            return
        }
        // A looping skin must not hammer the backend (row 20): a reused id or
        // a call past the in-flight cap answers `bad_request`, like Android.
        guard httpTasks[id] == nil, httpTasks.count < Self.maxHttpInFlight else {
            reject(code: .badRequest)
            return
        }
        guard let validated = GameHttpBridge.validatedPath(path) else {
            reject(code: .badRequest)
            return
        }
        // A live-test game carries its invocation into the skin's POST `state`
        // call: without it a draft campaign refuses `notFound` even though
        // `play` on the chance works. Organic games send byte-identical bodies.
        var body = body ?? [:]
        if validated == "state", method == "POST",
           let tid = request.testInvocationId, !tid.isEmpty,
           body["testInvocationId"] == nil
        {
            body["testInvocationId"] = tid
        }
        // Encoded before the hop: `[String: Any]` is not Sendable, `Data` is.
        let payloadData: Data?
        switch method {
        case "POST":
            guard let data = GameHttpBridge.jsonData(body) else {
                reject(code: .badRequest)
                return
            }
            payloadData = data
        case "GET":
            payloadData = nil
        default:
            reject(code: .badRequest)
            return
        }
        if Self.httpWatchdogPaths.contains(validated) { armHttpWatchdog(id: id, path: validated) }
        httpTasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.httpSend(method, validated, payloadData)
            guard !Task.isCancelled, !self.didFinish, self.bridge.state != .closed else { return }
            self.httpTasks.removeValue(forKey: id)
            self.cancelHttpWatchdog(id: id)
            // A late answer after the watchdog fired: the game already closed
            // on the timeout. Never reply, never record: the window settles once.
            guard !self.httpTimedOutIds.contains(id) else { return }
            switch result {
            case .success(let response):
                self.bridge.answer(id: id, payload: [
                    "status": response.status, "body": response.body ?? NSNull(),
                ])
                self.request.onHttpAnswer?(validated, body, response.body)
                if validated == "state", let body = response.body {
                    self.recordStateAnswer(body)
                }
            case .failure(let failure):
                self.bridge.fail(id: id, code: failure.code, message: self.httpErrorMessage(failure.code))
                let failed = GameHttpBridge.failedCall(method: method, path: validated, failure: failure)
                let durationMs = Int(Date().timeIntervalSince(start) * 1000)
                SDKInstance.shared.events.toDigia(
                    GameHttpFailedEvent(
                        health: self.health, method: failed.method, path: failed.path,
                        code: failed.code.rawValue, status: failed.status,
                        durationMs: durationMs),
                    payload: self.request.payload)
            }
        }
    }

    /// A successful skin `state` answer feeds the next open's `init.chanceState`.
    private func recordStateAnswer(_ envelope: [String: Any]) {
        guard envelope["isSuccess"] as? Bool == true,
              let response = (envelope["data"] as? [String: Any])?["response"] as? [String: Any]
        else { return }
        GameChanceStateCache.shared.record(campaignKey: request.campaignKey, response: response)
    }

    private func httpErrorMessage(_ code: GameBridgeErrorCode) -> String {
        code == .timeout ? "request timed out" : "request failed"
    }

    /// The `http` paths a stuck game would wait on: a call here with no answer
    /// within `httpWatchdogSeconds` closes the game. Every other path relies
    /// on `http`'s own 20 s `error timeout`.
    private static let httpWatchdogPaths: Set<String> = ["state", "play", "getRewards"]
    /// Most skin `http` calls one game may have in flight at once (row 20).
    private static let maxHttpInFlight = 8

    /// Arms the watchdog for one watched skin `http` call: still pending when
    /// the delay elapses means the native stack hung, so the fire closes the
    /// game. Re-arming replaces the earlier task, so a reused id fires once.
    private func armHttpWatchdog(id: String, path: String) {
        cancelHttpWatchdog(id: id)
        let delay = httpWatchdogSeconds
        httpWatchdogs[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.httpWatchdogFired(id: id, path: path)
        }
        httpWatchdogStarted[id] = Date()
    }

    private func cancelHttpWatchdog(id: String) {
        httpWatchdogs.removeValue(forKey: id)?.cancel()
        httpWatchdogStarted.removeValue(forKey: id)
    }

    private func cancelAllHttpWatchdogs() {
        for task in httpWatchdogs.values { task.cancel() }
        httpWatchdogs.removeAll()
        httpWatchdogStarted.removeAll()
    }

    /// Fires once per window: marks the call timed out so its late answer is
    /// dropped, reports `game_rewards_failed`, then closes the game through
    /// the normal path — `dismiss` when showing (so the entry stays and the
    /// rewards page refreshes, the existing retry affordances), `didFail`
    /// before `ready` (which reports the single `game_open_failed`).
    private func httpWatchdogFired(id: String, path: String) {
        httpWatchdogs.removeValue(forKey: id)
        guard !didFinish, !isClosing, bridge.state != .closed else { return }
        guard httpTimedOutIds.insert(id).inserted else { return }
        let durationMs = Int(Date().timeIntervalSince(httpWatchdogStarted.removeValue(forKey: id) ?? Date()) * 1000)
        request.onHttpTimeout?(path, durationMs)
        if isReady {
            log.w("Game http call timed out with no answer — closing", campaign: request.campaignKey)
            dismiss(reason: GameFailure.httpTimeout.wireValue)
        } else {
            didFail(.httpTimeout)
        }
    }

    private func emitSkinLog(level: String, message: String) {
        let campaign = request.campaignKey
        switch level {
        case "debug": log.d(message, campaign: campaign)
        case "info": log.i(message, campaign: campaign)
        case "warn": log.w(message, campaign: campaign)
        case "error": log.e(message, campaign: campaign)
        default: log.d(message, campaign: campaign)
        }
        if level == "error", skinErrorCount < Self.maxSkinErrorsPerOpen {
            skinErrorCount += 1
            SDKInstance.shared.events.toDigia(
                GameSkinErrorEvent(health: health, message: message),
                payload: request.payload)
        }
    }

    // MARK: - Native pushes

    private func pushSensor(_ event: GameMotionEvent) {
        send(["type": "motionSample", "payload": event.payload])
    }

    /// Reports the rendered viewport when it changes (rotation, split
    /// screen, keyboard show/hide/height). The container calls this on
    /// appear and on geometry changes, the keyboard observers on keyboard
    /// frame changes; unchanged viewports stay silent.
    func pushViewportIfChanged(size: CGSize, safeArea: GameSafeArea) {
        refreshKeyboardBottom()
        let viewport = (
            width: Double(size.width), height: Double(size.height),
            safeArea: safeArea, keyboardBottom: keyboardBottom)
        if let last = lastViewport, last == viewport { return }
        lastViewport = viewport
        send([
            "type": "viewport",
            "payload": [
                "width": viewport.width, "height": viewport.height,
                "safeArea": safeArea.payload,
                "keyboardInset": ["bottom": viewport.keyboardBottom],
            ],
        ])
    }

    /// The keyboard will show, hide or change height: measure its final
    /// overlap with the game (the animation's end frame, like Android's
    /// IME animation target) and push it. The game surface itself never
    /// resizes. Before the game is shown there is no viewport to update;
    /// the container's first push carries the value.
    private func keyboardWillChange(endFrame: CGRect?) {
        keyboardEndFrame = endFrame
        guard let last = lastViewport else { return }
        pushViewportIfChanged(
            size: CGSize(width: last.width, height: last.height), safeArea: last.safeArea)
    }

    /// Recomputes `keyboardBottom` from the last keyboard frame against the
    /// game view. Before the view is in a window the previous value stays.
    private func refreshKeyboardBottom() {
        guard let endFrame = keyboardEndFrame else { keyboardBottom = 0; return }
        guard let view = webCoordinator?.view, let screen = view.window?.screen else { return }
        let keyboard = view.convert(endFrame, from: screen.coordinateSpace)
        keyboardBottom = GameKeyboardInset.bottom(keyboard: keyboard, surface: view.bounds)
    }

    /// Whether the next pushed `device` facts differ from the last push.
    /// Pure, so the shared case-table run pins the change gate without a game.
    static func devicePushChanged(_ next: [String: Any], from last: [String: Any]?) -> Bool {
        guard let last else { return true }
        // Push payloads are flat JSON scalars; NSDictionary equality is exact.
        return !NSDictionary(dictionary: next).isEqual(to: last)
    }

    private func pushDeviceIfChanged(_ info: GameDeviceInfo? = nil) {
        var info = info ?? GameDeviceInfo.current(sdkVersion: sdkVersion)
        if isMuted { info.soundAllowed = false }
        let push = info.pushPayload
        guard Self.devicePushChanged(push, from: lastDevicePush) else { return }
        lastDevicePush = push
        send(["type": "device", "payload": push])
    }

    private func pushLifecycle(_ state: String) {
        send(["type": "lifecycle", "payload": ["state": state]])
    }

    private func send(_ message: [String: Any]) {
        guard !isHeld else { return }
        guard let script = GameBridge.receiveScript(for: message) else {
            log.w("Game push dropped — message not JSON", campaign: request.campaignKey)
            return
        }
        evaluate(script)
    }

    private func evaluate(_ script: String) {
        guard !isHeld else { return }
        webCoordinator?.view.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: - Init facts

    private static var storageDefaults: UserDefaults {
        UserDefaults(suiteName: "tech.digia.engage") ?? .standard
    }

    private var sdkVersion: String {
        SDKInstance.shared.sdkVersion ?? DigiaSdkVersion.value
    }

    @MainActor
    private static func initMessage(for request: GameOpenRequest) -> [String: Any] {
        let size = ViewControllerUtil.keyWindow()?.bounds.size ?? .zero
        let safeArea = GameSafeArea.fullScreen(system: activeWindowSafeAreaInsets)
        let scheme = ViewControllerUtil.keyWindow()?.traitCollection.userInterfaceStyle
        let hostFamily = SDKInstance.shared.config?.fontFamily?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fontFamily = (hostFamily?.isEmpty == false ? hostFamily : nil)
            ?? request.themeFontFamily
        var message = GameInitPayload(
            chanceId: request.chanceId,
            campaignId: request.campaignId,
            campaignKey: request.campaignKey,
            skinId: request.skinId,
            skinVersion: request.skinVersion,
            values: request.values,
            slots: request.slots,
            viewportWidth: Double(size.width),
            viewportHeight: Double(size.height),
            safeArea: safeArea,
            colorScheme: scheme == .dark ? "dark" : "light",
            fontFamily: fontFamily,
            themeFonts: request.themeFonts,
            device: GameDeviceInfo.current(
                sdkVersion: SDKInstance.shared.sdkVersion ?? DigiaSdkVersion.value)
        ).message()
        // The last `state` answer for this very chance, so the skin can skip
        // its open-time `state` call. Absent when nothing matches.
        if let chanceState = GameChanceStateCache.shared.lookup(
            campaignKey: request.campaignKey, chanceId: request.chanceId)
        {
            message["chanceState"] = chanceState
        }
        return message
    }

    private func observeDeviceSignals() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.pushDeviceIfChanged() }
            },
            center.addObserver(
                forName: Notification.Name.NSProcessInfoPowerStateDidChange,
                object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.pushDeviceIfChanged() }
            },
            center.addObserver(
                forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
                object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.pushDeviceIfChanged() }
            },
            // Keyboard show, height change and hide reach the skin as a
            // `viewport` push with `keyboardInset.bottom`.
            center.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification,
                object: nil, queue: .main) { [weak self] note in
                let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                Task { @MainActor [weak self] in self?.keyboardWillChange(endFrame: end) }
            },
            center.addObserver(
                forName: UIResponder.keyboardWillHideNotification,
                object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.keyboardWillChange(endFrame: nil) }
            },
            // Pause on resign-active, like the story and canvas campaigns:
            // a call, Control Center or the app switcher pauses the game, and
            // the load and ready timers never run while the app is not active.
            center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.appDidResignActive() }
            },
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.appDidBecomeActive() }
            },
        ]
        lastDevicePush = GameDeviceInfo.current(sdkVersion: sdkVersion).pushPayload
        // Thermal, power-save and reduced-motion changes do not move the
        // viewport: re-collect on a slow tick while the game is open, so
        // `device` pushes still fire (B21). `pushDeviceIfChanged` pushes only
        // when the pushed subset changed, so the tick is one cheap collect.
        devicePollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(GameBridge.deviceFactsPollSeconds * 1_000_000_000))
                guard let self else { return }
                if self.bridge.state == .idle { self.pushDeviceIfChanged() }
            }
        }
    }

    private func appDidResignActive() {
        guard !didFinish, !isHeld else { return }
        request.onForeground?(false)
        if bridge.state == .loading {
            spendPhaseBudget()
            bridge.cancelReadyTimer()
        }
        pushLifecycle("paused")
        motion.suspend()
    }

    private func appDidBecomeActive() {
        guard !didFinish, !isHeld else { return }
        request.onForeground?(true)
        armLoadTimer()
        pushLifecycle("resumed")
        motion.resume()
    }

    private func removeObservers() {
        devicePollTask?.cancel()
        devicePollTask = nil
        let center = NotificationCenter.default
        for observer in observers { center.removeObserver(observer) }
        observers = []
    }

    // MARK: - Close paths

    /// Main page load failure before `ready`: close early without waiting for
    /// the timer. After `ready` the bundle is up; subresource failures stay
    /// the skin's own fallback art. Finishes first so the failure — not a
    /// close — is what the callbacks report.
    func failLoading() {
        if isHeld {
            heldLoadFailed = true
            return
        }
        guard bridge.state == .loading else { return }
        finish(report: { [request] in request.onFailure?(.bundleLoadFailed) })
        bridge.close()
    }

    /// Renderer death: this skin version off for the session. Before `ready`
    /// the open fails `web_process_terminated`; a shown game closes like a
    /// native close with that dismiss reason.
    func failRendering() {
        // A held game has shown nothing and been asked for nothing: discard it quietly.
        if isHeld {
            GamePrewarmer.discard(reason: "process_killed", campaignKey: id)
            return
        }
        GameAvailability.markCrashed(skinId: request.skinId, skinVersion: request.skinVersion)
        guard bridge.state != .closed else { return }
        if isReady {
            dismiss(reason: "web_process_terminated")
            return
        }
        finish(report: { [request] in request.onFailure?(.webProcessTerminated) })
        bridge.close()
    }

    /// Native close affordance, and the skin `close` and CTA-handoff paths.
    /// `reason` is `user` for the close button and back, `skin` for the
    /// skin's own `close`, `cta` for a handoff op — the funnel's Dismissed
    /// reason. The bridge fires `onClosed`, which settles.
    func dismiss(reason: String = "user") {
        // The first close wins: a later dismiss (e.g. screen_exit after a cta)
        // must not overwrite the reason `onClosed` reports.
        guard !didFinish, !isClosing else { return }
        closeReason = reason
        pushLifecycle("paused")
        motion.stopAll()
        bridge.close()
    }

    private func didBecomeReady(version _: Int) {
        guard !didFinish, !isReady else { return }
        isReady = true
        // Hand the loaded web view to the container; it is never reloaded.
        webCoordinator?.view.removeFromSuperview()
        webCoordinator?.view.alpha = 1
        webCoordinator?.view.isUserInteractionEnabled = true
        GamePresenter.loading = nil
        SDKInstance.shared.controller.showGame(self)
        request.onShown?()
        // `ready` can land while the app is inactive; resume waits for didBecomeActive.
        pushLifecycle(UIApplication.shared.applicationState == .active ? "resumed" : "paused")
    }

    /// Ends the session on every path. A game that never became visible has no
    /// container to tear the web view down, so it is torn down here.
    private func finish(report: @MainActor () -> Void) {
        guard !didFinish else { return }
        didFinish = true
        cancelAllHttpWatchdogs()
        for task in httpTasks.values { task.cancel() }
        httpTasks.removeAll()
        if GamePresenter.loading === self { GamePresenter.loading = nil }
        motion.stopAll()
        removeObservers()
        if !isReady {
            webCoordinator?.view.removeFromSuperview()
            webCoordinator?.teardown()
        }
        SDKInstance.shared.controller.dismissGame()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { RewardsPageViewController.sweepOrphanGameHost() }
        report()
        // A test send that superseded this game opens now that it is gone.
        if !GamePresenter.isBusy, let next = GamePresenter.pendingTestOpen {
            GamePresenter.pendingTestOpen = nil
            next.open()
        }
    }

    /// A visible game plays its exit animation first, then settles once.
    /// The close reason (`user`, `skin` or `cta`) rides to the funnel.
    private func didClose() {
        guard !didFinish, !isClosing else { return }
        guard isReady else {
            finish(report: { [request, closeReason] in request.onClose?(closeReason) })
            return
        }
        isClosing = true
        let delay = GameMotion.exitDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let request = self.request
            let reason = self.closeReason
            self.finish(report: { request.onClose?(reason) })
        }
    }

    private func didFail(_ reason: GameFailure) {
        log.w("Game closed", error: reason.rawValue)
        finish(report: { [request] in request.onFailure?(reason) })
    }
}

/// The one internal entry point routing calls to open a game. `grantChance`
/// calls `open(_:)` on `granted && show`; teardown and the skin `close` funnel
/// back through `dismiss()`.
@MainActor
enum GamePresenter {
    /// The game loading out of sight, before its `ready`. Counts as the one
    /// open game so a re-trigger cannot start a second load.
    static var loading: GamePresentation?

    /// True while a game is loading or on screen.
    static var isBusy: Bool {
        loading != nil || SDKInstance.shared.controller.activeGame != nil
    }

    /// Opens the container for `request`. Failures that are known before the
    /// container exists (unsupported runtime, games off, busy, missing bundle)
    /// call `onFailure` directly and open nothing.
    static func open(_ request: GameOpenRequest) {
        guard #available(iOS 17, *) else {
            log.w("Game not opened — requires iOS 17", error: request.campaignKey)
            request.onFailure?(.unsupportedWebView)
            return
        }
        guard GameAvailability.isEnabled(skinId: request.skinId, skinVersion: request.skinVersion) else {
            log.w("Game not opened — this skin version's renderer died earlier this session",
                  error: request.campaignKey)
            request.onFailure?(.renderError)
            return
        }
        // One game owns the surface: a re-trigger must not restart the live
        // one. It fails `busy` instead of dropping silently, so the
        // second open settles through the same policy as any other failure.
        guard !isBusy else {
            log.w("Game not opened — another game is already open", error: request.campaignKey)
            request.onFailure?(.busy)
            return
        }
        // A game prewarmed for this very open is adopted instead of loading anew.
        if let warm = GamePrewarmer.takeGame(matching: request) {
            log.d("Game loading (prewarmed)", campaign: request.campaignKey)
            loading = warm
            warm.release(with: request)
            return
        }
        guard let presentation = GamePresentation(request: request) else {
            log.w("Game not opened — bundle entry missing", error: request.campaignKey)
            request.onFailure?(.bundleLoadFailed)
            return
        }
        log.d("Game loading", campaign: request.campaignKey)
        loading = presentation
        presentation.preload()
    }

    /// A dashboard test send waiting for the game it replaces to finish closing.
    static var pendingTestOpen: (open: () -> Void, drop: () -> Void)?

    /// Replaces the open game with a dashboard test send: closes the open game
    /// as `superseded` and opens the test once it is gone. A newer test send
    /// drops an older one still waiting.
    static func replace(open: @escaping () -> Void, drop: @escaping () -> Void) {
        pendingTestOpen?.drop()
        pendingTestOpen = (open, drop)
        dismiss(reason: "superseded")
    }

    /// Closes the open game, if any. Fires `onClose` exactly once; a failure
    /// already reported stays reported. `reason` as for the instance dismiss,
    /// plus `cancelled` when the SDK withdraws the presentation.
    static func dismiss(reason: String = "user") {
        guard let game = SDKInstance.shared.controller.activeGame ?? loading else { return }
        game.dismiss(reason: reason)
    }
}
