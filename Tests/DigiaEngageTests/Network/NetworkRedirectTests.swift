import Foundation
import Testing

@testable import DigiaEngage

/// Answers `/play` with a 302 to `/login`, and `/login` with a 200 HTML page,
/// the shape of a captive portal.
private final class RedirectURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        if url.path.hasSuffix("/play") {
            let login = URL(string: "https://example.test/login")!
            let redirect = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                headerFields: ["Location": login.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: login), redirectResponse: redirect)
            client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        } else {
            let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: ok, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("<html>login</html>".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

@Suite("Network redirects")
struct NetworkRedirectTests {
    private func client() -> URLSessionNetworkClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RedirectURLProtocol.self]
        return URLSessionNetworkClient(
            session: URLSession(configuration: config), sessionIdProvider: { nil }, headerProvider: { [:] })
    }

    @Test("A skin call answers network on a redirect instead of the portal page")
    func skinCallRefusesRedirect() async {
        let result = await GameHttpBridge.send(
            client: client(), baseUrl: "https://example.test", headers: [:],
            method: "POST", path: "play", body: Data("{}".utf8))
        guard case .failure(let failure) = result else {
            Issue.record("expected a failure, got \(result)")
            return
        }
        #expect(failure.code == .network)
        #expect(failure.status == 302)
    }

    @Test("Other SDK calls still follow redirects")
    func defaultRequestFollowsRedirect() async throws {
        let response = try await client().execute(
            request: NetworkRequest(url: URL(string: "https://example.test/play")!))
        #expect(response.statusCode == 200)
    }
}
