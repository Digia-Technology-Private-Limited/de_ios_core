import Foundation

private let log = DigiaLogger()

/// The one decision point for every gamification chance request. PlaySession
/// never opens games, renders entries, hides entries, logs analytics or
/// touches live tests — it only decides. `SDKInstance` maps the decision to
/// side effects.
///
/// Every entry kind asks for the chance on the trigger (`direct == true` for
/// a direct routing, `false` for an inline or floating one). A tap never
/// calls `grantChance`: it opens the game with the stored chance.
@MainActor
final class PlaySession {
    private let source: any GameOutcomeSource
    private let identity: () -> PlayIdentity?
    /// One request in flight per campaign: a second trigger for a campaign
    /// whose grant is still in flight drops `busy` at once.
    private var inFlightCampaigns = Set<String>()
    /// Only one direct game can show, so only one direct grant runs at a time
    /// across campaigns: two direct triggers would otherwise both spend a chance.
    /// Matches Android's `PlaySession.directInFlight`.
    private var directInFlight = false

    init(source: any GameOutcomeSource, identity: @escaping () -> PlayIdentity?) {
        self.source = source
        self.identity = identity
    }

    /// The one admission gate before the grant. A game on screen blocks only
    /// a direct trigger — an inline or floating trigger only renders a
    /// teaser, so it still asks. Only one direct grant runs at a time across
    /// campaigns: two direct triggers would otherwise both spend a chance.
    /// One request runs at a time per campaign: a second trigger for a
    /// campaign whose grant is still in flight drops `busy` at once. Admitting
    /// reserves the campaign (and direct) slots; `request` releases them when
    /// the grant settles. Returns the busy drop reason when the request must
    /// not ask, else nil. Matches Android's `PlaySession` admission.
    func admit(_ request: PlayRequest) -> String? {
        if request.direct, request.isGameBusy() {
            return PlayDropReason.busy
        }
        if request.direct, directInFlight {
            return PlayDropReason.busy
        }
        guard !inFlightCampaigns.contains(request.campaignKey) else {
            return PlayDropReason.busy
        }
        inFlightCampaigns.insert(request.campaignKey)
        if request.direct { directInFlight = true }
        return nil
    }

    private func release(_ request: PlayRequest) {
        inFlightCampaigns.remove(request.campaignKey)
        if request.direct { directInFlight = false }
    }

    func request(_ request: PlayRequest) async -> PlayDecision {
        if let busy = admit(request) {
            return .drop(reason: busy, denyReason: nil)
        }
        defer { release(request) }
        // The identity is read once: the check and the grant below see the same user.
        guard let identity = identity(),
              !identity.userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.triggerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .drop(reason: PlayDropReason.missingConfig, denyReason: nil)
        }
        let grant = GrantChanceRequest(
            campaignKey: request.campaignKey,
            userId: identity.userId,
            userHash: identity.userHash,
            triggerId: request.triggerId,
            testInvocationId: request.testInvocationId,
            deviceId: request.testInvocationId != nil ? identity.deviceId : nil
        )
        switch await source.grantChance(grant) {
        case .granted(let chance):
            // `show` only gates a direct open. An inline or floating entry
            // renders whenever the chance is granted: the server saves the
            // chance either way, so hiding the entry would strand it.
            if !request.direct {
                return .showEntry(chance)
            }
            if chance.show {
                return .open(chance)
            }
            return .drop(reason: PlayDropReason.notShown, denyReason: nil, events: chance.events)
        case .denied(let reason, let events):
            if reason == "notVerified" {
                log.w(
                    "Gamification chance not granted (denyReason=notVerified) — user verification is on and the userHash is missing or invalid",
                    campaign: request.campaignKey,
                    stage: .trigger
                )
            } else {
                log.d(
                    "Gamification chance not granted (denyReason=\(reason ?? "unknown"))",
                    campaign: request.campaignKey
                )
            }
            return .drop(reason: PlayDropReason.denied, denyReason: reason, events: events)
        case .failure(let error):
            switch error {
            case .transport(_, let timedOut):
                // A grant timeout reads `timeout`, like the close-time `state`
                // leg; any other transport failure reads `network`. Matches
                // Android's `PlaySession` (`FAIL_TIMEOUT`).
                return .drop(
                    reason: timedOut ? PlayDropReason.timeout : PlayDropReason.network,
                    denyReason: nil)
            case .httpStatus:
                return .drop(reason: PlayDropReason.network, denyReason: nil)
            case .invalidResponse:
                return .drop(reason: PlayDropReason.invalidResponse, denyReason: nil)
            }
        }
    }

    /// The trigger id sent with the chance request: the delivering
    /// presentation's id, so every trigger asks for its own chance. Without one
    /// (a live test) it falls back to `cepCampaignId`, which is the same for
    /// every trigger of a campaign. Empty means there is none. Matches
    /// Android's `PlaySession.triggerIdOrNull`.
    nonisolated static func triggerId(of payload: CEPTriggerPayload) -> String {
        if let id = payload.presentationId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return id
        }
        return payload.cepCampaignId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The drop reason a refused chance settles as. Only the two denials that
    /// really are a cap (`capReached`, `alreadyPlayed`) read as
    /// `frequency_capped`; every other backend `denyReason` names what
    /// happened, and an unknown or missing one is `.notEligible`, never a cap.
    /// Spellings are the backend's `DenyReason`.
    nonisolated static func dropReason(forDenyReason denyReason: String?) -> DropReason {
        switch denyReason {
        case "capReached", "alreadyPlayed": return .frequencyCapped
        case "notVerified": return .userNotVerified
        case "notLive": return .campaignNotLive
        case "notInAudience": return .notInAudience
        case "budgetUsed": return .budgetExhausted
        case "chanceExpired": return .chanceExpired
        default: return .notEligible
        }
    }

    /// The tap decision: a shown entry opens with its stored chance, unless a
    /// game is already visible. A live-test tap is not busy — the open
    /// replaces the visible game (`GamePresenter.replace`), as every new test
    /// send does. Pure, so both platforms share it exactly.
    nonisolated static func decideTap(
        gameVisible: Bool, isLiveTest: Bool = false, chance: GrantedChance?
    ) -> TapDecision {
        if gameVisible && !isLiveTest {
            return .fail(reason: PlayDropReason.busy)
        }
        guard let chance else {
            return .fail(reason: PlayDropReason.missingConfig)
        }
        return .open(chance)
    }

    /// The after-close decision from the `state` answer about the entry's own
    /// chance. `playable` keeps the entry with that chance; a failed call
    /// keeps it with the stored one, so a network blip never dismisses it;
    /// anything else, `played` included, hides it: once played, a floater
    /// comes down on its own. Pure, so both platforms share it exactly.
    nonisolated static func decideAfterClose(_ state: ChanceStateResult) -> CloseDecision {
        switch state {
        case .playable(let chanceId, let expiresAt):
            return .keep(GrantedChance(chanceId: chanceId, expiresAt: expiresAt, show: true))
        case .failed:
            return .keep(nil)
        case .played, .expired, .none, .refused:
            return .hide
        }
    }
}

