import Foundation
import UIKit

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

// Digia-decided campaigns. A campaign carrying a `rule` belongs to Digia: the
// engine evaluates it on each signal and routes the winner through the same
// gates a CEP-triggered campaign passes. A campaign with no rule belongs to
// the CEP, which calls in through `deliver` when it decides.

/// What the ``DecisionEngine`` reads from the SDK when it decides.
@MainActor
private final class EngineFacts: DecisionFacts {
    private unowned let sdk: SDKInstance

    init(_ sdk: SDKInstance) { self.sdk = sdk }

    var ready: Bool { sdk.sdkState == .ready && sdk.services != nil }

    func listeningTo(_ signal: RuleSignal) -> [CampaignModel] {
        sdk.campaignStore.listeningTo(signal)
    }

    func find(_ campaignKey: String) -> CampaignModel? { sdk.campaignStore.find(campaignKey) }

    var attributes: [String: Any] { sdk.services?.userContextManager.resolvedValues ?? [:] }

    var device: [String: Any] { sdk.deviceSnapshot() }

    func inAudience(_ campaign: CampaignModel) -> Bool {
        campaign.allowsUser(sdk.services?.userContextManager.eligibleCampaigns ?? [])
    }

    func capped(_ campaign: CampaignModel) -> Bool {
        sdk.services?.frequencyManager.blockReason(
            campaignKey: campaign.campaignKey, policy: campaign.frequency) != nil
    }

    var currentScreen: String { sdk.currentScreenForAnchorless ?? "" }

    func slotCampaignKey(_ slot: String) -> String? {
        sdk.inlineController.getCampaign(slot)?.campaignKey
    }

    var audienceContext: String { sdk.services?.userContextManager.contextState ?? "missing" }
}

/// The prefix that marks a `cepCampaignId` as built by the SDK for a campaign
/// it fired itself, never by a real CEP plugin.
let selfTriggeredCepIdPrefix = "digia_trigger:"

/// The synthetic `cepCampaignId` for one firing of `campaignId`.
///
/// Distinct per firing, not per campaign, because a CEP's own id is: the whole
/// lifecycle downstream — impression dedup, dwell tracking, dismissal — keys
/// off this id, so reusing one across firings would make the second showing of
/// a campaign report no impression at all.
func selfTriggeredCepId(_ campaignId: String, firing: Int) -> String {
    "\(selfTriggeredCepIdPrefix)\(campaignId)#\(firing)"
}

extension SDKInstance {
    func makeDecisionEngine() -> DecisionEngine {
        DecisionEngine(
            facts: EngineFacts(self),
            route: { [weak self] campaign, firedBy, signal in
                self?.routeSelfTriggered(campaign, firedBy: firedBy, signal: signal)
            },
            nowMs: { [weak self] in self?.waitClock() ?? MonotonicClock.nowMs() }
        )
    }

    // MARK: Routing

    /// Routes one campaign the SDK fired itself, standing in for the payload a
    /// CEP would otherwise have supplied. It never touches a CEP plugin: the
    /// coordinator owner is `digia`, so its lifecycle events settle the
    /// presentation and reach no plugin.
    ///
    /// `signal` is the signal that fired the campaign — the event that matched
    /// an OR trigger, or the event a wait started from. Its properties feed the
    /// campaign's `{{ event.<key> }}` tokens; a non-event signal leaves the
    /// event scope empty, so those tokens use their fallback.
    private func routeSelfTriggered(_ campaign: CampaignModel, firedBy: String, signal: RuleSignal) {
        // No CEP hands us per-firing values, so the campaign interpolates what
        // is known about this user — imported attributes and whatever the app
        // set — over its dashboard defaults, plus the `user.` / `event.`
        // context variables it declares. Only DMC campaigns declare any.
        let driver = DigiaDriver()
        let userAttributes = services?.userContextManager.resolvedAttributes ?? [:]
        var eventProperties: [String: Any] = [:]
        if case .event(_, let properties) = signal { eventProperties = properties }
        selfTriggerCount += 1
        let payload = CEPTriggerPayload(
            cepCampaignId: selfTriggeredCepId(campaign.id, firing: selfTriggerCount),
            campaignKey: campaign.campaignKey,
            cepMetadata: [:],
            variables: userAttributes.merging(
                bindContextVariables(
                    campaign.variableSchemas,
                    userAttributes: userAttributes,
                    eventProperties: eventProperties
                )
            ) { _, bound in bound }
        )
        let controller = coordinator.open(payload, owner: driver.owner)
        observeDelivery(controller, firedBy: firedBy)
        routeOrDrop(controller, driver: driver)
    }

