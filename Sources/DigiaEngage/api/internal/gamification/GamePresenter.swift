import Foundation

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

/// Session kill-switch: a dead renderer closes the game quietly and turns
/// games off for the rest of the process. The next trigger tries again from
/// scratch on the next launch; no state carries over.
enum GameAvailability {
    nonisolated(unsafe) static var isEnabled = true
}

/// The live game session the overlay controller holds. Owns the bridge, the
/// entry the web view loads, and the exactly-once close/failure callbacks.
/// T8 adds the `play` call and outcome delivery on this same type.
@MainActor
final class GamePresentation: Identifiable, ObservableObject {
    /// The campaign key. One game owns the surface at a time, so this is unique.
    let id: String
    let request: GameOpenRequest
    let entryURL: URL
    let bundleRoot: URL?
    let initPayload: GameInitPayload
    let bridge = GameBridge()

    /// Set when `ready` arrives; the container hides its loader and shows the
    /// web view. Published so the container animates with it.
    @Published private(set) var isReady = false

    private weak var coordinator: GameWebCoordinator?
    private var didFinish = false

    init?(request: GameOpenRequest, safeArea: GameSafeArea) {
        self.request = request
        self.id = request.campaignKey
        switch request.source {
        case .localFolder(let folder):
            let root = folder.standardizedFileURL
            let entry = root.appendingPathComponent("index.html").standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: entry.path, isDirectory: &isDirectory), !isDirectory.boolValue
            else { return nil }
            self.bundleRoot = root
            self.entryURL = URL(string: "\(GameURLPolicy.scheme)://bundle/index.html")!
        case .remoteEntry(let url):
            self.bundleRoot = nil
            self.entryURL = url
        }
        self.initPayload = GameInitPayload(
            surface: request.container,
            safeArea: safeArea,
            locale: GameInitPayload.deviceLocale,
            showMute: request.showMute
        )
        bridge.onReady = { [weak self] in self?.didBecomeReady() }
        bridge.onClosed = { [weak self] in self?.didClose() }
        bridge.onFailed = { [weak self] reason in self?.didFail(reason) }
    }

    func attach(coordinator: GameWebCoordinator) {
        self.coordinator = coordinator
    }

    /// Sends `init` after the page loads. Each `init` fully resets the skin;
    /// T8 re-sends it after `playNext` with a new play id.
    func sendInit() {
        guard let script = bridge.script(for: initPayload.message()) else { return }
        coordinator?.view.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Main page load failure before `ready`: close early without waiting for
    /// the timer. After `ready` the bundle is up; subresource failures stay
    /// the skin's own fallback art.
    func failLoading() {
        guard bridge.state == .loading else { return }
        bridge.close()
        finishAsFailure(.bundleLoadFailed)
    }

    /// Renderer death: destroy, close quietly, games off for the session.
    func failRendering() {
        GameAvailability.isEnabled = false
        guard bridge.state != .closed else { return }
        bridge.close()
        finishAsFailure(.renderError)
    }

    /// Native close affordance. The bridge fires `onClosed`, which settles.
    func dismiss() {
        bridge.close()
    }

    private func didBecomeReady() {
        isReady = true
    }

    private func didClose() {
        guard !didFinish else { return }
        didFinish = true
        SDKInstance.shared.controller.dismissGame()
        request.onClose?()
    }

    private func didFail(_ reason: GameFailure) {
        finishAsFailure(reason)
    }

    private func finishAsFailure(_ reason: GameFailure) {
        guard !didFinish else { return }
        didFinish = true
        log.w("Game closed", error: reason.rawValue)
        SDKInstance.shared.controller.dismissGame()
        request.onFailure?(reason)
    }
}

/// The one internal entry point routing calls to open a game. T2's
/// `grantChance` hook calls `open(_:)` on `granted && show`; teardown and the
/// skin `close` funnel back through `dismiss()`.
@MainActor
enum GamePresenter {
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
        let safeArea = GameSafeArea.forContainer(
            request.container, system: activeWindowSafeAreaInsets)
        guard let presentation = GamePresentation(request: request, safeArea: safeArea) else {
            log.w("Game not opened — bundle entry missing", error: request.campaignKey)
            request.onFailure?(.bundleLoadFailed)
            return
        }
        log.d("Game opening", campaign: request.campaignKey)
        SDKInstance.shared.controller.showGame(presentation)
    }

    /// Closes the open game, if any. Fires `onClose` exactly once; a failure
    /// already reported stays reported.
    static func dismiss() {
        guard let game = SDKInstance.shared.controller.activeGame else { return }
        game.dismiss()
    }
}
