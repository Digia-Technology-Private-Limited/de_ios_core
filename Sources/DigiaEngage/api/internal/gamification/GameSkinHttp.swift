import Foundation

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

/// The generic gamification HTTP pass-through (`http`).
///
/// Skins call new backend endpoints through this without an SDK update: the
/// path allowlist, not the SDK version, is the gate. Native sends to
/// `{baseUrl}/api/v1/engage/sdk/gamification/{path}` with the same auth and
/// identity headers as every other engage call, and returns the raw backend
/// JSON envelope unchanged.
enum GameHttpBridge {
    /// How long one skin HTTP call may take before it answers `error timeout`.
    nonisolated static let timeoutSeconds: TimeInterval = 20

    /// A denied path: a skin must never grant itself chances.
    private nonisolated static let forbiddenPath = "grantChance"

    /// Validates a skin `http` path: one segment matching
    /// `^[a-zA-Z][a-zA-Z0-9]{0,63}$`, anything but `grantChance`.
    /// Returns the path, or nil when the call must answer `error forbidden`.
    static func validatedPath(_ raw: String?) -> String? {
        guard let path = raw, path != forbiddenPath, isSingleSegment(path) else { return nil }
        return path
    }

    /// Parses a skin `http` method. Only exact `GET` and `POST` exist;
    /// anything else (including lowercase) answers `error invalid`.
    static func httpMethod(_ raw: String?) -> HTTPMethod? {
        switch raw {
        case "GET": return .get
        case "POST": return .post
        default: return nil
        }
    }

    /// The endpoint URL for a validated path.
    static func endpoint(baseUrl: String, path: String) -> URL? {
        URL(string: "\(baseUrl)/api/v1/engage/sdk/gamification/\(path)")
    }

    /// Encodes a skin `http` body. Nil when the object is not JSON — the body
    /// came from JSON, so this fails only on programmer error upstream.
    static func jsonData(_ body: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body)
        else { return nil }
        return data
    }

    /// One skin call's outcome: the raw JSON envelope and the HTTP status
    /// that delivered it.
    struct Success {
        let envelope: [String: Any]
        let status: Int
    }

    /// One skin call's failure: the bridge error code and the HTTP status
    /// when the server answered (nil for transport failures and unparsable
    /// bodies). Carrying the status lets `game_http_failed` report it, like
    /// Android's `Outcome.Error.status`.
    struct Failure: Error {
        let code: GameBridgeErrorCode
        let status: Int?
    }

    /// Sends one skin call and maps the outcome to a bridge answer: the raw
    /// JSON envelope on HTTP 200 (refusals included), `network` on any other
    /// status or transport failure, `timeout` on a timeout, `internal` when a
    /// 200 body is not JSON at all. The method rides verbatim from the
    /// intake; only exact `GET`/`POST` run — anything else answers `invalid`
    /// without touching the network, like Android's `GameHttpBridge.call`.
    static func send(
        client: any NetworkClient,
        baseUrl: String,
        headers: [String: String],
        method: String,
        path: String,
        body: Data?
    ) async -> Result<Success, Failure> {
        guard let url = endpoint(baseUrl: baseUrl, path: path) else {
            return .failure(Failure(code: .internal, status: nil))
        }
        guard let httpMethod = Self.httpMethod(method) else {
            return .failure(Failure(code: .invalid, status: nil))
        }
        var headers = headers
        headers["Content-Type"] = "application/json"
        let response: NetworkResponse
        do {
            response = try await client.execute(request: NetworkRequest(
                url: url, method: httpMethod, headers: headers,
                body: httpMethod == .post ? body : nil,
                connectTimeout: timeoutSeconds, readTimeout: timeoutSeconds))
        } catch {
            if gameTransportIsTimeout(error) {
                return .failure(Failure(code: .timeout, status: nil))
            }
            log.w("Game http failed (path=\(path), error=\(error))")
            return .failure(Failure(code: .network, status: nil))
        }
        guard response.isSuccessful else {
            return .failure(Failure(
                code: Self.errorCode(forStatus: response.statusCode),
                status: response.statusCode))
        }
        guard let data = response.body,
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .failure(Failure(code: .internal, status: response.statusCode)) }
        return .success(Success(envelope: envelope, status: response.statusCode))
    }

    /// Maps a non-2xx status to a bridge error code: 429 is `quota`, any other
    /// 4xx is `invalid` (the skin sent something the backend refused), and the
    /// rest — redirects, 5xx — is `network`.
    private static func errorCode(forStatus status: Int) -> GameBridgeErrorCode {
        if status == 429 { return .quota }
        if (400...499).contains(status) { return .invalid }
        return .network
    }

    /// The allowlist as a pure predicate: ASCII letters first, then ASCII
    /// letters or digits, 1…64 characters. A regex would read shorter, but
    /// `NSRegularExpression` throws its configuration at runtime; this cannot.
    private static func isSingleSegment(_ path: String) -> Bool {
        guard (1...64).contains(path.utf8.count) else { return false }
        guard let first = path.unicodeScalars.first,
              (first >= "A" && first <= "Z") || (first >= "a" && first <= "z")
        else { return false }
        return path.unicodeScalars.allSatisfy { scalar in
            (scalar >= "A" && scalar <= "Z") || (scalar >= "a" && scalar <= "z")
                || (scalar >= "0" && scalar <= "9")
        }
    }
}
