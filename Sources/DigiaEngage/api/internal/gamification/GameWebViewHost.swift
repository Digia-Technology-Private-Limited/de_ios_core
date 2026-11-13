import Foundation
import SwiftUI
import WebKit

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

/// Serves the cached bundle folder through `digia-skin://`, one to one onto
/// the bundle path, with the contract CSP on every response. iOS cannot
/// intercept https, so this handler is the iOS half of the cache serving T11
/// fills; until then routing loads the remote entry and this handler idles.
final class GameSchemeHandler: NSObject, WKURLSchemeHandler {
    private let bundleRoot: URL

    init(bundleRoot: URL) {
        self.bundleRoot = bundleRoot.standardizedFileURL
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let relative = GameURLPolicy.filePath(for: url),
              let file = GameURLPolicy.localFile(forRelativePath: relative, bundleRoot: bundleRoot),
              let mime = GameURLPolicy.mimeType(for: file.pathExtension),
              let data = try? Data(contentsOf: file),
              let response = HTTPURLResponse(
                  url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                  headerFields: [
                      "Content-Type": mime,
                      "Content-Security-Policy": GameURLPolicy.contentSecurityPolicy,
                  ])
        else {
            let error = NSError(
                domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError, userInfo: nil)
            urlSchemeTask.didFailWithError(error)
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // File reads are synchronous and short; nothing to cancel.
    }
}

/// Breaks the retain cycle `WKUserContentController` would otherwise close:
/// the controller holds its message handlers strongly, so the handler held
/// here must not hold the coordinator (and through it the web view) back.
final class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler?) {
        self.target = target
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// Builds the locked-down `WKWebViewConfiguration` from the web view contract:
/// non-persistent storage (DOM storage and cookies off), the `digia` handler
/// on the main frame only, selection and callout off, bounce off, playback
/// gated on a user gesture, inspection in debug builds only.
enum GameWebViewConfigurationFactory {
    /// Defines `window.digia.postMessage` for skins that speak the
    /// Android/Flutter spelling. Skins using the iOS spelling
    /// (`window.webkit.messageHandlers.digia.postMessage`) reach the same
    /// native handler directly.
    private static let digiaShimScript =
        "window.digia = { postMessage: function(message) { " +
        "window.webkit.messageHandlers.digia.postMessage(message); } };"

    private static let noSelectionStyle =
        "* { -webkit-user-select: none !important; -webkit-touch-callout: none !important; }"