    /// The `device` values rules read. `os_version` is the bare version, or nil.
    func deviceSnapshot() -> [String: Any] {
        let context = services?.staticContext ?? [:]
        var snapshot: [String: Any] = [:]
        snapshot["platform"] = context["device_platform"]
        if let os = context["os_version"] as? String,
           let range = os.range(of: #"^(?:Android|iOS|Version) (\d+(?:\.\d+)*)"#, options: .regularExpression)
        {
            snapshot["os_version"] = os[range].split(separator: " ", maxSplits: 1).last.map(String.init)
        }
        snapshot["app_version"] = context["app_version"]
        snapshot["sdk_version"] = DigiaSdkVersion.value
        snapshot["locale"] = Locale.preferredLanguages.first
        snapshot["app_opens"] = appOpens.value
        return snapshot
    }

    // MARK: Startup

    /// Reads whether the process launched in the background, then notes the open.
    func beginAppOpen() {
        if launchedInBackground() {
            inBackground = true
            engine.pause()
            dwellTracker.pause()
        }
        noteAppOpened()
    }

    /// `app_opened` fires at once in the foreground, or on the first return to it.
    func noteAppOpened() {
        if inBackground {
            appOpenedDue = true
        } else {
            sendAppOpened()
        }
    }

    /// Counted first, so the signal's own evaluation sees this open.
    private func sendAppOpened() {
        appOpens.countOpen()
        engine.send(.appOpened)
    }

    /// Applies the bundle's app-event policy, loads the user context, and only
    /// then lets held signals through: no rule sees an empty context.
    func openDecisionEngine(policy: AppEventUploadPolicy, generation: Int) async {
        guard let services, initGeneration == generation else { return }
        services.appEventsService?.applyPolicy(policy)
        let manager = services.userContextManager
        manager.configure(restoredUserId: services.identityManager.userId)
        await manager.refresh()
        guard self.services === services, initGeneration == generation else { return }
        engine.ready()
    }

    // MARK: Lifecycle

    func appDidEnterBackground() {
        engine.pause()
        inBackground = true
        // Held signals are of the app that was on screen.
        if !engine.isReady { engine.dropHeld() }
    }

    func appWillEnterForeground() {
        // Waits keep counting in the background but end only on screen. The
        // clock keeps counting through sleep, so the return reads it directly.
        let wasBackground = inBackground
        inBackground = false
        engine.resume()
        guard wasBackground else { return }
        if appOpenedDue {
            appOpenedDue = false
            sendAppOpened()
        } else {
            engine.send(.appForegrounded)
        }
        if let manager = services?.userContextManager, manager.needsRefresh {
            Task { @MainActor in await manager.refresh() }
        }
    }

    /// A new session starts clean: no wait or visibility carries over.
    func sessionDidRotate() {
        // Rotation can fire from any thread; the engine lives on the main actor.
        if Thread.isMainThread {
            MainActor.assumeIsolated { endSession() }
        } else {
            Task { @MainActor [weak self] in self?.endSession() }
        }
    }

    private func endSession() {
        visibleSent.removeAll()
        engine.reset()
    }

    /// Sends an anchor or slot signal once per session, after the frame that
    /// mounted it, so routing sees the finished layout.
    func sendVisibleOnce(_ id: String, _ signal: RuleSignal) {
        guard visibleSent.insert(id).inserted else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.engine.send(signal) }
        }
    }

    // MARK: Identity

    /// The one path a user change takes, buffered or not. `nil` clears.
    func applyUserId(_ services: SDKServices, _ userId: String?, refreshContext: Bool = true) {
        let identity = services.identityManager
        let trimmed = userId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed?.isEmpty == true { return }
        services.userContextManager.dropPreviousUser(trimmed)
        if trimmed != identity.userId { clearDigiaInlineContent() }
        if let trimmed {
            identity.setUserId(trimmed)
        } else {
            identity.clearUserId()
        }
        guard refreshContext else { return }
        let current = identity.userId
        // A set that identity refused leaves nothing to tell the context.
        if trimmed != nil, current == nil { return }
        let manager = services.userContextManager
        Task { @MainActor in await manager.onUserIdChanged(current) }
    }

    /// Clears the inline content Digia decided for the user who is leaving, so
    /// it does not stay for the next one. A CEP's inline content is left alone.
    private func clearDigiaInlineContent() {
        for (slot, payload) in inlineController.slotOccupants
        where payload.cepCampaignId.hasPrefix(selfTriggeredCepIdPrefix) {
            inlineController.dismissCampaign(slot, reason: .superseded)
        }
    }

    // MARK: Host API

    /// Supplies attributes about the current user, for campaigns to interpolate.
    /// Calls merge. Requires `setUserId`; attributes describe an identified user.
    func setUserAttributes(_ attributes: [String: Any]) async {
        guard let services else {
            log.e("setUserAttributes() ignored — called before initialize()")
            return
        }
        await services.userContextManager.setUserAttributes(attributes)
    }

    /// Records an event the app performed, such as a purchase.
    ///
    /// Queued and sent in batches alongside campaign analytics; never blocks.
    /// The name and `properties` are also evaluated against Digia-owned rules.
    func trackEvent(_ eventName: String, properties: [String: Any] = [:]) {
        guard let services else {
            log.e("trackEvent() ignored — called before initialize()")
            return
        }
        log.d("trackEvent (name=\(eventName), properties=\(properties.keys.sorted().joined(separator: ",")))")
        // An invalid call is not a signal: nothing is queued and no rule is
        // evaluated. Names are trimmed, as the server does, so both validate
        // the same name.
        let name = eventName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidAppEventName(name) else {
            log.w(
                "trackEvent dropped — invalid app event name",
                stage: .session,
                reason: TimelineReason.appEventInvalid,
                extras: ["event_name": String(name.prefix(appEventNameMaxLength))]
            )
            return
        }
        let cleaned = cleanAppEventProperties(properties)
        if !cleaned.dropped.isEmpty {
            // The event is kept; only the values the backend can't store go.
            log.w(
                "trackEvent(\(name)) dropped values that are not a string, "
                    + "number, boolean or list of those: \(cleaned.dropped.joined(separator: ", "))",
                stage: .session,
                reason: TimelineReason.appEventInvalid,
                extras: ["event_name": name]
            )
        }
        let signal = RuleSignal.event(name, cleaned.properties)
        // Before the enqueue, so a wait cannot end while this event is in
        // flight, even when the bus queues the signal behind one being handled.
        engine.cancelWaits(signal)
        // Queued first, so the event precedes anything a rule emits.
        services.appEventsService?.track(name, properties: cleaned.properties)
        engine.send(signal)
    }

    /// Resets what DMC keeps, for tests.
    func resetDecisionStateForTesting() {
        engine.close()
        engine.reset()
        engine.resume()
        inBackground = false
        appOpenedDue = false
        appOpens = AppOpensCounter()
        visibleSent.removeAll()
        selfTriggerCount = 0
    }
}
