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
/// callbacks. Answers every bridge v1 request: generic `http`, `event`,
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

    private var didFinish = false
    private let haptics = GameHaptics()
    private let motion = GameMotionSource()
    private let storage: GameSkinStorage
    /// The one `init` for this session: built from the open request and the
    /// live facts, re-sent unchanged on a repeated `ready`.
    private let initMessage: [String: Any]
    private var lastViewport: (width: Double, height: Double, safeArea: GameSafeArea)?
    private var lastDevicePush: [String: Any]?
    private var observers: [NSObjectProtocol] = []

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
                projectId: request.projectId, skinId: request.skinId, userId: request.userId))
        self.initMessage = Self.initMessage(for: request)
        bridge.onReady = { [weak self] version in self?.didBecomeReady(version: version) }
        bridge.onRepeatedReady = { [weak self] _ in self?.sendInit() }
        bridge.onRequest = { [weak self] request in self?.handle(request) }
        bridge.onSend = { [weak self] script in self?.evaluate(script) }
        bridge.onClosed = { [weak self] in self?.didClose() }
        bridge.onFailed = { [weak self] reason in self?.didFail(reason) }
        observeDeviceSignals()
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
        // The fields go both under `payload` (bridge v1) and flat beside `type`:
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
        case .event(let id, let name, let props):
            SDKInstance.shared.reportGameSkinEvent(
                name: name, properties: props, payload: self.request.payload,
                skinId: self.request.skinId, skinVersion: self.request.skinVersion,
                chanceId: self.request.chanceId)
            if let id { bridge.answer(id: id) }
        case .log(let id, let level, let message):
            emitSkinLog(level: level, message: message)
            if let id { bridge.answer(id: id) }
        case .haptics(let id, let style):
            if !haptics.play(style) {
                log.d("Game haptic dropped (style=\(style.rawValue))", campaign: self.request.campaignKey)
            }
            if let id { bridge.answer(id: id) }
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
                bridge.fail(id: id, code: .invalid, message: "invalid key")
                return
            }
            storage.remove(key)
            bridge.answer(id: id)
        case .actionCopy(let id, let text):
            UIPasteboard.general.string = text
            if let id { bridge.answer(id: id) }
        case .actionOpenLink(let id, let url):
            // Contract: the container closes first, then the host opens the link.
            if let id { bridge.answer(id: id) }
            let openLink = request.openLink
            dismiss()
            if let openLink { openLink(url) } else { UIApplication.shared.open(url) }
        case .actionClose(let id, let reason):
            if let reason, !reason.isEmpty {
                log.d("Game closed by skin (reason=\(reason))", campaign: self.request.campaignKey)
            }
            if let id { bridge.answer(id: id) }
            dismiss()
        case .actionSteps(let id, let actions):
            // Canvas steps over the bridge: the same executor the canvas uses.
            // A dismiss step closes the game like a legacy close; `openGame`
            // has no entry canvas here, so it stays a no-op. Answered only
            // once the steps have run — or not at all, when the skin sent no
            // id (S9) or the game closed mid-execution.
            Task { @MainActor [weak self] in
                guard let self, self.bridge.state != .closed else { return }
                await SDKInstance.shared.executeActionFlow(
                    actions, variables: nil, campaignKey: self.request.campaignKey,
                    localActionExecutor: LocalActionExecutor(
                        dismiss: { [weak self] in self?.dismiss() }))
                guard self.bridge.state != .closed else { return }
                if let id { self.bridge.answer(id: id) }
            }
        }
    }

    /// One generic skin backend call. The path allowlist is the gate; the 200
    /// envelope returns unchanged, and anything else answers by kind.
    private func performHttp(id: String, method: String, path: String, body: [String: Any]?) {
        guard let validated = GameHttpBridge.validatedPath(path) else {
            bridge.fail(id: id, code: .forbidden, message: "forbidden path")
            return
        }
        guard let httpMethod = GameHttpBridge.httpMethod(method) else {
            bridge.fail(id: id, code: .invalid, message: "method must be GET or POST")
            return
        }
        // Encoded before the hop: `[String: Any]` is not Sendable, `Data` is.
        let payload: Data?
        switch httpMethod {
        case .post:
            guard let data = GameHttpBridge.jsonData(body ?? [:]) else {
                bridge.fail(id: id, code: .internal, message: "request not JSON")
                return
            }
            payload = data
        case .get:
            payload = nil
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await GameHttpBridge.send(
                client: SDKInstance.shared.networkClient,
                baseUrl: DigiaEndpoints.baseUrl,
                headers: SDKInstance.shared.requestHeaders,
                method: httpMethod, path: validated, body: payload)
            guard self.bridge.state != .closed else { return }
            switch result {
            case .success(let envelope):
                self.bridge.answer(id: id, payload: envelope)
            case .failure(let code):
                self.bridge.fail(id: id, code: code, message: self.httpErrorMessage(code))
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
        default: log.e(message, campaign: campaign)
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

    private func pushesEqual(_ left: [String: Any], _ right: [String: Any]?) -> Bool {
        guard let right else { return false }
        // Push payloads are flat JSON scalars; NSDictionary equality is exact.
        return NSDictionary(dictionary: left).isEqual(to: right)
    }

    private func pushDeviceIfChanged() {
        let info = GameDeviceInfo.current(sdkVersion: sdkVersion)
        let push = info.pushPayload
        guard !pushesEqual(push, lastDevicePush) else { return }
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
        let fontFamily = SDKInstance.shared.config?.fontFamily?
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
            fontFamily: fontFamily?.isEmpty == false ? fontFamily : nil,
            themeFonts: [],
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
    }

    private func removeObservers() {
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

    /// Native close affordance. The bridge fires `onClosed`, which settles.
    func dismiss() {
        pushLifecycle("pause")
        motion.stopAll()
        bridge.close()
    }

    private func didBecomeReady(version: Int) {
        guard !didFinish, !isReady else { return }
        guard version <= GameBridge.bridgeVersion else {
            log.w(
                "Game closed — skin needs bridge v\(version)",
                campaign: request.campaignKey)
            finish(report: { [request] in request.onFailure?(.bridgeUnsupported) })
            bridge.close()
            return
        }
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

    private func didClose() {
        finish(report: { [request] in request.onClose?() })
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
    /// container exists (unsupported runtime, games off, missing bundle) call
    /// `onFailure` directly and open nothing.
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
        guard let presentation = GamePresentation(request: request) else {
            log.w("Game not opened — bundle entry missing", error: request.campaignKey)
            request.onFailure?(.bundleLoadFailed)
            return
        }
        // One game owns the surface: a re-trigger must not restart the live one.
        guard !isBusy else {
            log.w("Game not opened — another game is already open", error: request.campaignKey)
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
