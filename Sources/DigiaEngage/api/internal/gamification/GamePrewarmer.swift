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
///
/// The game prewarm: at most one warm game (`GamePresentation` held before
/// `init`), started at an entry's impression or alongside a Direct grant
/// request, adopted by `GamePresenter.open` on the tap or grant. Off unless
/// the config allows `game`. Discards send no analytics, only a debug log.
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
        if let key = warm?.id, !campaigns.contains(where: { $0.campaignKey == key }) {
            discard(reason: "campaign_removed")
        }
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
        discard(reason: "reset")
        hasGameCampaigns = false
    }

    // MARK: - Game prewarm

    private static var warm: GamePresentation?
    private static var warmSource: GamePrewarmSource = .entry
    private static var hiddenSince: Date?

    /// Warms `request` in the single slot: the newest entry replaces an older
    /// warm game, Direct replaces an entry's, an entry never replaces Direct.
    static func warmGame(_ request: GameOpenRequest, source: GamePrewarmSource) {
        guard gameAllowed(request) else { return }
        switch GamePrewarmPolicy.slot(
            currentKey: warm?.id, currentSource: warm == nil ? nil : warmSource,
            incomingKey: request.campaignKey, incomingSource: source) {
        case .keep, .skip: return
        case .replace: discard(reason: "replaced")
        case .warm: break
        }
        guard let game = GamePresentation(request: request) else { return }
        warm = game
        warmSource = source
        hiddenSince = nil
        game.preload(held: true)
        log.d("prewarm game started source=\(source) campaign=\(request.campaignKey)")
        let warmedAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + GamePrewarmPolicy.idleSeconds + 0.1) {
            Task { @MainActor in
                guard warm === game,
                      GamePrewarmPolicy.isIdle(warmedAt: warmedAt, now: Date())
                else { return }
                discard(reason: "idle")
            }
        }
    }

    /// The warm game prewarmed for this open, handed over and cleared from the
    /// slot. A warm game that does not match (other campaign, bundle or user)
    /// or whose load failed is discarded (`replaced`); the open then loads
    /// normally.
    static func takeGame(matching request: GameOpenRequest) -> GamePresentation? {
        guard let game = warm else { return nil }
        guard game.isHeld, !game.heldLoadFailed,
              game.id == request.campaignKey,
              game.entryFile == request.entryFile,
              game.request.userId == request.userId
        else {
            discard(reason: "replaced")
            return nil
        }
        warm = nil
        hiddenSince = nil
        log.d("prewarm game used campaign=\(request.campaignKey)")
        return game
    }

    /// Destroys the warm game, if any; with `campaignKey`, only when it is that
    /// campaign's. Silent: a debug log, never analytics.
    static func discard(reason: String, campaignKey: String? = nil) {
        guard let game = warm else { return }
        if let campaignKey, campaignKey != game.id { return }
        warm = nil
        hiddenSince = nil
        log.d("prewarm discard reason=\(reason) campaign=\(game.id)")
        game.discardWarm()
    }

    /// An inline entry's slot visibility. Off screen for more than 3 s
    /// discards (`offscreen`); back on screen sooner keeps the game.
    static func entryVisibility(campaignKey: String, visible: Bool) {
        guard let game = warm, game.id == campaignKey else { return }
        guard !visible else {
            hiddenSince = nil
            return
        }
        guard hiddenSince == nil else { return }
        hiddenSince = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + GamePrewarmPolicy.offscreenGraceSeconds + 0.1) {
            Task { @MainActor in
                guard warm === game,
                      GamePrewarmPolicy.shouldDiscardOffscreen(hiddenSince: hiddenSince, now: Date())
                else { return }
                discard(reason: "offscreen")
            }
        }
    }

    static var warmGameKeyForTesting: String? { warm?.id }

    private static func gameAllowed(_ request: GameOpenRequest) -> Bool {
        guard #available(iOS 17, *) else { return false }
        guard deviceAllowsGame() else { return false }
        guard !GamePresenter.isBusy else { return false }
        return GameAvailability.isEnabled(skinId: request.skinId, skinVersion: request.skinVersion)
    }

    private static func deviceAllowsGame() -> Bool {
        guard UIApplication.shared.applicationState != .background else { return false }
        let device = GameDeviceInfo.current(sdkVersion: DigiaSdkVersion.value)
        return SDKInstance.shared.gamePrewarm.allowsGame(tier: device.tier, ramMb: device.ramMb)
    }

    /// Thermal or low-power change: the device may have left tier `full`.
    private static func deviceTierChanged() {
        refreshEngine()
        if warm != nil, !deviceAllowsGame() { discard(reason: "tier_drop") }
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
                Task { @MainActor in
                    freeEngine(reason: "memory")
                    discard(reason: "memory")
                }
            },
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil, queue: .main) { _ in
                Task { @MainActor in
                    freeEngine(reason: "background")
                    discard(reason: "background")
                }
            },
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil, queue: .main) { _ in
                Task { @MainActor in refreshEngine() }
            },
            center.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil, queue: .main) { _ in
                Task { @MainActor in deviceTierChanged() }
            },
            center.addObserver(
                forName: .NSProcessInfoPowerStateDidChange,
                object: nil, queue: .main) { _ in
                Task { @MainActor in deviceTierChanged() }
            },
        ]
    }
}

/// Who asked for a warm game: an entry's impression, or a Direct trigger.
enum GamePrewarmSource: Equatable {
    case entry
    case direct
}

/// The pure decision core of the game prewarm: the single slot, the 3 s
/// offscreen grace and the 2 min idle limit.
enum GamePrewarmPolicy {
    static let offscreenGraceSeconds: TimeInterval = 3
    static let idleSeconds: TimeInterval = 120

    enum SlotDecision: Equatable {
        /// The slot is empty: warm.
        case warm
        /// This campaign is already warm from the same source.
        case keep
        /// A Direct game holds the slot; an entry does not take it.
        case skip
        /// Discard the warm game (`replaced`), then warm.
        case replace
    }

    static func slot(
        currentKey: String?, currentSource: GamePrewarmSource?,
        incomingKey: String, incomingSource: GamePrewarmSource
    ) -> SlotDecision {
        guard let currentKey, let currentSource else { return .warm }
        if currentSource == .direct, incomingSource == .entry { return .skip }
        if currentKey == incomingKey, currentSource == incomingSource { return .keep }
        return .replace
    }

    /// True once the slot has been off screen for more than the grace period.
    static func shouldDiscardOffscreen(hiddenSince: Date?, now: Date) -> Bool {
        guard let hiddenSince else { return false }
        return now.timeIntervalSince(hiddenSince) > offscreenGraceSeconds
    }

    /// True once a warm game has waited the idle limit without being used.
    static func isIdle(warmedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(warmedAt) >= idleSeconds
    }
}
