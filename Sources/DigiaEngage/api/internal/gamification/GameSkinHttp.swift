import Foundation

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

/// The generic gamification HTTP pass-through (bridge v1 `http`).
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

    /// Parses a skin `http` method. Only `GET` and `POST` exist; nil answers
    /// `error invalid`.
    static func httpMethod(_ raw: String?) -> HTTPMethod? {
        switch raw?.uppercased() {
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

    /// Sends one skin call and maps the outcome to a bridge answer: the raw
    /// JSON envelope on HTTP 200 (refusals included), `network` on any other
    /// status or transport failure, `timeout` on a timeout, `internal` when a
    /// 200 body is not JSON at all.
    static func send(
        client: any NetworkClient,
        baseUrl: String,
        headers: [String: String],
        method: HTTPMethod,
        path: String,
        body: Data?
    ) async -> Result<[String: Any], GameBridgeErrorCode> {
        guard let url = endpoint(baseUrl: baseUrl, path: path) else {
            return .failure(.internal)
        }
        var headers = headers
        headers["Content-Type"] = "application/json"
        let response: NetworkResponse
        do {
            response = try await client.execute(request: NetworkRequest(
                url: url, method: method, headers: headers,
                body: method == .post ? body : nil,
                connectTimeout: timeoutSeconds, readTimeout: timeoutSeconds))
        } catch let error as URLError where error.code == .timedOut {
            return .failure(.timeout)
        } catch {
            log.d("Game http failed (path=\(path), error=\(error))")
            return .failure(.network)
        }
        guard response.isSuccessful else { return .failure(.network) }
        guard let data = response.body,
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .failure(.internal) }
        return .success(envelope)
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
