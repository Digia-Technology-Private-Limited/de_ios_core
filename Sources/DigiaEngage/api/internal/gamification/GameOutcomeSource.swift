import Foundation

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

struct GrantChanceRequest: Equatable, Sendable {
    let campaignKey: String
    let userId: String
    /// The verification hash for user-gated projects, sent in the body next
    /// to `userId` and as `X-Digia-User-Hash` on every request. Nil when the
    /// app never set one.
    let userHash: String?
    /// The CEP message id (`cepCampaignId` on iOS), or the Digia rule's
    /// `event_id`. The SDK never invents one.
    let triggerId: String
    /// An explicit ask to show: always true, in live tests as well as CEP mode
    /// (a live test also carries `testInvocationId` with the device header).
    let showNow: Bool?
    /// Live test only.
    let testInvocationId: String?
    /// Live test only: sent as the `x-digia-device-id` header.
    let deviceId: String?
}

struct GrantedChance: Equatable, Sendable {
    let chanceId: String
    let expiresAt: String?
    let show: Bool
    /// Chance events the grant answer carried, for Digia analytics only (ADR 0002).
    var events: [ChanceAnalyticsEvent] = []
}

enum GrantChanceResult: Equatable, Sendable {
    case granted(GrantedChance)
    /// Held-out and denied chances alike: nothing visible. `reason` is the
    /// server's `denyReason`, opaque, for logs only.
    case denied(reason: String?, events: [ChanceAnalyticsEvent] = [])
    case failure(GameOutcomeError)
}

/// What the read-only `state` route answered for a campaign key. Never throws.
enum ChanceStateResult: Equatable, Sendable {
    /// The user can play now, with this chance. `remaining` is ignored.
    case playable(chanceId: String, expiresAt: String?)
    /// Nothing is playable and the user has played before. `result` is ignored.
    case played(chanceId: String)
    /// The user had chances, but none is open any more.
    case expired
    /// The user has no chance in this campaign.
    case none
    /// The backend refused to answer; `reason` is its code.
    case refused(reason: String)
    case failed(GameOutcomeError)
}

/// A backend call that did not produce an answer. Returned, never thrown —
/// callers degrade off this (a direct open settles, a skin `http` answers).
enum GameOutcomeError: Error, Equatable, Sendable {
    /// The transport failed. `timedOut` keeps the timeout identity, so a
    /// timeout reports `timeout` — like `getRewards` — instead of collapsing
    /// to `network`. Additive: every existing construction keeps working.
    case transport(String, timedOut: Bool = false)
    case httpStatus(Int)
    case invalidResponse(String)
}

extension GameOutcomeError {
    /// The `game_rewards_failed` code for this failure: a timeout stays a
    /// timeout, an HTTP refusal reports `status`, anything else is the
    /// backend's answer mapped down. Mirrors Android's `rewardsCode()`.
    var rewardsCode: String {
        switch self {
        case .transport(_, let timedOut):
            return timedOut ? "timeout" : "network"
        case .httpStatus:
            return "status"
        case .invalidResponse:
            return "invalid_response"
        }
    }

    /// The HTTP status for `game_rewards_failed`, when the server answered.
    var rewardsStatus: Int? {
        switch self {
        case .httpStatus(let status): return status
        default: return nil
        }
    }
}

/// Whether `error` is a timeout, walking the cause chain and not only the
/// top-level `URLError.timedOut`. Shared by the skin `http` bridge and the
/// outcome source, like Android's `failureCodeOf`.
func gameTransportIsTimeout(_ error: Error) -> Bool {
    var current: Error? = error
    while let currentError = current {
        if let urlError = currentError as? URLError, urlError.code == .timedOut {
            return true
        }
        let description = currentError.localizedDescription.lowercased()
        if description.contains("timed out") || description.contains("timeout") {
            return true
        }
        current = (currentError as NSError).userInfo[NSUnderlyingErrorKey] as? Error
    }
    return false
}

/// The one seam for gamification backend calls. Responses are wrapped as
/// `{ isSuccess, data: { response } }`, exactly as the contract sends them.
protocol GameOutcomeSource: Sendable {
    func grantChance(_ request: GrantChanceRequest) async -> GrantChanceResult
    /// The read-only play state for a campaign key. Reserves nothing and does
    /// not count as a play. Identity travels in the headers the network
    /// client already sends; the body carries only the campaign key, plus the
    /// live-test invocation when a live-test game closed.
    func state(campaignKey: String, testInvocationId: String?) async -> ChanceStateResult
    func getRewards() async -> Result<GameRewardsResponse, GameOutcomeError>
}

final class HttpGameOutcomeSource: GameOutcomeSource, Sendable {
    private let networkClient: any NetworkClient

    init(networkClient: any NetworkClient) {
        self.networkClient = networkClient
    }

