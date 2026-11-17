import Foundation

/// The one decision point for every gamification chance request. PlaySession
/// never opens games, hides entries, logs analytics or touches live tests —
/// it only decides. `SDKInstance` maps the decision to side effects.
@MainActor
final class PlaySession {
    /// Backend `grantChance` deny reasons for a repeated trigger whose chance
    /// can never open again: `alreadyPlayed` (chain played, or next chance
    /// expired unplayed) and `chanceExpired` (the unplayed chance expired).
    /// Both hide the entry.
    static let hideEntryDenyReasons: Set<String> = ["alreadyPlayed", "chanceExpired"]

    private let source: any GameOutcomeSource
    private let identity: () -> PlayIdentity?
    /// One request in flight at a time: a second one fails `busy` at once.
    private var requestInFlight = false

    init(source: any GameOutcomeSource, identity: @escaping () -> PlayIdentity?) {
        self.source = source
        self.identity = identity
    }

    func request(_ request: PlayRequest) async -> PlayDecision {
        if request.isGameBusy() {
            return .fail(reason: PlayFailReason.busy, denyReason: nil)
        }
        guard !requestInFlight else {
            return .fail(reason: PlayFailReason.busy, denyReason: nil)
        }
        requestInFlight = true
        defer { requestInFlight = false }
        // The identity is read once: the check and the grant below see the same user.
        guard let identity = identity(),
              !identity.userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.triggerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .fail(reason: PlayFailReason.missingConfig, denyReason: nil)
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
            // An entry tap already is the ask to play: open for any granted
            // chance, whatever the backend's `show` says. A direct routing
            // only auto-opens on `show`; anything else stays pending.
            if chance.show || request.trigger == .entryTap {
                return .open(chance)
            }
            return .hold(chance)
        case .denied(let reason):
            if let reason, Self.hideEntryDenyReasons.contains(reason) {
                return .hideEntry(denyReason: reason)
            }
            return .fail(reason: PlayFailReason.denied, denyReason: reason)
        case .failure(let error):
            switch error {
            case .transport, .httpStatus:
                return .fail(reason: PlayFailReason.network, denyReason: nil)
            case .invalidResponse:
                return .fail(reason: PlayFailReason.invalidResponse, denyReason: nil)
            }
        }
    }
}

/// Who the chance is asked for. A snapshot read once per request.
struct PlayIdentity: Equatable, Sendable {
    let userId: String
    let userHash: String?
    let deviceId: String?
}

/// What asked for the chance: a direct routing (`auto`) or the user's tap on
/// an entry canvas (`entryTap`, `Action.openGame`).
enum PlayTrigger: Equatable, Sendable {
    case auto
    case entryTap
}

/// One chance request. `triggerId` arrives trimmed; `isGameBusy` reports
/// whether a game is loading or on screen (`GamePresenter.isBusy`).
struct PlayRequest {
    let campaignKey: String
    let triggerId: String
    let testInvocationId: String?
    let trigger: PlayTrigger
    let isGameBusy: () -> Bool
}

/// What a `PlaySession.request` decided.
enum PlayDecision: Equatable, Sendable {
    /// Granted, and the game opens now.
    case open(GrantedChance)
    /// Granted with `show == false` on a direct routing: prefetch only, the
    /// direct entry stays pending for the acceptance watchdog.
    case hold(GrantedChance)
    /// Denied with a reason in `hideEntryDenyReasons`: hide the entry.
    case hideEntry(denyReason: String)
    /// Anything else: log, report the live test, emit `game_open_failed`,
    /// and settle a direct entry at once.
    case fail(reason: String, denyReason: String?)
}

/// The `PlayDecision.fail` reason strings. Exact on both platforms.
enum PlayFailReason {
    /// A game is showing, or another request is already in flight.
    static let busy = "busy"
    /// Blank trigger id, or no identity / blank user id.
    static let missingConfig = "missing_config"
    /// Denied with a reason outside the hide set (carried, may be nil).
    static let denied = "denied"
    /// Transport failure, non-2xx HTTP status, or no network client.
    static let network = "network"
    /// The response did not parse / violated the strict schema.
    static let invalidResponse = "invalid_response"
}
