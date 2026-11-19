import Combine
import SafariServices
import SwiftUI
import UIKit
import WebKit

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

extension Notification.Name {
    /// Posted when a game opened for a rewards chance closes, so an open
    /// rewards page can refresh itself.
    static let digiaRewardsGameClosed = Notification.Name("tech.digia.engage.rewardsGameClosed")
}

/// Hosts the web rewards page. Presented full screen by `present`, but it
/// assumes nothing about how it is shown: it closes by dismissing or popping.
///
/// A native loading view covers the web view until the page sends `ready`.
/// A native offline view replaces it on any failure, so the user never sees a
/// WebKit error page. Both carry a close button.
@MainActor
final class RewardsPageViewController: UIViewController, WKNavigationDelegate, WKUIDelegate,
    WKScriptMessageHandler
{
    static let readyTimeoutSeconds = 10.0

    enum State: Equatable { case loading, ready, offline }

    private static weak var current: RewardsPageViewController?

    /// Presents the page full screen over the top-most view controller. A page
    /// already open stays the only one.
    static func present(resolveURL: @escaping () async -> URL) {
        guard current == nil else { return }
        let page = RewardsPageViewController(resolveURL: resolveURL)
        page.modalPresentationStyle = .fullScreen
        current = page
        ViewControllerUtil.present(page)
    }

    /// Forwards the page's script errors (message, source, line only) so a
    /// broken page is visible in the logs.
    static let errorForwardScript = """
        (function () {
          function send(m, s, l) {
            try {
              window.webkit.messageHandlers.digiaPageError.postMessage(JSON.stringify(
                { m: String(m).slice(0, 200), s: String(s || '').slice(0, 200), l: l || 0 }));
            } catch (e) {}
          }
          window.addEventListener('error', function (e) { send(e.message, e.filename, e.lineno); });
          window.addEventListener('unhandledrejection', function (e) {
            var r = e.reason; send(r && r.message ? r.message : r, 'promise', 0);
          });
        })();
        """

    private(set) var state: State = .loading
    /// The page's last `navState`. False unless the page is shown. A pushed
    /// page can gate the navigation controller's `interactivePopGestureRecognizer`
    /// on this through `onCanGoBackChange`.
    private(set) var canGoBack = false {
        didSet { if canGoBack != oldValue { onCanGoBackChange?(canGoBack) } }
    }
    var onCanGoBackChange: ((Bool) -> Void)?

    /// Whether a back request goes to the page: only while it is shown and said
    /// it has a screen to go back to. Otherwise the swipe does nothing.
    static func shouldGoBack(canGoBack: Bool, state: State) -> Bool {
        canGoBack && state == .ready
    }
    private let resolveURL: () async -> URL
    private var pageURL: URL?
    private var loadToken = 0
    private var readyTimer: DispatchWorkItem?
    private var loadTask: Task<Void, Never>?
    private var isVisible = false
    private var observers: [NSObjectProtocol] = []
    private var layerToken: Int?
    private var gameWatch: AnyCancellable?
    private var gameHost: UIViewController?

    private let webView: WKWebView
    private let loadingView = UIView()
    private let offlineView = UIView()
    private let closeButton = UIButton(type: .system)

    /// The native views are always light, whatever the system appearance.
    private enum Palette {
        static let background = UIColor(red: 1, green: 1, blue: 1, alpha: 1)
        static let spinner = UIColor(red: 0x9C / 255, green: 0xA3 / 255, blue: 0xAF / 255, alpha: 1)
        static let text = UIColor(red: 0x11 / 255, green: 0x18 / 255, blue: 0x27 / 255, alpha: 1)
        static let control = UIColor(red: 0x37 / 255, green: 0x41 / 255, blue: 0x51 / 255, alpha: 1)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }

    init(resolveURL: @escaping () async -> URL) {
        self.resolveURL = resolveURL
        let proxy = WeakScriptMessageProxy(target: nil)
        let configuration = WKWebViewConfiguration()
        // The default store keeps the page's hashed assets cached between opens.
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(proxy, name: "digia")
        configuration.userContentController.add(proxy, name: "digiaPageError")
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.errorForwardScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
        proxy.target = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - View

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.background
        if #available(iOS 16.4, *) { webView.isInspectable = SDKInstance.shared.isDebugBuild }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsLinkPreview = false
        // The web view's own back-forward swipe stays off: the page owns its screens.
        webView.allowsBackForwardNavigationGestures = false
        let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edgeSwiped(_:)))
        edge.edges = .left
        edge.cancelsTouchesInView = false
        view.addGestureRecognizer(edge)
        webView.isHidden = true
        // Light only on the native views; the web view keeps the system appearance.
        [loadingView, offlineView, closeButton].forEach { $0.overrideUserInterfaceStyle = .light }
        [webView, loadingView, offlineView, closeButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        buildLoadingView()
        buildOfflineView()
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = Palette.control
        closeButton.accessibilityLabel = "Close"
        closeButton.addAction(UIAction { [weak self] _ in self?.closePage() }, for: .touchUpInside)
        observe()
        claimGameLayer()
        startLoad()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || isMovingFromParent || navigationController?.isBeingDismissed == true {
            tearDown()
        }
    }

    private func buildLoadingView() {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        loadingView.backgroundColor = Palette.background
        spinner.color = Palette.spinner
        loadingView.addSubview(spinner)
        pin(loadingView)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: loadingView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: loadingView.centerYAnchor),
        ])
    }

    private func buildOfflineView() {
        let title = UILabel()
        title.text = "You're offline"
        title.font = .preferredFont(forTextStyle: .headline)
        title.textColor = Palette.text
        let retry = UIButton(type: .system)
        retry.setTitle("Retry", for: .normal)
        retry.setTitleColor(Palette.control, for: .normal)
        retry.addAction(UIAction { [weak self] _ in self?.startLoad() }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [title, retry])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        offlineView.backgroundColor = Palette.background
        offlineView.isHidden = true
        offlineView.addSubview(stack)
        pin(offlineView)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: offlineView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: offlineView.centerYAnchor),
        ])
    }

    private func pin(_ child: UIView) {
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: view.topAnchor),
            child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        // The close button stays above the native views.
        view.bringSubviewToFront(closeButton)
    }

    private func show(_ next: State) {
        state = next
        webView.isHidden = next != .ready
        loadingView.isHidden = next != .loading
        offlineView.isHidden = next != .offline
        closeButton.isHidden = next == .ready
        if next != .ready { canGoBack = false }
    }

    // MARK: - Loading

    /// Starts (or restarts) a load: resolves the URL, loads it, and gives the
    /// page `readyTimeoutSeconds` from the moment the load starts to send
    /// `ready`. A newer load makes every older step a no-op. The task never
    /// holds the page across the URL lookup.
    private func startLoad() {
        loadToken += 1
        let token = loadToken
        show(.loading)
        readyTimer?.cancel()
        loadTask?.cancel()
        let resolve = resolveURL
        loadTask = Task { @MainActor [weak self] in
            let url = await resolve()
            guard let self, !Task.isCancelled, token == self.loadToken else { return }
            self.pageURL = url
            self.webView.load(URLRequest(url: url))
            let timer = DispatchWorkItem { [weak self] in
                guard let self, self.state == .loading else { return }
                log.w("Rewards page sent no ready in time")
                self.showOffline()
            }
            self.readyTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.readyTimeoutSeconds, execute: timer)
        }
    }

    /// Stops everything that could keep the page alive once it is gone.
    private func tearDown() {
        loadToken += 1
        loadTask?.cancel()
        readyTimer?.cancel()
        webView.stopLoading()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        gameWatch = nil
        if let layerToken { GameLayerOwner.release(layerToken) }
        layerToken = nil
        // A game still open falls back to the root cover: have it re-read the gate.
        SDKInstance.shared.controller.objectWillChange.send()
        if Self.current === self { Self.current = nil }
    }

    private func showOffline() {
        loadToken += 1
        readyTimer?.cancel()
        webView.stopLoading()
        show(.offline)
    }

    private func didBecomeReady() {
        guard state == .loading else { return }
        readyTimer?.cancel()
        show(.ready)
    }

    // MARK: - Bridge

    private func sendInit() {
        guard let context = Self.liveContext() else { return }
        push(RewardsBridge.initMessage(context))
    }

    @objc private func edgeSwiped(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard gesture.state == .recognized || gesture.state == .ended,
              Self.shouldGoBack(canGoBack: canGoBack, state: state)
        else { return }
        push(RewardsBridge.backMessage)
    }

    private func pushRefresh() {
        guard state == .ready else { return }
        push(RewardsBridge.refreshMessage)
    }

    private func push(_ message: [String: Any]) {
        guard let script = RewardsBridge.script(for: message) else { return }
        webView.evaluateJavaScript(script)
    }

    /// Identity and context from the live SDK. Nil when the SDK is not set up.
    private static func liveContext() -> RewardsBridge.Context? {
        let sdk = SDKInstance.shared
        guard let services = sdk.services else { return nil }
        let headers = services.requestHeaders
        return RewardsBridge.Context(
            apiBase: "\(DigiaEndpoints.baseUrl)/api/v1",
            projectId: headers["X-Digia-Project-Id"] ?? "",
            userId: services.identityManager.userId ?? "",
            userHash: services.identityManager.userHash,
            platform: "ios",
            sdkVersion: sdk.sdkVersion ?? DigiaSdkVersion.value,
            appVersion: headers["x-app-version"] ?? "",
            deviceId: services.identityManager.deviceId,
            locale: RewardsBridge.bcp47Locale())
    }

    /// Owns the game layer while the page is open, so a game opened from the
    /// page shows over it instead of replacing it. A game already open stays
    /// on the app's root cover.
    private func claimGameLayer() {
        let controller = SDKInstance.shared.controller
        layerToken = GameLayerOwner.claim(
            existingGame: controller.activeGame.map(ObjectIdentifier.init),
            isLive: { [weak self] in
                guard let self else { return false }
                return self.view.window != nil || self.presentingViewController != nil || self.parent != nil
            })
        gameWatch = controller.$activeGame.receive(on: DispatchQueue.main).sink { [weak self] game in
            self?.gameChanged(game)
        }
    }

    private func gameChanged(_ game: GamePresentation?) {
        guard let game, GameLayerOwner.layer(for: ObjectIdentifier(game)) == .rewards else {
            // Closing goes through `GamePresenter.dismiss`, so the session
            // already settled; only the cover is removed here.
            gameHost?.dismiss(animated: false)
            gameHost = nil
            return
        }
        gameHost?.dismiss(animated: false)
        let host = UIHostingController(rootView: GameLayerView(game: game))
        host.modalPresentationStyle = .overFullScreen
        host.view.backgroundColor = .clear
        gameHost = host
        ViewControllerUtil.topViewController(base: self)?.present(host, animated: false)
    }

    private func observe() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isVisible else { return }
                    self.pushRefresh()
                }
            },
            center.addObserver(
                forName: .digiaRewardsGameClosed, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.pushRefresh() }
            },
        ]
    }

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        if message.name == "digiaPageError" {
            if let text = message.body as? String { log.w("Rewards page script error", error: String(text.prefix(450))) }
            return
        }
        guard message.frameInfo.isMainFrame,
              RewardsPageURL.isSameOrigin(message.frameInfo.request.url, as: pageURL),
              let page = RewardsBridge.parse(message.body)
        else { return }
        handle(page)
    }

    private func handle(_ message: RewardsPageMessage) {
        switch message {
        case .ready:
            didBecomeReady()
        case .loadFailed:
            showOffline()
        case .openGame(let chanceId, let campaignId):
            guard state == .ready else { return }
            SDKInstance.shared.gamification.openGameForRewardsChance(
                GameRewardChance(
                    chanceId: chanceId, campaignId: campaignId, format: nil,
                    rewardsPageTitle: nil, expiresAt: nil, playable: true))
        case .openLink(let raw):
            open(link: raw)
        case .copy(let text):
            ActionPlatform.current.copy(text)
        case .close:
            closePage()
        case .navState(let flag):
            canGoBack = state == .ready && flag
        }
    }

    private func open(link raw: String) {
        switch RewardsLinkRouter.route(
            raw, appLinkHosts: Set(SDKInstance.shared.rewardsResponse?.appLinkDomains ?? [])) {
        case .refused:
            log.w("Rewards link refused")
        case .internal(let url):
            closePage {
                SDKInstance.shared.gamification.openRewardDeepLink(url.absoluteString)
            }
        case .external(let url):
            if url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https" {
                let safari = SFSafariViewController(url: url)
                ViewControllerUtil.topViewController(base: self)?.present(safari, animated: true)
            } else {
                ActionPlatform.current.open(url)
            }
        }
    }

    /// Dismisses the page, or pops it when it was pushed.
    func closePage(completion: (() -> Void)? = nil) {
        if let navigation = navigationController, navigation.viewControllers.first !== self {
            navigation.popViewController(animated: true)
            completion?()
        } else {
            dismiss(animated: true, completion: completion)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(
            RewardsPageURL.allowNavigation(
                url: url, pageURL: pageURL, hasTargetFrame: navigationAction.targetFrame != nil)
                ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame, RewardsPageURL.isHttpError(navigationResponse.response) {
            showOffline()
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        sendInit()
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        showOffline()
    }

    /// Our own cancels (policy, http error) land here too; only a real failure
    /// shows the offline view.
    private func failed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        log.w("Rewards page failed to load", error: error.localizedDescription)
        showOffline()
    }

    // MARK: - WKUIDelegate

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }
}
