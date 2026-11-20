import Foundation
import UIKit
import WebKit

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

/// The engine prewarm: one hidden blank `WKWebView`, built with the game web
/// view's exact configuration, so the next game skips the web engine's cold
/// start. The next game adopts this very instance (`takeEngine`); a new one
/// is built lazily afterwards.
///
/// Off unless the SDK config's `gamification.prewarm` allows the engine and
/// the device is tier `full` with enough RAM. It exists only while the last
/// campaign sync left at least one gamification campaign. A memory warning or
/// the app going to background frees it; the next app activation or sync
/// rebuilds it if still allowed.
@MainActor
enum GamePrewarmer {
    /// A warm engine: the blank web view and the message proxy its
    /// configuration registered. The adopting coordinator points the proxy at
    /// itself, so the skin's `digia` messages reach it.
    final class Engine {
        let webView: WKWebView
        let proxy: WeakScriptMessageProxy

        init(webView: WKWebView, proxy: WeakScriptMessageProxy) {
            self.webView = webView
            self.proxy = proxy
        }
    }

    private static var engine: Engine?
    /// Whether the last campaign sync left at least one gamification campaign.
    private static var hasGameCampaigns = false
    private static var observers: [NSObjectProtocol] = []

    /// Campaign sync: keeps the engine when a gamification campaign remains
    /// and the device is eligible, frees it otherwise.
    static func campaignsSynced(_ campaigns: [CampaignModel]) {
        hasGameCampaigns = campaigns.contains { $0.gamificationConfig != nil }
        observeAppSignals()
        refreshEngine()
    }

    /// Builds the engine if it qualifies and is missing; frees it if it no
    /// longer qualifies (config off, or the device dropped out of `full`).
    static func refreshEngine() {
        guard hasGameCampaigns, engineAllowed() else {
            freeEngine(reason: "not_eligible")
            return
        }
        guard engine == nil else { return }
        engine = makeEngine()
        log.d("prewarm engine created")
    }

    /// Hands the warm engine to a game, which uses it as its web view. Nil
    /// when there is none, or its blank page is still loading — the game then
    /// builds its own web view, exactly as without the prewarm.
    static func takeEngine() -> Engine? {
        guard let warm = engine, !warm.webView.isLoading else { return nil }
        engine = nil
        log.d("prewarm engine used")
        return warm
    }

    static func freeEngine(reason: String) {
        guard let warm = engine else { return }
        engine = nil
        warm.webView.stopLoading()
        warm.webView.configuration.userContentController.removeScriptMessageHandler(forName: "digia")
        log.d("prewarm engine freed reason=\(reason)")
    }

    static var hasEngineForTesting: Bool { engine != nil }

    static func resetForTesting() {
        freeEngine(reason: "reset")
        hasGameCampaigns = false
    }

    private static func engineAllowed() -> Bool {
        guard #available(iOS 17, *) else { return false }
        guard UIApplication.shared.applicationState != .background else { return false }
        let device = GameDeviceInfo.current(sdkVersion: DigiaSdkVersion.value)
        return SDKInstance.shared.gamePrewarm.allowsEngine(tier: device.tier, ramMb: device.ramMb)
    }

    private static func makeEngine() -> Engine {
        let proxy = WeakScriptMessageProxy(target: nil)
        let configuration = GameWebViewConfigurationFactory.make(messageProxy: proxy)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // Starts the web content process now; the game's own load reuses it.
        webView.loadHTMLString("", baseURL: nil)
        return Engine(webView: webView, proxy: proxy)
    }

    private static func observeAppSignals() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil, queue: .main) { _ in
                Task { @MainActor in freeEngine(reason: "memory") }
            },
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil, queue: .main) { _ in
                Task { @MainActor in freeEngine(reason: "background") }
            },
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil, queue: .main) { _ in
                Task { @MainActor in refreshEngine() }
            },
        ]
    }
}