    static func make(
        bundleRoot: URL?,
        messageProxy: WKScriptMessageHandler
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true
        // Matches Android's setMediaPlaybackRequiresUserGesture(true): the
        // skin starts audio after the user's first tap.
        configuration.mediaTypesRequiringUserActionForPlayback = .all

        let controller = configuration.userContentController
        controller.add(messageProxy, name: "digia")
        controller.addUserScript(WKUserScript(
            source: digiaShimScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        let styleScript =
            "var style = document.createElement('style'); style.textContent = '\(noSelectionStyle)'; " +
            "(document.head || document.documentElement).appendChild(style);"
        controller.addUserScript(WKUserScript(
            source: styleScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

        if let bundleRoot {
            configuration.setURLSchemeHandler(
                GameSchemeHandler(bundleRoot: bundleRoot),
                forURLScheme: GameURLPolicy.scheme
            )
        }
        return configuration
    }
}

/// Owns the `WKWebView` and glues it to the `GamePresentation`: loads the
/// entry, enforces the URL policy, forwards `digia` messages to the bridge,
/// sends `init` on page load, arms the ready timer, and tears everything down.
/// Nonisolated because `WKNavigationDelegate` is an ObjC protocol; every touch
/// of game state hops to the main actor, in arrival order.
final class GameWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private weak var game: GamePresentation?
    private let entryURL: URL
    private let webView: WKWebView

    init(game: GamePresentation, entryURL: URL, bundleRoot: URL?) {
        self.game = game
        self.entryURL = entryURL
        let proxy = WeakScriptMessageProxy(target: nil)
        let configuration = GameWebViewConfigurationFactory.make(
            bundleRoot: bundleRoot,
            messageProxy: proxy
        )
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        if #available(iOS 16.4, *) {
            // Debug builds only: a release web view is never inspectable.
            webView.isInspectable = SDKInstance.shared.isDebugBuild
        }
        super.init()
        proxy.target = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // Contract safety rails: no bounce, no zoom, no link preview. The skin
        // owns its own pinch-free layout; the scroll view's recognizers would
        // only fight it.
        webView.scrollView.bounces = false
        // The skin pads itself from `safeArea` in `init`; letting the scroll
        // view inset too leaves a blank band above the home indicator.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.minimumZoomScale = 1
        webView.scrollView.maximumZoomScale = 1
        if let pinch = webView.scrollView.pinchGestureRecognizer {
            pinch.isEnabled = false
        }
        webView.allowsLinkPreview = false
    }

    var view: WKWebView { webView }

    /// Starts the load and the 5 s ready timer. The timer carries the bridge
    /// generation so a stale fire after a reload can never close the new load.
    func start() {
        webView.load(URLRequest(url: entryURL))
        // `beginLoading` runs on the main actor; the timer arms there too, so
        // the generation it captures is the one from this load, in order.
        Task { @MainActor [weak game] in
            guard let game else { return }
            let current = game.bridge.beginLoading()
            DispatchQueue.main.asyncAfter(
                deadline: .now() + GameBridge.readyTimeoutSeconds
            ) { [weak game] in
                Task { @MainActor [weak game] in
                    game?.bridge.readyTimeoutFired(generation: current)
                }
            }
        }
    }

    /// Stops the load, detaches the message handler, and closes the bridge.
    /// SwiftUI calls this when the container goes away; closing an already
    /// closed bridge is a no-op, never a second callback.
    func teardown() {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "digia")
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        Task { @MainActor [weak game] in game?.bridge.close() }
    }

    // MARK: - WKScriptMessageHandler (digia.postMessage)

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // The handler is main-frame-only, and the scheme check below keeps a
        // foreign iframe from driving the game even if one were ever embedded.
        guard message.frameInfo.isMainFrame else { return }
        let body = message.body
        Task { @MainActor [weak game] in game?.bridge.receive(body) }
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        decisionHandler(GameURLPolicy.allowNavigation(
            url: url,
            entryURL: entryURL,
            navigationType: navigationAction.navigationType,
            isMainFrame: isMainFrame
        ) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak game] in game?.sendInit() }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        let code = (error as NSError).code
        // Our own policy cancels land here; only a real load failure closes.
        guard code != NSURLErrorCancelled else { return }
        log.w("Game bundle failed to load", error: error.localizedDescription)
        Task { @MainActor [weak game] in game?.failLoading() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log.w("Game web content process terminated")
        Task { @MainActor [weak game] in game?.failRendering() }
    }

    // MARK: - WKUIDelegate

    /// `window.open` never opens: links work only through the native bridge
    /// (T8's `useReward`), never by navigating away.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }
}

/// The SwiftUI seam for the game web view. One coordinator owns one web view
/// for the life of this view; teardown runs when the container dismisses.
struct GameWebViewHost: UIViewRepresentable {
    let game: GamePresentation

    func makeCoordinator() -> GameWebCoordinator {
        let coordinator = GameWebCoordinator(
            game: game,
            entryURL: game.entryURL,
            bundleRoot: game.bundleRoot
        )
        game.attach(coordinator: coordinator)
        return coordinator
    }

    func makeUIView(context: Context) -> WKWebView {
        let view = context.coordinator.view
        context.coordinator.start()
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Loads once in makeUIView. State changes (`ready`) flow through the
        // observed presentation, never through a reload.
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: GameWebCoordinator) {
        coordinator.teardown()
    }
}
