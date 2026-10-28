import Foundation
import Testing
@testable import DigiaEngage

/// Why a floater's Lottie did not load, as `loadLottieSource` tells the health report: a 4xx is
/// the campaign's fault (`http_4xx`), a 2xx that is not an animation is a content fault (`decode`),
/// and a failure with no response at all is the network's, which is not reported. The PiP waits on
/// this load before it shows, so the cause decides whether a dropped campaign is diagnosable.
///
/// Lottie downloads through `URLSession.shared`, so the origin is a `URLProtocol` registered for
/// one host name of its own. The Flutter counterpart is the media half of
/// `flutter/core/test/fixture_behaviour/degradation_pip_test.dart`, which drives images; the image
/// cases are already ported in `FixtureBehaviour/Floater/PipMediaDegradationBehaviourTests.swift`.
@Suite("Media floater: Lottie load health", .serialized, .tags(.integration, .media, .floater))
struct MediaFloaterLottieHealthTests {

    private static let animation = Data(#"""
    {"v":"5.7.4","fr":30,"ip":0,"op":30,"w":100,"h":100,"nm":"t","ddd":0,"assets":[],"layers":[]}
    """#.utf8)

    private func url(_ name: String) -> URL {
        URL(string: "https://\(MediaFloaterLottieProtocol.host)/\(UUID().uuidString)/\(name)")!
    }

    private func load(_ name: String, reply: MediaFloaterLottieProtocol.Reply) async -> (loaded: Bool, cause: String?) {
        URLProtocol.registerClass(MediaFloaterLottieProtocol.self)
        defer { URLProtocol.unregisterClass(MediaFloaterLottieProtocol.self) }
        let target = url(name)
        MediaFloaterLottieProtocol.set(reply, for: target)
        let result = await loadLottieSource(target)
        return (result.source != nil, result.failureCause)
    }

    // Fails if: media_load_health.swift `mediaFailureCause(httpStatus:)` `case (400..<500)?: "http_4xx"`
    // is deleted.
    @Test("an animation the server 404s is reported as http_4xx")
    func notFoundIsHttp4xx() async {
        let result = await load("missing.json", reply: .status(404, Data("not found".utf8)))
        #expect(!result.loaded)
        #expect(result.cause == "http_4xx")
    }

    // Fails if: media_load_health.swift `mediaFailureCause(httpStatus:)` `case (200..<300)?: "decode"`
    // is deleted.
    @Test("a 200 that is not an animation is reported as decode, for .json and .lottie alike")
    func garbageIsDecode() async {
        let json = await load("broken.json", reply: .status(200, Data("<html>CDN error</html>".utf8)))
        #expect(!json.loaded)
        #expect(json.cause == "decode")
        let dotLottie = await load("broken.lottie", reply: .status(200, Data("not a zip".utf8)))
        #expect(!dotLottie.loaded)
        #expect(dotLottie.cause == "decode")
    }

    // Fails if: media_load_health.swift `loadLottieSource` `return (nil, mediaFailureCause(httpStatus:
    // session.statusCode))` -> `return (nil, "decode")`.
    @Test("a load that gets no response is the network's fault and reports no cause")
    func networkFailureReportsNothing() async {
        let result = await load("offline.json", reply: .fail)
        #expect(!result.loaded)
        #expect(result.cause == nil)
    }

    // The control. Fails if: media_load_health.swift `loadLottieSource` `} else if let animation =
    // await LottieAnimation.loadedFrom(url: url, session: session) {` -> `} else if false {`.
    @Test("a real animation loads with no cause")
    func animationLoads() async {
        let result = await load("ok.json", reply: .status(200, Self.animation))
        #expect(result.loaded)
        #expect(result.cause == nil)
    }
}

/// Answers `URLSession.shared` requests to its own host with a scripted reply.
final class MediaFloaterLottieProtocol: URLProtocol, @unchecked Sendable {
    enum Reply { case status(Int, Data), fail }

    static let host = "lottie-\(UUID().uuidString.lowercased()).origin.test"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [URL: Reply] = [:]

    static func set(_ reply: Reply, for url: URL) { lock.withLock { replies[url] = reply } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        switch Self.lock.withLock({ Self.replies[url] }) ?? .fail {
        case let .status(code, body):
            let response = HTTPURLResponse(
                url: url, statusCode: code, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "\(body.count)"])!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: body)
            client.urlProtocolDidFinishLoading(self)
        case .fail:
            client.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
    }

    override func stopLoading() {}
}
