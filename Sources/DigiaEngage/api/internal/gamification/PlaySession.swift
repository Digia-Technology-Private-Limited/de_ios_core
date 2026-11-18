import Foundation

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

    init(source: any GameOutcomeSource, identity: @escaping () -> PlayIdentity?) {
        self.source = source
        self.identity = identity
    }

    func request(_ request: PlayRequest) async -> PlayDecision {
        // A game on screen only blocks a direct trigger. An inline or
        // floating trigger only renders a teaser, so it still asks.
        if request.direct, request.isGameBusy() {
            return .drop(reason: PlayDropReason.busy, denyReason: nil)
        }
        guard !inFlightCampaigns.contains(request.campaignKey) else {
            return .drop(reason: PlayDropReason.busy, denyReason: nil)
        }
        inFlightCampaigns.insert(request.campaignKey)
        defer { inFlightCampaigns.remove(request.campaignKey) }
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
            showNow: true,
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
            return .drop(reason: PlayDropReason.notShown, denyReason: nil)
        case .denied(let reason):
            return .drop(reason: PlayDropReason.denied, denyReason: reason)
        case .failure(let error):
            switch error {
            case .transport, .httpStatus:
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

    /// The tap decision: a shown entry opens with its stored chance, unless a
    /// game is already visible. Pure, so both platforms share it exactly.
    nonisolated static func decideTap(gameVisible: Bool, chance: GrantedChance?) -> TapDecision {
        if gameVisible {
            return .fail(reason: PlayDropReason.busy)
        }
        guard let chance else {
            return .fail(reason: PlayDropReason.missingConfig)
        }
        return .open(chance)
    }

    /// The after-close decision for a game opened from a floating entry.
    /// `playable` keeps the floater with the new chance, a failed call keeps
    /// it with the stored one, and anything else hides it. Pure, so both
    /// platforms share it exactly.
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
    /// and settle the presentation as dropped.
    case drop(reason: String, denyReason: String?)
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
    /// Hide the floater for the rest of the session.
    case hide
}

/// The `PlayDecision.drop` and `TapDecision.fail` reason strings. Exact on
/// both platforms.
enum PlayDropReason {
    /// GrantChance denied; the server reason rides in `denyReason` (may be nil).
    static let denied = "denied"
    /// A direct trigger granted without `show`: the game does not open.
    static let notShown = "not_shown"
    /// A game is showing, or another request for the campaign is in flight.
    static let busy = "busy"
    /// Blank trigger id, or no identity / blank user id.
    static let missingConfig = "missing_config"
    /// Transport failure, non-2xx HTTP status, or no network client.
    static let network = "network"
    /// The response did not parse / violated the strict schema.
    static let invalidResponse = "invalid_response"
}