/// Who the chance is asked for. A snapshot read once per request.
struct PlayIdentity: Equatable, Sendable {
    let userId: String
    let userHash: String?
    let deviceId: String?
}

/// One chance request. `direct` is true for a direct routing, false for an
/// inline or floating trigger. `triggerId` arrives trimmed; `isGameBusy`
/// reports whether a game is loading or on screen (`GamePresenter.isBusy`).
struct PlayRequest {
    let campaignKey: String
    let triggerId: String
    let testInvocationId: String?
    let direct: Bool
    let isGameBusy: () -> Bool
}

/// What a `PlaySession.request` decided.
enum PlayDecision: Equatable, Sendable {
    /// Inline / floating trigger, granted with `show`: store the chance and
    /// render the entry.
    case showEntry(GrantedChance)
    /// Direct trigger, granted with `show`: open the game now.
    case open(GrantedChance)
    /// Anything else: log, report the live test, emit `game_open_failed`,
    /// and settle the presentation as dropped. `events` are the chance events
    /// a granted-but-not-shown or denied answer's facts call for.
    case drop(reason: String, denyReason: String?, events: [ChanceEvent] = [])
}

/// What a tap on a shown entry decided. No network call.
enum TapDecision: Equatable, Sendable {
    /// Open the game with the stored chance.
    case open(GrantedChance)
    /// The tap failed: `busy` (a game is visible) or `missing_config` (no
    /// stored chance). Emits `game_open_failed`; the entry's presentation
    /// stays live.
    case fail(reason: String)
}

/// What closing a game opened from a floating entry decided.
enum CloseDecision: Equatable, Sendable {
    /// Keep the floater. A non-nil replacement replaces the stored chance (a
    /// fresh `playable` answer); nil keeps the stored one (a failed call).
    case keep(GrantedChance?)
    /// Dismiss the floater and forget its spent chance; a later trigger can show it again.
    case hide
}

/// The `PlayDecision.drop` and `TapDecision.fail` reason strings. Exact on
/// both platforms.
enum PlayDropReason {
    /// GrantChance denied; the server reason rides in `denyReason` (may be nil).
    static let denied = "denied"
    /// A direct trigger granted without `show`: the game does not open.
    static let notShown = "not_shown"
    /// A game is showing, another request for the campaign is in flight, or (direct) another direct grant is in flight.
    static let busy = "busy"
    /// Blank trigger id, or no identity / blank user id.
    static let missingConfig = "missing_config"
    /// Transport timeout, kept distinct like the close-time `state` leg.
    /// Matches Android's `PlaySession.FAIL_TIMEOUT`.
    static let timeout = "timeout"
    /// Transport failure, non-2xx HTTP status, or no network client.
    static let network = "network"
    /// The response did not parse / violated the strict schema.
    static let invalidResponse = "invalid_response"
}
