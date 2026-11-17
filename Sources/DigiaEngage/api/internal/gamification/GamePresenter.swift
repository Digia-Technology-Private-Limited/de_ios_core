import Foundation
import UIKit

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

/// Session kill-switch: a dead renderer closes the game quietly and turns
/// games off for the rest of the process. The next trigger tries again from
/// scratch on the next launch; no state carries over.
enum GameAvailability {
    nonisolated(unsafe) static var isEnabled = true
}

/// The live game session the overlay controller holds. Owns the bridge, the
/// cached entry the web view loads, and the exactly-once close/failure
/// callbacks. Answers every bridge request: generic `http`, `event`,
/// `log`, `haptics`, `sensor`, `storage`, and `action`.
@MainActor
final class GamePresentation: Identifiable, ObservableObject {
    /// The campaign key. One game owns the surface at a time, so this is unique.
    let id: String
    let request: GameOpenRequest
    let entryFile: URL
    let bundleRoot: URL
    let bridge = GameBridge()

    /// Set when `ready` arrives; the game is presented only after this.
    private(set) var isReady = false

    /// True from the first close request until the exit animation ends and the
    /// session settles; the container animates out on it.
    @Published private(set) var isClosing = false

    private var didFinish = false
    private let haptics = GameHaptics()
    private let motion = GameMotionSource()
    private let storage: GameSkinStorage
    /// Skin `error` logs reported this open; capped, so a noisy skin cannot spam analytics.
    private var skinErrorCount = 0
    private static let maxSkinErrorsPerOpen = 5
    /// The one `init` for this session: built from the open request and the
    /// live facts, re-sent unchanged on a repeated `ready`.
    private let initMessage: [String: Any]
    private var lastViewport: (width: Double, height: Double, safeArea: GameSafeArea)?
    private var lastDevicePush: [String: Any]?
    private var observers: [NSObjectProtocol] = []
    /// The slow device-facts re-collect while the game is open. Cancelled
    /// with the observers when the session settles.
    private var devicePollTask: Task<Void, Never>?
    /// Why the game is closing (`user`, `skin` or `cta`): set by `dismiss`,
    /// read by `didClose` for the funnel's Dismissed reason.
    private var closeReason = "user"

