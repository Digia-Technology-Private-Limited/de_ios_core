import Foundation

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

/// The generic gamification HTTP pass-through (`http`).
///
/// Skins call new backend endpoints through this without an SDK update: the
/// path allowlist, not the SDK version, is the gate. Native sends to
/// `{baseUrl}/api/v1/engage/sdk/gamification/{path}` with the same auth and
/// identity headers as every other engage call. 2xx and 4xx return the status
/// and the backend JSON unchanged, so the skin decides what a refusal shows.
enum GameHttpBridge {
    /// How long one skin HTTP call may take before it answers `error timeout`.
    nonisolated static let timeoutSeconds: TimeInterval = 20

    /// A denied path: a skin must never grant itself chances.
    private nonisolated static let forbiddenPath = "grantChance"

    /// Validates a skin `http` path: one segment matching
    /// `^[a-zA-Z][a-zA-Z0-9]{0,63}$`, anything but `grantChance`.
    /// Returns the path, or nil when the call must answer `bad_request`.
    static func validatedPath(_ raw: String?) -> String? {
        guard let path = raw, path != forbiddenPath, isSingleSegment(path) else { return nil }
        return path
    }

    /// Parses a skin `http` method. Only exact `GET` and `POST` exist;
    /// anything else (including lowercase) answers `bad_request`.
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

    /// One answered skin call: a 2xx or 4xx status and its JSON body, nil
    /// when the body is empty or not a JSON object.
    struct Success {
        let status: Int
        let body: [String: Any]?
    }

    /// One skin call's failure: the bridge error code and the HTTP status
    /// when the server answered (nil for transport failures and unparsable
    /// bodies). Carrying the status lets `game_http_failed` report it, like
    /// Android's `Outcome.Error.status`.
    struct Failure: Error {
        let code: GameBridgeErrorCode
        let status: Int?
    }

    /// One failed skin `http` call's `game_http_failed` fields. The mapping
    /// production (`GamePresentation.performHttp`) and the shared case-table
    /// harness both run, so the table pins the production legs: B14 (reject),
    /// B15–B16 (transport failure), plus the in-flight/dedup reject leg both
    /// share through `inFlightRejection`. Success carries no health.
    struct FailedCall: Equatable, Sendable {
        let method: String
        let path: String
        let code: GameBridgeErrorCode
        let status: Int?
    }

    /// Most skin `http` calls one game may have in flight at once (row 20).
    nonisolated static let maxHttpInFlight = 8

    /// The in-flight reject leg, shared by production
    /// (`GamePresentation.performHttp`) and the case-table harness: a reused
    /// id or a call past the in-flight cap answers `bad_request` with health
    /// and no status — the call never runs, like Android's session. Nil when
    /// the call may run. The cap is derived from the ids alone, so callers
    /// pass one projection, never ids plus a count.
    static func inFlightRejection(
        id: String, method: String, path: String,
        inFlightIds: Set<String>
    ) -> FailedCall? {
        guard inFlightIds.contains(id) || inFlightIds.count >= maxHttpInFlight else { return nil }
        return rejectedCall(method: method, path: path, code: .badRequest)
    }

    /// The reject leg (missing method/path, denied path, bad method): answers
    /// `code` and always reports health with no status — the call never ran.
    static func rejectedCall(method: String, path: String, code: GameBridgeErrorCode) -> FailedCall {
        FailedCall(method: method, path: path, code: code, status: nil)
    }

    /// One transport outcome's failure leg: the reply code plus the health
    /// fields with the outcome status (nil for transport failures).
    static func failedCall(method: String, path: String, failure: Failure) -> FailedCall {
        FailedCall(method: method, path: path, code: failure.code, status: failure.status)
    }

    /// Sends one skin call and maps the outcome to a bridge answer: `{status,
    /// body}` on 2xx and 4xx, `server` on 5xx, `network` on any other status
    /// (a redirect is not followed, so a 3xx lands here) or transport
    /// failure, `timeout` on a timeout. The method rides verbatim from the
    /// intake; only exact `GET`/`POST` run — anything else answers
    /// `bad_request` without touching the network, like Android's
    /// `GameHttpBridge.call`.
    static func send(
        client: any NetworkClient,
        baseUrl: String,
        headers: [String: String],
        method: String,
        path: String,
        body: Data?
    ) async -> Result<Success, Failure> {
        guard let url = endpoint(baseUrl: baseUrl, path: path) else {
            return .failure(Failure(code: .badRequest, status: nil))
        }
        guard let httpMethod = Self.httpMethod(method) else {
            return .failure(Failure(code: .badRequest, status: nil))
        }
        var headers = headers
        headers["Content-Type"] = "application/json"
        let response: NetworkResponse
        do {
            response = try await client.execute(request: NetworkRequest(
                url: url, method: httpMethod, headers: headers,
                body: httpMethod == .post ? body : nil,
                connectTimeout: timeoutSeconds, readTimeout: timeoutSeconds,
                followRedirects: false))
        } catch {
            if gameTransportIsTimeout(error) {
                return .failure(Failure(code: .timeout, status: nil))
            }
            log.w("Game http failed (path=\(path), error=\(error))")
            return .failure(Failure(code: .network, status: nil))
        }
        let status = response.statusCode
        guard (200...299).contains(status) || (400...499).contains(status) else {
            log.w("Game http failed (path=\(path), status=\(status))")
            return .failure(Failure(code: status >= 500 ? .server : .network, status: status))
        }
        let body = response.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return .success(Success(status: status, body: body))
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
