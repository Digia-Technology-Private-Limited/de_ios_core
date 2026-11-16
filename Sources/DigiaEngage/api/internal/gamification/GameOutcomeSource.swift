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
}

enum GrantChanceResult: Equatable, Sendable {
    case granted(GrantedChance)
    /// Held-out and denied chances alike: nothing visible. `reason` is the
    /// server's `denyReason`, opaque, for logs only.
    case denied(reason: String?)
    case failure(GameOutcomeError)
}

/// A backend call that did not produce an answer. Returned, never thrown —
/// callers degrade off this (a direct open settles, a skin `http` answers).
enum GameOutcomeError: Error, Equatable, Sendable {
    case transport(String)
    case httpStatus(Int)
    case invalidResponse(String)
}

/// The one seam for gamification backend calls. Responses are wrapped as
/// `{ isSuccess, data: { response } }`, exactly as the contract sends them.
protocol GameOutcomeSource: Sendable {
    func grantChance(_ request: GrantChanceRequest) async -> GrantChanceResult
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
}
