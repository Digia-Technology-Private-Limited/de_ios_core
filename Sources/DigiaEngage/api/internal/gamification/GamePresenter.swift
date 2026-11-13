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

    /// Set when `ready` arrives; the game is presented only after this.
    private(set) var isReady = false

    private var didFinish = false
    private let haptics: GameHaptics
    /// The delivered reward's deep link, opened on `useReward`; never sent to the skin.
    private var rewardLink: URL?

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
        var payload = GameInitPayload(
            safeArea: safeArea,
            locale: GameInitPayload.deviceLocale,
            showMute: request.showMute
        )
        payload.extra["values"] = request.values.mapValues(Self.jsonObject)
        payload.extra["sensors"] = request.sensors
        if !request.slots.isEmpty {
            payload.extra["slots"] = request.slots.map {
                ["outcomeKey": $0.outcomeKey, "values": $0.values] as [String: Any]
            }
        }
        self.initPayload = payload
        self.haptics = GameHaptics(sensors: Set(request.sensors))
        bridge.onUnhandled = { [weak self] type, object in self?.handleSkinMessage(type, object) }
        bridge.onReady = { [weak self] in self?.didBecomeReady() }
        bridge.onClosed = { [weak self] in self?.didClose() }
        bridge.onFailed = { [weak self] reason in self?.didFail(reason) }
    }

    /// The web view's owner, created once in `preload()` and reused by the
    /// container once the game is shown.
    private(set) var webCoordinator: GameWebCoordinator?

    /// Loads the skin before anything is shown. The web view sits in the key
    /// window fully transparent and ignoring touches, so the host app stays
    /// usable; `ready` presents the game, and a missing `ready` closes it
    /// silently on the bridge's 5 s timer.
    func preload() {
        let coordinator = GameWebCoordinator(game: self, entryURL: entryURL, bundleRoot: bundleRoot)
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

    /// Sends `init` after the page loads, and again after `playNext`. Each
    /// `init` fully resets the skin.
    func sendInit() {
        guard let script = bridge.script(for: initPayload.message()) else { return }
        webCoordinator?.view.evaluateJavaScript(script, completionHandler: nil)
    }

    private static func jsonObject(_ value: JSONValue) -> Any {
        switch value {
        case .string(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .array(let v): return v.map(jsonObject)
        case .object(let v): return v.mapValues(jsonObject)
        case .null: return NSNull()
        }
    }

    /// Skin messages the bridge leaves to us: a play request, haptics, `useReward` and `playNext`.
    private func handleSkinMessage(_ type: String, _ object: [String: Any]) {
        switch type {
        case "playRequested":
            startPlay()
        case "haptic":
            if let style = GameHapticStyle(rawValue: object["style"] as? String ?? "") {
                haptics.play(style)
            }
        case "useReward":
            guard let link = rewardLink else { return }
            UIApplication.shared.open(link)
            dismiss()
        case "playNext":
            // Same web view, fresh `init`; the next `playRequested` spends `nextChance`.
            guard bridge.playNext() else { return }
            rewardLink = nil
            sendInit()
        default:
            break
        }
    }

    /// One play per `idle` skin: calls the backend with a fresh play id and
    /// hands the skin its `outcome` or `refused`.
    private func startPlay() {
        guard bridge.beginPlay() else { return }
        request.onPlayCommitted?()
        let playId = UUID().uuidString
        let play = request.play
        Task { @MainActor [weak self] in
            let result = await play?(playId) ?? .refused(.unavailable)
            self?.deliver(result)
        }
    }

    private func deliver(_ result: PlayResult) {
        guard bridge.finishPlay(),
              let script = bridge.script(
                  for: Self.playResultMessage(
                      result, slots: request.slots, rewardCtaTexts: request.rewardCtaTexts))
        else { return }
        rewardLink = Self.rewardDeepLink(result)
        webCoordinator?.view.evaluateJavaScript(script, completionHandler: nil)
    }

    /// The grant's deep link (top level or under `cta`), when it parses as a URL.
    static func rewardDeepLink(_ result: PlayResult) -> URL? {
        guard case .outcome(let outcome) = result, outcome.kind == .reward,
              let grant = outcome.grant else { return nil }
        var cta: [String: JSONValue] = [:]
        if case .object(let nested)? = grant["cta"] { cta = nested }
        for object in [grant, cta] {
            if case .string(let value)? = object["deepLink"],
               let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
               url.scheme != nil {
                return url
            }
        }
        return nil
    }

    /// The `outcome` / `refused` message for one play result. `slotIndex` is
    /// random among the slots matching `outcomeKey` and omitted when none do.
    /// `busy` and unknown refusals read as `unavailable`; a failure does too.
    static func playResultMessage(
        _ result: PlayResult, slots: [GamificationSlotConfig],
        rewardCtaTexts: [String: String] = [:]
    ) -> [String: Any] {
        switch result {
        case .outcome(let outcome):
            var message: [String: Any] = [
                "type": "outcome",
                "outcomeKey": outcome.outcomeKey,
                "kind": outcome.kind.rawValue,
                "hasNextChance": outcome.nextChance != nil,
            ]
            let matches = slots.indices.filter { slots[$0].outcomeKey == outcome.outcomeKey }
            if let index = matches.randomElement() { message["slotIndex"] = index }
            if outcome.kind == .reward {
                message["reward"] = rewardObject(outcome, rewardCtaTexts: rewardCtaTexts)
            }
            return message
        case .refused(let refusal):
            let reason = refusal == .busy ? GamificationPlayRefusal.unavailable : refusal
            return ["type": "refused", "reason": reason.rawValue]
        case .failure:
            return ["type": "refused", "reason": GamificationPlayRefusal.unavailable.rawValue]
        }
    }

    /// The skin-facing `reward` object, built from the play's `grant`. The skin
    /// never sees the deep link, only whether one exists (`useReward` opens it).
    /// `ctaText` comes from `templateConfig.rewards`, matched by `grant.rewardId`;
    /// omitted when there is no match so the skin shows "Use now".
    static func rewardObject(
        _ outcome: PlayOutcome, rewardCtaTexts: [String: String]
    ) -> [String: Any] {
        let grant = outcome.grant ?? [:]
        func text(_ key: String, in object: [String: JSONValue] = grant) -> String? {
            guard case .string(let value)? = object[key] else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        var cta: [String: JSONValue] = [:]
        if case .object(let nested)? = grant["cta"] { cta = nested }

        let type = outcome.rewardType ?? .perk
        var reward: [String: Any] = [
            "type": type.rawValue,
            "name": text("name") ?? text("displayText") ?? outcome.outcomeKey,
        ]
        if let imageUrl = text("imageUrl"), imageUrl.lowercased().hasPrefix("https://") {
            reward["imageUrl"] = imageUrl
        }
        switch type {
        case .coupon:
            if let code = text("code") { reward["code"] = code }
        case .currency:
            if let valueText = text("valueText") {
                reward["valueText"] = valueText
            } else if let unit = text("unit") {
                switch grant["amount"] {
                case .int(let amount)?: reward["valueText"] = "\(amount) \(unit)"
                case .double(let amount)?: reward["valueText"] = "\(amount) \(unit)"
                default: break
                }
            }
        case .perk, .unknown:
            if let perkText = text("perkText") ?? text("displayText") { reward["perkText"] = perkText }
        }
        if let expiresAt = text("expiresAt") { reward["expiresAt"] = expiresAt }
        reward["hasDeepLink"] = rewardDeepLink(.outcome(outcome)) != nil
        if let ctaText = text("rewardId").flatMap({ rewardCtaTexts[$0] }) ?? text("label", in: cta) {
            reward["ctaText"] = ctaText
        }
        return reward
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
        guard !didFinish, !isReady else { return }
        isReady = true
        // Hand the loaded web view to the container; it is never reloaded.
        webCoordinator?.view.removeFromSuperview()
        webCoordinator?.view.alpha = 1
        webCoordinator?.view.isUserInteractionEnabled = true
        GamePresenter.loading = nil
        SDKInstance.shared.controller.showGame(self)
        request.onShown?()
    }

    /// Ends the session on every path. A game that never became visible has no
    /// container to tear the web view down, so it is torn down here.
    private func finish() {
        didFinish = true
        if GamePresenter.loading === self { GamePresenter.loading = nil }
        if !isReady {
            webCoordinator?.view.removeFromSuperview()
            webCoordinator?.teardown()
        }
        SDKInstance.shared.controller.dismissGame()
    }

    private func didClose() {
        guard !didFinish else { return }
        finish()
        request.onClose?()
    }

    private func didFail(_ reason: GameFailure) {
        finishAsFailure(reason)
    }

    private func finishAsFailure(_ reason: GameFailure) {
        guard !didFinish else { return }
        log.w("Game closed", error: reason.rawValue)
        finish()
        request.onFailure?(reason)
    }
}

/// The one internal entry point routing calls to open a game. T2's
/// `grantChance` hook calls `open(_:)` on `granted && show`; teardown and the
/// skin `close` funnel back through `dismiss()`.
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
        let safeArea = GameSafeArea.fullScreen(system: activeWindowSafeAreaInsets)
        guard let presentation = GamePresentation(request: request, safeArea: safeArea) else {
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