    init?(request: GameOpenRequest) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: request.entryFile.path, isDirectory: &isDirectory), !isDirectory.boolValue
        else { return nil }
        self.request = request
        self.id = request.campaignKey
        self.entryFile = request.entryFile
        self.bundleRoot = request.bundleRoot
        GameSkinStorage.migrateLegacyNamespace(
            defaults: Self.storageDefaults,
            projectId: request.projectId, skinId: request.skinId,
            identity: request.userId)
        self.storage = GameSkinStorage(
            defaults: Self.storageDefaults,
            namespace: GameSkinStorage.namespace(
                projectId: request.projectId, skinId: request.skinId, identity: request.userId))
        self.initMessage = Self.initMessage(for: request)
        bridge.onReady = { [weak self] version in self?.didBecomeReady(version: version) }
        bridge.onRepeatedReady = { [weak self] _ in
            self?.sendInit()
            // A skin re-announcing itself on an open game gets the current
            // state again, like Android's ready-on-open init-then-resume.
            if self?.bridge.state == .idle { self?.pushLifecycle("resume") }
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

    /// The web view's owner, created once in `preload()` and reused by the
    /// container once the game is shown.
    private(set) var webCoordinator: GameWebCoordinator?

    /// Loads the skin before anything is shown. The web view sits in the key
    /// window fully transparent and ignoring touches, so the host app stays
    /// usable; `ready` presents the game, and a missing `ready` closes it
    /// silently on the bridge's 5 s timer.
    func preload() {
        let coordinator = GameWebCoordinator(game: self, entryFile: entryFile, bundleRoot: bundleRoot)
        webCoordinator = coordinator
        let view = coordinator.view
        view.alpha = 0
        view.isUserInteractionEnabled = false
        if let window = ViewControllerUtil.keyWindow() {
            view.frame = window.bounds
            window.addSubview(view)
        }
        coordinator.start()
    }

    /// Sends the session's `init`: once after the page loads, and again on a
    /// repeated `ready`. Each `init` fully resets the skin.
    func sendInit() {
        // The fields go both under `payload` and flat beside `type`:
        // skin bundles already deployed read them flat and must keep working.
        var message = initMessage
        message["type"] = "init"
        message["payload"] = initMessage
        send(message)
    }

    // MARK: - Skin requests

    private func handle(_ message: GameBridgeRequest) {
        switch message {
        case .http(let id, let method, let path, let body):
            performHttp(id: id, method: method, path: path, body: body)
        case .event(_, let name, let props):
            SDKInstance.shared.gamification.reportGameSkinEvent(
                name: name, properties: props, payload: self.request.payload,
                campaignId: self.request.campaignId,
                skinId: self.request.skinId, skinVersion: self.request.skinVersion)
        case .log(_, let level, let message):
            emitSkinLog(level: level, message: message)
        case .haptics(_, let style):
            // Unknown styles never reach here: the intake drops them, so the
            // sink is never invoked for one.
            if !haptics.play(style) {
                log.d("Game haptic dropped (style=\(style.rawValue))", campaign: self.request.campaignKey)
            }
        case .sensorStart(let id, let sensor, let hz):
            let started = motion.start(sensor: sensor, hz: hz) { [weak self] event in
                guard let self else { return }
                self.pushSensor(event)
            }
            if started {
                bridge.answer(id: id, payload: ["started": true])
            } else {
                bridge.fail(id: id, code: .unsupported, message: "sensor unavailable")
            }
        case .sensorStop(let id, let sensor):
            motion.stop(sensor: sensor)
            bridge.answer(id: id)
        case .storageGet(let id, let key):
            guard GameSkinStorage.isValidKey(key) else {
                bridge.fail(id: id, code: .invalid, message: "invalid key")
                return
            }
            if let value = storage.get(key) {
                bridge.answer(id: id, payload: ["value": value])
            } else {
                bridge.answer(id: id, payload: ["value": NSNull()])
            }
        case .storageSet(let id, let key, let value):
            if let code = storage.set(key, value: value) {
                bridge.fail(id: id, code: code, message: code == .quota ? "storage quota exceeded" : "invalid key")
            } else {
                bridge.answer(id: id)
            }
        case .storageRemove(let id, let key):
            guard GameSkinStorage.isValidKey(key) else {
                if let id { bridge.fail(id: id, code: .invalid, message: "invalid key") }
                return
            }
            storage.remove(key)
            if let id { bridge.answer(id: id) }
        case .actionCopy(let id, let text):
            runSkinAction(id: id, action: .copyToClipboard(text), op: "copy")
        case .actionOpenLink(let id, let op, let url):
            // The container closes first, then the host opens the link.
            // Every CTA run counts one click, like Android's onCta.
            if let id { bridge.answer(id: id, payload: ["ok": true]) }
            request.onCta?(op)
            dismiss(reason: "cta")
            runSkinActionAfterClose(action: .openUrl(url.absoluteString))
        case .actionOpenDeeplink(let id, let url):
            if let id { bridge.answer(id: id, payload: ["ok": true]) }
            request.onCta?("deeplink")
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
                bridge.answer(id: id, payload: ["ok": true])
            } else {
                bridge.fail(id: id, code: .unsupported, message: "sensor unavailable")
            }
        case .motionUnsubscribe(let id, let sensors):
            for sensor in sensors { motion.stop(sensor: sensor) }
            bridge.answer(id: id, payload: ["ok": true])
        case .actionSteps(let id, let actions):
            // Canvas steps over the bridge: the same executor the canvas uses.
            // A dismiss step closes the game like a legacy close; `openGame`
            // has no entry canvas here, so it stays a no-op. Answered only
            // once the steps have run — or not at all, when the skin sent no
            // id or the game closed mid-execution. A steps run counts one
            // click, like one single-op CTA run.
            Task { @MainActor [weak self] in
                guard let self, self.bridge.state != .closed else { return }
                await SDKInstance.shared.executeActionFlow(
                    actions, variables: nil, campaignKey: self.request.campaignKey,
                    localActionExecutor: LocalActionExecutor(
                        dismiss: { [weak self] in self?.dismiss(reason: "skin") }))
                guard self.bridge.state != .closed else { return }
                if let id { self.bridge.answer(id: id, payload: ["ok": true]) }
                self.request.onCta?("steps")
            }
        }
    }

    /// Runs one skin `action` op through the same executor the canvas uses, so
    /// host handlers behave exactly as for any other campaign action. Answered
    /// only once the action has run — or not at all, when the skin sent no id
    /// or the game closed mid-execution. A run counts one click, like
    /// Android's `onCta` — including id-less runs, which still tapped.
    private func runSkinAction(id: String?, action: EngageAction, op: String) {
        Task { @MainActor [weak self] in
            guard let self, self.bridge.state != .closed else { return }
            await SDKInstance.shared.executeActionFlow(
                [action], variables: nil, campaignKey: self.request.campaignKey,
                localActionExecutor: LocalActionExecutor(
                    dismiss: { [weak self] in self?.dismiss(reason: "skin") }))
            guard self.bridge.state != .closed else { return }
            if let id { self.bridge.answer(id: id, payload: ["ok": true]) }
            self.request.onCta?(op)
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
    /// the intake: a missing one answers `invalid`, a denied path answers
    /// `forbidden`, and anything but exact `GET`/`POST` answers `invalid` —
    /// each with its `game_http_failed`, like Android's session — before the
    /// call below runs. The 200 envelope returns unchanged, and anything else
    /// answers by kind.
    private func performHttp(id: String, method: String, path: String, body: [String: Any]?) {
        let start = Date()
        func reject(code: GameBridgeErrorCode) {
            bridge.fail(id: id, code: code, message: self.httpErrorMessage(code))
            SDKInstance.shared.events.toDigia(
                GameHttpFailedEvent(
                    health: self.health, method: method, path: path,
                    code: code.rawValue, status: nil,
                    durationMs: Int(Date().timeIntervalSince(start) * 1000)),
                payload: self.request.payload)
        }
        guard !method.isEmpty, !path.isEmpty else {
            reject(code: .invalid)
            return
        }
        guard let validated = GameHttpBridge.validatedPath(path) else {
            reject(code: .forbidden)
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
                bridge.fail(id: id, code: .internal, message: "request not JSON")
                return
            }
            payloadData = data
        case "GET":
            payloadData = nil
        default:
            reject(code: .invalid)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await GameHttpBridge.send(
                client: SDKInstance.shared.networkClient,
                baseUrl: DigiaEndpoints.baseUrl,
                headers: SDKInstance.shared.requestHeaders,
                method: method, path: validated, body: payloadData)
            guard self.bridge.state != .closed else { return }
            switch result {
            case .success(let success):
                self.bridge.answer(id: id, payload: success.envelope)
            case .failure(let failure):
                self.bridge.fail(id: id, code: failure.code, message: self.httpErrorMessage(failure.code))
                let durationMs = Int(Date().timeIntervalSince(start) * 1000)
                SDKInstance.shared.events.toDigia(
                    GameHttpFailedEvent(
                        health: self.health, method: method, path: validated,
                        code: failure.code.rawValue, status: failure.status,
                        durationMs: durationMs),
                    payload: self.request.payload)
            }
        }
    }

    private func httpErrorMessage(_ code: GameBridgeErrorCode) -> String {
        code == .timeout ? "request timed out" : "request failed"
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
        send(["type": "sensor", "payload": event.payload])
    }

    /// Reports the rendered viewport when it changes (rotation, split
    /// screen). The container calls this on appear and on geometry changes;
    /// unchanged viewports stay silent.
    func pushViewportIfChanged(size: CGSize, safeArea: GameSafeArea) {
        let viewport = (width: Double(size.width), height: Double(size.height), safeArea: safeArea)
        if let last = lastViewport, last == viewport { return }
        lastViewport = viewport
        send([
            "type": "viewport",
            "payload": [
                "width": viewport.width, "height": viewport.height,
                "safeArea": safeArea.payload,
            ],
        ])
    }

    /// Whether the next pushed `device` facts differ from the last push.
    /// Pure, so the shared case-table run pins the change gate without a game.
    static func devicePushChanged(_ next: [String: Any], from last: [String: Any]?) -> Bool {
        guard let last else { return true }
        // Push payloads are flat JSON scalars; NSDictionary equality is exact.
        return !NSDictionary(dictionary: next).isEqual(to: last)
        // Push payloads are flat JSON scalars; NSDictionary equality is exact.
        return !NSDictionary(dictionary: next).isEqual(to: last)
    }

    private func pushDeviceIfChanged(_ info: GameDeviceInfo? = nil) {
        let info = info ?? GameDeviceInfo.current(sdkVersion: sdkVersion)
        let push = info.pushPayload
        guard Self.devicePushChanged(push, from: lastDevicePush) else { return }
        lastDevicePush = push
        send(["type": "device", "payload": push])
    }

    private func pushLifecycle(_ state: String) {
        send(["type": "lifecycle", "payload": ["state": state]])
    }

    private func send(_ message: [String: Any]) {
        guard let script = GameBridge.receiveScript(for: message) else {
            log.w("Game push dropped — message not JSON", campaign: request.campaignKey)
            return
        }
        evaluate(script)
    }

    private func evaluate(_ script: String) {
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
        return GameInitPayload(
            chanceId: request.chanceId,
            campaignId: request.campaignId,
            campaignKey: request.campaignKey,
            skinId: request.skinId,
            skinVersion: request.skinVersion,
            values: request.values,
            slots: request.slots,
            showMute: request.showMute,
            viewportWidth: Double(size.width),
            viewportHeight: Double(size.height),
            safeArea: safeArea,
            colorScheme: scheme == .dark ? "dark" : "light",
            fontFamily: fontFamily,
            themeFonts: request.themeFonts,
            device: GameDeviceInfo.current(
                sdkVersion: SDKInstance.shared.sdkVersion ?? DigiaSdkVersion.value)
        ).message()
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
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.pushLifecycle("pause")
                    self?.motion.suspend()
                }
            },
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.pushLifecycle("resume")
                    self?.motion.resume()
                }
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
        guard bridge.state == .loading else { return }
        finish(report: { [request] in request.onFailure?(.bundleLoadFailed) })
        bridge.close()
    }

    /// Renderer death: destroy, close quietly, games off for the session.
    func failRendering() {
        GameAvailability.isEnabled = false
        guard bridge.state != .closed else { return }
        finish(report: { [request] in request.onFailure?(.renderError) })
        bridge.close()
    }

    /// Native close affordance, and the skin `close` and CTA-handoff paths.
    /// `reason` is `user` for the close button and back, `skin` for the
    /// skin's own `close`, `cta` for a handoff op — the funnel's Dismissed
    /// reason. The bridge fires `onClosed`, which settles.
    func dismiss(reason: String = "user") {
        closeReason = reason
        pushLifecycle("pause")
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
        pushLifecycle("resume")
    }

    /// Ends the session on every path. A game that never became visible has no
    /// container to tear the web view down, so it is torn down here.
    private func finish(report: @MainActor () -> Void) {
        guard !didFinish else { return }
        didFinish = true
        if GamePresenter.loading === self { GamePresenter.loading = nil }
        motion.stopAll()
        removeObservers()
        if !isReady {
            webCoordinator?.view.removeFromSuperview()
            webCoordinator?.teardown()
        }
        SDKInstance.shared.controller.dismissGame()
        report()
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
        guard GameAvailability.isEnabled else {
            log.w("Game not opened — renderer died earlier this session", error: request.campaignKey)
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
        guard let presentation = GamePresentation(request: request) else {
            log.w("Game not opened — bundle entry missing", error: request.campaignKey)
            request.onFailure?(.bundleLoadFailed)
            return
        }
        log.d("Game loading", campaign: request.campaignKey)
        loading = presentation
        presentation.preload()
    }

    /// Closes the open game, if any. Fires `onClose` exactly once; a failure
    /// already reported stays reported.
    static func dismiss() {
        guard let game = SDKInstance.shared.controller.activeGame ?? loading else { return }
        game.dismiss()
    }
}
