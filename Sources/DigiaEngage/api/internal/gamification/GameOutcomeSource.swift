import Foundation

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

struct GrantChanceRequest: Equatable, Sendable {
    let campaignKey: String
    let userId: String
    /// iOS has no user-hash concept; always nil, kept for contract parity.
    let userHash: String?
    /// The CEP message id (`cepCampaignId` on iOS), or the Digia rule's
    /// `event_id`. The SDK never invents one.
    let triggerId: String
    /// Set only for CEP-mode triggers; omitted for live tests.
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
}

enum GrantChanceResult: Equatable, Sendable {
    case granted(GrantedChance)
    /// Held-out and denied chances alike: nothing visible. `reason` is the
    /// server's `denyReason`, opaque, for logs only.
    case denied(reason: String?)
    case failure(GameOutcomeError)
}

struct PlayRequest: Equatable, Sendable {
    let chanceId: String
    let userId: String
    let userHash: String?
    /// Made once per play attempt by the bridge (T8) and reused on every retry.
    let playId: String
}

struct PlayOutcome: Equatable, Sendable {
    let outcomeKey: String
    let kind: GamificationOutcomeKind
    let rewardType: GamificationRewardType?
    /// Carried opaquely until the T8 reward mapping reads them.
    let grant: [String: JSONValue]?
    let nextChance: [String: JSONValue]?
}

enum PlayResult: Equatable, Sendable {
    case outcome(PlayOutcome)
    case refused(GamificationPlayRefusal)
    case failure(GameOutcomeError)
}

/// A backend call that did not produce an answer. Returned, never thrown —
/// the bridge (T8) retries `busy` and network failures off this.
enum GameOutcomeError: Error, Equatable, Sendable {
    case transport(String)
    case httpStatus(Int)
    case invalidResponse(String)
}

/// The one seam for gamification backend calls. Responses are wrapped as
/// `{ isSuccess, data: { response } }`, exactly as the contract sends them.
protocol GameOutcomeSource: Sendable {
    func grantChance(_ request: GrantChanceRequest) async -> GrantChanceResult
    func play(_ request: PlayRequest) async -> PlayResult
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
            if granted {
                guard let chanceId = response.nonBlankString("chanceId") else {
                    log.e("grantChance unreadable — granted without a chanceId")
                    return .failure(.invalidResponse("granted without chanceId"))
                }
                return .granted(
                    GrantedChance(
                        chanceId: chanceId,
                        expiresAt: response["expiresAt"] as? String,
                        show: Self.bool(response["show"]) ?? false
                    ))
            }
            return .denied(reason: response["denyReason"] as? String)
        }
    }

    func play(_ request: PlayRequest) async -> PlayResult {
        var body: [String: Any] = [
            "chanceId": request.chanceId,
            "userId": request.userId,
            "playId": request.playId,
        ]
        if let userHash = request.userHash { body["userHash"] = userHash }
        let result = await post(
            urlString: DigiaEndpoints.gamificationPlay, body: body,
            headers: ["Content-Type": "application/json"])
        switch result {
        case .failure(let error):
            return .failure(error)
        case .success(let response):
            if let refusedWire = response["refused"] as? String {
                let refusal = GamificationPlayRefusal(wire: refusedWire)
                if refusal == .unavailable, refusedWire != GamificationPlayRefusal.unavailable.rawValue {
                    log.e("play refusal unknown — degrading to unavailable (refused=\(refusedWire))")
                }
                return .refused(refusal)
            }
            guard let outcomeKey = response.nonBlankString("outcomeKey") else {
                log.e("play unreadable — missing outcomeKey")
                return .failure(.invalidResponse("missing outcomeKey"))
            }
            let kind = GamificationOutcomeKind(wire: response["kind"] as? String)
            guard kind != GamificationOutcomeKind.unknown else {
                log.e("play unreadable — unknown outcome kind")
                return .failure(.invalidResponse("unknown outcome kind"))
            }
            let rewardType = GamificationRewardType(wire: response["rewardType"] as? String)
            return .outcome(
                PlayOutcome(
                    outcomeKey: outcomeKey,
                    kind: kind,
                    rewardType: rewardType == .unknown ? nil : rewardType,
                    grant: Self.object(response["grant"]),
                    nextChance: Self.object(response["nextChance"])
                ))
        }
    }

    // MARK: - Envelope

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
            return .failure(.transport(error.localizedDescription))
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

    private static func object(_ raw: Any?) -> [String: JSONValue]? {
        guard let dict = raw as? [String: Any] else { return nil }
        var result: [String: JSONValue] = [:]
        result.reserveCapacity(dict.count)
        for (key, item) in dict {
            guard let mapped = GamificationJSON.value(item) else { return nil }
            result[key] = mapped
        }
        return result
    }
}