    func grantChance(_ request: GrantChanceRequest) async -> GrantChanceResult {
        var body: [String: Any] = [
            "campaignKey": request.campaignKey,
            "userId": request.userId,
            "triggerId": request.triggerId,
        ]
        if let userHash = request.userHash { body["userHash"] = userHash }
        if let showNow = request.showNow { body["showNow"] = showNow }
        if let testInvocationId = request.testInvocationId {
            body["testInvocationId"] = testInvocationId
        }
        var headers = ["Content-Type": "application/json"]
        if request.testInvocationId != nil, let deviceId = request.deviceId {
            headers["x-digia-device-id"] = deviceId
        }
        let result = await post(
            urlString: DigiaEndpoints.gamificationGrantChance, body: body,
            headers: headers)
        switch result {
        case .failure(let error):
            return .failure(error)
        case .success(let response):
            guard let granted = Self.bool(response["granted"]) else {
                log.e("grantChance unreadable — missing granted flag")
                return .failure(.invalidResponse("missing granted flag"))
            }
            let events = chanceEventsOf(response["events"], campaignKey: request.campaignKey)
            if granted {
                guard let chanceId = response.nonBlankString("chanceId") else {
                    log.e("grantChance unreadable — granted without a chanceId")
                    return .failure(.invalidResponse("granted without chanceId"))
                }
                return .granted(
                    GrantedChance(
                        chanceId: chanceId,
                        expiresAt: response["expiresAt"] as? String,
                        show: Self.bool(response["show"]) ?? false,
                        events: events
                    ))
            }
            return .denied(reason: response["denyReason"] as? String, events: events)
        }
    }

    // MARK: - State

    /// The read-only play state for a campaign key. Same envelope as
    /// grantChance (`{isSuccess, data: {response}}`, `isSuccess` must be
    /// true); the answer is one of `playable`, `played`, `expired`, `none`,
    /// or a refusal. A blank `chanceId` on `playable`/`played`, an unknown
    /// `state`, or an unusable `refused` is `invalidResponse`, in the strict
    /// grantChance style.
    func state(campaignKey: String, testInvocationId: String? = nil) async -> ChanceStateResult {
        var body: [String: Any] = ["campaignKey": campaignKey]
        if let testInvocationId, !testInvocationId.isEmpty {
            body["testInvocationId"] = testInvocationId
        }
        switch await post(
            urlString: DigiaEndpoints.gamificationState,
            body: body,
            headers: ["Content-Type": "application/json"])
        {
        case .failure(let error):
            return .failed(error)
        case .success(let response):
            GameChanceStateCache.shared.record(campaignKey: campaignKey, response: response)
            if response["refused"] != nil, !(response["refused"] is NSNull) {
                guard let reason = response.nonBlankString("refused") else {
                    log.e("state unreadable — refused is not a usable reason")
                    return .failed(.invalidResponse("refused is not a usable reason"))
                }
                return .refused(reason: reason)
            }
            guard let state = response.nonBlankString("state") else {
                log.e("state unreadable — missing state")
                return .failed(.invalidResponse("missing state"))
            }
            switch state {
            case "playable":
                guard let chanceId = response.nonBlankString("chanceId") else {
                    log.e("state unreadable — playable without a chanceId")
                    return .failed(.invalidResponse("playable without chanceId"))
                }
                return .playable(
                    chanceId: chanceId, expiresAt: response["expiresAt"] as? String)
            case "played":
                guard let chanceId = response.nonBlankString("chanceId") else {
                    log.e("state unreadable — played without a chanceId")
                    return .failed(.invalidResponse("played without chanceId"))
                }
                return .played(chanceId: chanceId)
            case "expired":
                return .expired
            case "none":
                return .none
            default:
                log.e("state unreadable — unknown state (\(state))")
                return .failed(.invalidResponse("unknown state \(state)"))
            }
        }
    }

    // MARK: - Envelope

    /// The rewards page and widget data. Identity travels in the headers, as
    /// on every other call; the body stays an empty object.
    func getRewards() async -> Result<GameRewardsResponse, GameOutcomeError> {
        switch await post(
            urlString: DigiaEndpoints.gamificationGetRewards, body: [:],
            headers: ["Content-Type": "application/json"])
        {
        case .failure(let error):
            return .failure(error)
        case .success(let response):
            return .success(GameRewardsResponse.fromJson(response))
        }
    }

    private func post(
        urlString: String, body: [String: Any], headers: [String: String]
    ) async -> Result<[String: Any], GameOutcomeError> {
        guard let url = URL(string: urlString) else {
            return .failure(.invalidResponse("bad endpoint"))
        }
        let payload: Data
        do {
            payload = try JSONSerialization.data(withJSONObject: body)
        } catch {
            return .failure(.invalidResponse("request body not JSON"))
        }
        let networkResponse: NetworkResponse
        do {
            networkResponse = try await networkClient.execute(
                request: NetworkRequest(
                    url: url, method: .post, headers: headers,
                    body: payload, connectTimeout: 10, readTimeout: 10))
        } catch {
            return .failure(.transport(
                error.localizedDescription, timedOut: gameTransportIsTimeout(error)))
        }
        guard networkResponse.isSuccessful else {
            return .failure(.httpStatus(networkResponse.statusCode))
        }
        guard let root = (try? JSONSerialization.jsonObject(with: networkResponse.body ?? Data()))
            as? [String: Any]
        else {
            return .failure(.invalidResponse("response is not an object"))
        }
        guard Self.bool(root["isSuccess"]) == true else {
            return .failure(.invalidResponse("isSuccess is not true"))
        }
        guard let response = (root["data"] as? [String: Any])?["response"] as? [String: Any] else {
            return .failure(.invalidResponse("missing data.response"))
        }
        return .success(response)
    }

    /// A strict boolean: JSON booleans bridge to `NSNumber`, and so does every
    /// number — only a real boolean counts. Nil when absent or not a boolean.
    private static func bool(_ raw: Any?) -> Bool? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }
}
