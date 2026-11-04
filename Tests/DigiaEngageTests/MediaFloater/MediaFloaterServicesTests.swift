import Foundation
import Testing

@testable import DigiaEngage

extension RenderedUITests {
/// The floater has no view to read the environment from, so its Lottie warm-up and its drop report
/// read the process-wide `MediaServices`: one override reaches them like it reaches the widgets.
@Suite("Media floater: process-wide services", .serialized,
       .tags(.integration, .media, .floater),
       .enabled(if: testkitAvailable, testkitSkipReason))
@MainActor
struct MediaFloaterServicesTests {

    private final class AskedURLs: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        var all: [URL] { lock.withLock { urls } }
        func add(_ url: URL) { lock.withLock { urls.append(url) } }
    }

    @Test("a floater's Lottie warm-up loads and reports through the process-wide media services")
    func warmUpUsesTheProcessWideServices() async throws {
        defer { MediaServices.reset() }
        let recorder = HealthRecorder()
        let asked = AskedURLs()
        MediaServices.override(loadLottie: { url in
            asked.add(url)
            return (nil, "http_4xx")
        })
        let json = try fixture("pip/pip_media_lottie")
        let sdk = try await SdkHarness.start(json)
        defer { sdk.tearDown() }

        _ = try sdk.deliverFloater(keyOf(json))
        try await sdk.waitUntil("the floater is dropped", timeout: 5) { sdk.pip.state == nil }

        #expect(asked.all.map(\.lastPathComponent) == ["payday.lottie"])
        #expect(recorder.all == [.init(campaignKey: keyOf(json), kind: .lottie, cause: "http_4xx")])
    }
}
}
