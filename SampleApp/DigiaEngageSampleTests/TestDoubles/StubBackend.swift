import Foundation
import ObjectiveC

/// The network boundary: every request the SDK makes lands here instead of the internet. The campaign
/// bundle answers with the fixture campaigns, the analytics endpoints accept everything, and the Test
/// Kit's media origin is served from the workspace's `testkit/mock-server/assets`.
///
/// Registered with `URLProtocol.registerClass`, so the SDK's real `URLSessionNetworkClient` and the image
/// pipeline run unchanged; only the wire is replaced.
final class StubBackend: URLProtocol, @unchecked Sendable {
    struct Recorded: Sendable {
        let url: URL
        let method: String
        let body: Data?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var campaignsBody = Data()
    nonisolated(unsafe) private static var recorded: [Recorded] = []

    /// What a test may change about the backend's answers.
    struct Options: Sendable {
        /// The server clock the bundle response carries (`X-Digia-Server-Time-Ms`), or nil for none.
        var serverTimeMs: Int64?
        /// Serve every image that is not the Test Kit's or Digia's (the fixtures' picsum and CDN
        /// pictures, which a test must not fetch) as the Test Kit's `strawberry.jpg`, so a golden shows how
        /// the image is fitted and clipped instead of an empty error state.
        var foreignImagesAsStandIn = true
    }

    nonisolated(unsafe) private static var options = Options()

    static func install(campaigns: [[String: any Sendable]], options: Options = Options()) {
        var response: [String: Any] = ["campaigns": campaigns]
        // The SDK reads design tokens from the bundle response, not from a campaign, so the fixture's are lifted there.
        if let tokens = campaigns.lazy.compactMap({ $0["designTokens"] }).first { response["designTokens"] = tokens }
        let payload: [String: Any] = ["data": ["response": response]]
        lock.withLock {
            campaignsBody = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            recorded = []
            Self.options = options
        }
        URLProtocol.registerClass(StubBackend.self)
        swizzleDefaultConfiguration()
    }

    static func uninstall() {
        URLProtocol.unregisterClass(StubBackend.self)
    }

    /// `registerClass` reaches only `URLSession.shared`. The SDK and the image pipeline build their own
    /// sessions from `URLSessionConfiguration.default`, so that configuration carries the stub from here on.
    /// Test-only; every session built before `install` keeps its real wire.
    nonisolated(unsafe) private static var swizzled = false
    private static func swizzleDefaultConfiguration() {
        guard !swizzled else { return }
        swizzled = true
        let selector = NSSelectorFromString("defaultSessionConfiguration")
        guard let original = class_getClassMethod(URLSessionConfiguration.self, selector),
              let replacement = class_getClassMethod(URLSessionConfiguration.self, #selector(URLSessionConfiguration.stubbedDefault))
        else { return }
        method_exchangeImplementations(original, replacement)
    }

    /// Every request seen since `install`, in order.
    static var requests: [Recorded] { lock.withLock { recorded } }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme, scheme == "https" || scheme == "http" else { return false }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.withLock {
            Self.recorded.append(Recorded(url: url, method: request.httpMethod ?? "GET", body: request.httpBody ?? request.httpBodyStream.flatMap(Self.read)))
        }
        let (status, body, type) = answer(url)
        var headers = ["Content-Type": type, "Content-Length": "\(body.count)"]
        if url.path.hasSuffix("/getCampaignBundle"), let serverTime = Self.lock.withLock({ Self.options.serverTimeMs }) {
            headers["X-Digia-Server-Time-Ms"] = "\(serverTime)"
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func answer(_ url: URL) -> (Int, Data, String) {
        if url.host == "testkit.local" {
            let name = url.lastPathComponent
            let file = WorkspaceFixtures.testkitAssets.appendingPathComponent(name)
            if url.path.hasPrefix("/assets/"), let data = try? Data(contentsOf: file) {
                return (200, data, Self.mimeType(for: file))
            }
            // A fixture can name a picture the mock server does not ship; a known stand-in is drawn instead of
            // an error, so the golden still shows the layout. Other kinds of media are a 404, as the server sends.
            if ["png", "jpg", "jpeg", "webp", "gif"].contains(file.pathExtension.lowercased()) {
                let stand = WorkspaceFixtures.testkitAssets.appendingPathComponent("strawberry.jpg")
                if let data = try? Data(contentsOf: stand) { return (200, data, "image/jpeg") }
            }
            return (404, Data(), "text/plain")
        }
        if let host = url.host, host != "testkit.local", !host.hasSuffix("digia.tech"),
           !Self.lock.withLock({ Self.options.foreignImagesAsStandIn }) {
            return (404, Data(), "text/plain")
        }
        if let host = url.host, host != "testkit.local", !host.hasSuffix("digia.tech") {
            let file = WorkspaceFixtures.testkitAssets.appendingPathComponent("strawberry.jpg")
            return ((try? Data(contentsOf: file)).map { (200, $0, "image/jpeg") }) ?? (404, Data(), "text/plain")
        }
        if url.path.hasSuffix("/getCampaignBundle") {
            return (200, Self.lock.withLock { Self.campaignsBody }, "application/json")
        }
        return (200, Data(#"{"accepted":1,"rejected":0,"errors":[]}"#.utf8), "application/json")
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func mimeType(for file: URL) -> String {
        switch file.pathExtension {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "svg": "image/svg+xml"
        case "webp": "image/webp"
        case "gif": "image/gif"
        case "mp4": "video/mp4"
        case "json": "application/json"
        default: "application/octet-stream"
        }
    }
}

extension URLSessionConfiguration {
    /// After the exchange in `StubBackend`, `default` lands here, and this call reaches the original.
    @objc class func stubbedDefault() -> URLSessionConfiguration {
        let config = stubbedDefault()
        config.protocolClasses = [StubBackend.self] + (config.protocolClasses ?? [])
        return config
    }
}
