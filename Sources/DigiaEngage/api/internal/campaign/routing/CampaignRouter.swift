private let log = DigiaLogger()

/// Decides whether one campaign may start, then starts it.
///
/// The gates run in a fixed order — Template, Suppression, Screen, Config,
/// Frequency, Surface — and the first to drop wins, so a campaign that is wrong for this
/// screen never spends a frequency check and one the cap refuses never
/// displaces what is on screen. Where the drivers differ, ``SourcePolicy`` says
/// how; nothing here asks which driver it holds except the live-test path of
/// the surface gate.
@MainActor
struct CampaignRouter {
    /// Everything routing accepted that has not settled yet.
    let occupants: () -> [SurfaceOccupant]
    /// Takes an occupant off the screen and settles it `superseded`, given what
    /// replaced it.
    let supersede: (SurfaceOccupant, SurfaceKind, CampaignRequest) -> Void
    /// Starts the campaign once every gate has passed.
    let start: (CampaignRequest) -> RoutingVerdict
    let currentScreen: () -> String?
    /// Why the frequency policy refuses this campaign right now, nil if it allows it.
    let capReason: (CampaignModel) -> FrequencySkipReason?
    /// Whether the host asked overlays to stay off screen.
    var campaignsSuppressed: () -> Bool = { false }
    /// The dashboard id of the campaign stored under a key.
    var campaignId: (String) -> String? = { _ in nil }
    /// Reports the config's declared variables that have no value and no fallback.
    var reportMissing: (CampaignRequest) -> Void = { _ in }
    /// Config checks only this platform has, run last in the config gate.
    var configCheck: (CampaignRequest) -> RoutingVerdict? = { _ in nil }

    func route(_ request: CampaignRequest) -> RoutingVerdict {
        let gates: [(CampaignRequest) -> RoutingVerdict?] = [
            templateGate, suppressionGate, screenGate, configGate, frequencyGate, surfaceGate,
        ]
        for gate in gates {
            if let dropped = gate(request) { return dropped }
        }
        return start(request)
    }

    // CleverTap-specific: inline and floater come only by Native Display, never
    // by a `DigiaTemplate` in-app.
    private func templateGate(_ request: CampaignRequest) -> RoutingVerdict? {
        let type = request.campaign.campaignType
        guard type == "inline" || type == "floater",
            request.payload.cepMetadata["templateName"] == "DigiaTemplate"
        else { return nil }
        return request.invalidConfig(
            "\(type) campaign delivered as a CleverTap custom template", cause: "channel_mismatch")
    }

    // A host choice, not an SDK fault: no health extras. It runs before the cap
    // and surface checks, so a suppressed campaign never spends a cap.
    private func suppressionGate(_ request: CampaignRequest) -> RoutingVerdict? {
        guard campaignsSuppressed(), !request.campaign.isInline,
            request.campaign.surfaceArrival != nil
        else { return nil }
        let detail = "campaign overlays suppressed by host"
        log.d("Dropped — \(detail)", campaign: request.campaign.campaignKey)
        request.driver.policy.onDropped(DropReason.hostSuppressed, detail)
        return .dropped(reason: .hostSuppressed, detail: detail)
    }

    private func screenGate(_ request: CampaignRequest) -> RoutingVerdict? {
        let screen = currentScreen()
        guard !request.campaign.allowsScreen(screen) else { return nil }
        let key = request.campaign.campaignKey
        log.d(
            "Dropped — screen not targeted (current=\(screen ?? "<unset>"), "
                + "targets=\(request.campaign.targetScreenNames))",
            campaign: key)
        request.driver.policy.onDropped(DropReason.screenNotTargeted, "screen not targeted")
        return .dropped(
            reason: .screenNotTargeted,
            detail:
                "currentScreen=\(screen ?? "<unset>") targetScreenNames=\(request.campaign.targetScreenNames)",
            deliveryDetail: ["target_screens": Array(request.campaign.targetScreenNames.prefix(20))]
        )
    }

    private func configGate(_ request: CampaignRequest) -> RoutingVerdict? {
        reportMissing(request)
        switch request.campaign.config {
        case .inlineCanvas(let cfg):
            if let timer = cfg.statefulTimer,
               timer.resolve(schemas: request.campaign.variableSchemas, cepVars: request.payload.variables) == nil {
                return request.invalidConfig(
                    "timer time variable could not be resolved", cause: "timer_precondition")
            }
        case .survey(let cfg):
            if cfg.nodes.isEmpty || cfg.blocks.isEmpty {
                return request.invalidConfig("survey has no content", cause: "empty_content")
            }
        case .guide(let cfg):
            if cfg.steps.isEmpty {
                return request.invalidConfig("guide has no steps", cause: "empty_content")
            }
        default:
            break
        }
        return configCheck(request)
    }

    private func frequencyGate(_ request: CampaignRequest) -> RoutingVerdict? {
        guard request.driver.policy.respectsFrequencyCaps,
            request.campaign.campaignType != "inline",
            request.campaign.surfaceArrival != nil,
            let reason = capReason(request.campaign)
        else { return nil }
        log.d(
            "Dropped — frequency capped (rule=\(reason), "
                + "policy=\(String(describing: request.campaign.frequency)))",
            campaign: request.campaign.campaignKey)
        return .dropped(
            reason: .frequencyCapped, detail: nil,
            deliveryDetail: Self.frequencyCapDetail(reason, policy: request.campaign.frequency))
    }

    /// Which rule of `policy` capped the campaign.
    static func frequencyCapDetail(_ cap: FrequencySkipReason, policy: FrequencyPolicy?) -> [String: Any] {
        var detail: [String: Any] = [:]
        switch cap {
        case .maxTotal:
            detail["cap_rule"] = "max_total"
            if let limit = policy?.maxTotal { detail["cap_limit"] = limit }
        case .window:
            detail["cap_rule"] = "window"
            if let window = policy?.maxPerWindow {
                detail["cap_window"] = window.window
                detail["cap_limit"] = window.count
            }
        case .stopped:
            detail["cap_rule"] = "stopped"
        }
        return detail
    }

    /// A `surface_busy` drop's delivery detail naming `blocker`. A live-test
    /// blocker is a draft and is never named.
    static func surfaceBusyDetail(_ blocker: SurfaceOccupant, campaignId: String?) -> [String: Any] {
        if blocker.isLiveTest {
            return ["blocking_kind": blocker.kind.wire, "blocking_live_test": true]
        }
        var detail: [String: Any] = [
            "blocking_campaign_key": blocker.campaignKey,
            "blocking_kind": blocker.kind.wire,
            "blocking_displayed": blocker.hasDisplayed,
        ]
        if let campaignId { detail["blocking_campaign_id"] = campaignId }
        return detail
    }

    private func surfaceGate(_ request: CampaignRequest) -> RoutingVerdict? {
        guard let arrival = request.campaign.surfaceArrival else { return nil }
        let key = request.campaign.campaignKey
        let current = occupants()
        // A live test always shows: it supersedes whatever would have blocked it.
        if request.driver.kind == .liveTest {
            for occupant in SurfaceRule.liveTestDisplaced(arrival, occupants: current) {
                log.d("Live test displaces \(occupant.kind.wire) '\(occupant.campaignKey)'", campaign: key)
                supersede(occupant, arrival, request)
            }
            return nil
        }
        switch SurfaceRule.decide(arrival, occupants: current, priority: request.campaign.rulePriority) {
        case .show:
            return nil
        case .replace(let occupant):
            log.d("Superseded — slot was never displayed", campaign: occupant.campaignKey)
            supersede(occupant, arrival, request)
            return nil
        case .busy(let blocker):
            if case .inline = arrival, blocker.campaignKey == key {
                // A CEP redelivering the campaign its slot already holds: keep
                // what is shown and drop quietly. No blocker extras, so
                // HealthSink never reports "X blocked by X".
                let detail = "same campaign already in slot"
                log.d("Dropped — surface busy, \(detail)", campaign: key)
                request.driver.policy.onDropped(DropReason.surfaceBusy, detail)
                // The detail still names the blocker: it is the campaign itself.
                return .dropped(
                    reason: .surfaceBusy, detail: detail,
                    deliveryDetail: Self.surfaceBusyDetail(blocker, campaignId: campaignId(blocker.campaignKey)))
            }
            let detail = "\(blocker.kind.wire) on screen"
            log.d("Dropped — surface busy, \(detail) (blocking=\(blocker.campaignKey))", campaign: key)
            request.driver.policy.onDropped(DropReason.surfaceBusy, detail)
            // A live-test blocker is a PM testing, and a blocker never
            // displayed is nothing a customer saw: no blocker extras, so
            // HealthSink never reports it. The timeline still records the drop.
            let extras =
                blocker.isLiveTest || !blocker.hasDisplayed
                ? [:]
                : HealthReasons.surfaceBusyExtras(
                    blockingCampaignKey: blocker.campaignKey,
                    blockingKind: blocker.kind.wire,
                    blockerIsLiveTest: false)
            return .dropped(
                reason: .surfaceBusy, detail: detail, extras: extras,
                deliveryDetail: Self.surfaceBusyDetail(blocker, campaignId: campaignId(blocker.campaignKey)))
        }
    }
}
