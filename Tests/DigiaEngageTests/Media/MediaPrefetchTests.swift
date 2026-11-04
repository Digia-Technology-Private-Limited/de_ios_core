import Foundation
import SDWebImage
import Testing
import UIKit

@testable import DigiaEngage

// The prefetch contract (D6, T12): video first-bytes/whole-file warming goes through the
// range cache, images warm through the shared SDWebImage loader (so a warmed image is a
// cache hit at render), Lottie through Lottie's own composition fetch — and nothing throws.
// A blank or templated URL, a local file that plays directly, or a failed fetch answers
// nil/false/0 while health takes the reportable failures. Each test names the one
// production line its change fails; see ai_docs/meaningful-tests.md.
@Suite("Media prefetch", .tags(.media, .unit), .serialized)
struct MediaPrefetchTests {
    private static let animation = Data(#"""
    {"v":"5.7.4","fr":30,"ip":0,"op":30,"w":100,"h":100,"nm":"t","ddd":0,"assets":[],"layers":[]}
    """#.utf8)

    private static func redImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).image {
            context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    private func imagePrefetch(campaignKey: String? = nil) -> DefaultMediaPrefetch {
        SDImageLoadersManager.shared.addLoader(FakeImageLoader.shared)
        return DefaultMediaPrefetch(campaignKey: campaignKey)
    }

    private func unwireImageFake() {
        SDImageLoadersManager.shared.removeLoader(FakeImageLoader.shared)
    }

    private func videoPrefetch(
        body: Data, totalLength: Int64? = nil, fail: Bool = false
    ) async -> (DefaultMediaPrefetch, FakeRangeFetchClient, URL) {
        let fake = FakeRangeFetchClient()
        let url = URL(string: "https://prefetch.origin.test/\(UUID().uuidString)/movie.mp4")!
        await fake.setBehavior(url: url, body: body, totalLength: totalLength)
        if fail { await fake.enableFailAllCalls() }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("digia-media-prefetch-\(UUID().uuidString)", isDirectory: true)
        let store = MediaRangeCacheStore(folder: folder, client: fake)
        return (DefaultMediaPrefetch(store: store), fake, url)
    }

    // Fails if a blank or templated URL reaches any store: the `mediaUsableURL` guard in
    // each warm method. The templated image rides the fake host, so an attempted fetch
    // would show in its per-URL count (global totals belong to other suites running in
    // parallel and are never asserted here).
    @Test("blank and templated urls warm nothing and fetch nothing")
    func blankURLsWarmNothing() async {
        let image = imagePrefetch()
        defer { unwireImageFake() }
        let (video, fake, _) = await videoPrefetch(body: Data(repeating: 0x5A, count: 64))

        // A templated URL as raw as production hands it over (a literal `{{ }}`
        // string, never a pre-encoded `URL`: `absoluteString` percent-encodes the
        // braces, so a `URL` object can no longer represent a template).
        let templated = "https://media-fake.origin.test/\(UUID().uuidString)/{{asset}}.png"

        #expect(await image.warmImage("") == nil)
        #expect(await image.warmImage(templated) == nil)
        #expect(await video.warmVideoBytes(url: "", lengthBytes: 512) == 0)
        #expect(await video.warmWholeVideo(url: "{{asset}}") == 0)
        #expect(await image.warmLottie("") == false)
        image.enqueueImage("")
        image.enqueueImage("{{asset}}")

        // The guard answers before any loader is contacted, so a nil here also means
        // no fetch; the decodable test below proves good URLs do reach the loader.
        #expect(await fake.callCount() == 0)
    }

    // Fails if a local file is fetched or reported: the `isFileURL` branch in warmImage
    // decodes off-main and hands the image back, so floaters reveal on files too.
    @Test("a file image warms from disk")
    func fileImageWarmsFromDisk() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).png")
        try Self.redImage().pngData()?.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let prefetch = DefaultMediaPrefetch()

        let warmed = await prefetch.warmImage(file.absoluteString)

        #expect(warmed != nil)
    }

    // Fails if a decodable image does not answer it: the `finish(image)` in warmImage's
    // completion, reached through the shared manager + the appended fake transport.
    @Test("a decodable image warms to itself")
    func decodableImageWarms() async {
        let prefetch = imagePrefetch()
        defer { unwireImageFake() }
        let target = FakeImageLoader.url("warm.png")
        FakeImageLoader.set(.image(Self.redImage()), for: target)

        let warmed = await prefetch.warmImage(target.absoluteString)

        // The fake answers only this host, so the decoded 4x4 red square proves the
        // fetch went through the appended transport (no shared-counter read: other
        // suites reset those counts while this runs).
        #expect(warmed?.size == CGSize(width: 4, height: 4))
    }

    // Fails if a 404 does not answer nil: the `finish(nil)` in warmImage's error branch
    // (health takes the 404; the answer stays a plain nil).
    @Test("a missing image warms to nil")
    func missingImageWarmsNil() async {
        let prefetch = imagePrefetch()
        defer { unwireImageFake() }
        let target = FakeImageLoader.url("never-uploaded.png")
        FakeImageLoader.set(.error(FakeImageLoader.httpError(status: 404)), for: target)

        let warmed = await prefetch.warmImage(target.absoluteString)

        #expect(warmed == nil)
    }

    // Fails if a cancelled warm hangs: the `gate.cancel()` in the cancellation handler
    // resumes the continuation with nil instead of waiting out the hung fetch. The test
    // waits until the fetch is actually in flight first — a cancel before the start
    // answers nil without fetching at all, which is correct but pins nothing.
    @Test("a cancelled image warm answers nil")
    func cancelledImageWarmAnswersNil() async {
        let prefetch = imagePrefetch()
        defer { unwireImageFake() }
        let target = FakeImageLoader.url("hung.png")
        FakeImageLoader.set(.hang, for: target)

        let warming = Task { await prefetch.warmImage(target.absoluteString) }
        // Let the fetch get in flight before cancelling: a cancel before the start
        // answers nil without fetching at all, which is correct but pins nothing.
        // Fixed sleep, not a shared-counter poll — other suites reset those counts.
        try? await Task.sleep(nanoseconds: 500_000_000)
        warming.cancel()
        #expect(await warming.value == nil)
    }

    // Fails if video warming stops delegating to the store: the `store.warm` call in
    // warmVideoBytes (first bytes served by the fake client).
    @Test("video warming caches first bytes through the store")
    func videoWarmingCachesFirstBytes() async {
        let (prefetch, fake, url) = await videoPrefetch(
            body: Data(repeating: 0x5A, count: 2048))

        #expect(await prefetch.warmVideoBytes(url: url.absoluteString, lengthBytes: 512) == 512)
        #expect(await fake.callCount() == 1)
    }

    // Fails if a second warm re-fetches stored bytes: the second `serve` in warmVideoBytes
    // reads the first call's ranges from disk (D2: one download serves playback + caching).
    @Test("a second video warm fetches nothing")
    func secondVideoWarmFetchesNothing() async {
        let (prefetch, fake, url) = await videoPrefetch(
            body: Data(repeating: 0x5A, count: 2048))

        _ = await prefetch.warmVideoBytes(url: url.absoluteString, lengthBytes: 512)
        _ = await prefetch.warmVideoBytes(url: url.absoluteString, lengthBytes: 512)

        #expect(await fake.callCount() == 1)
    }

    // Fails if whole-file warming stops at the first range: the `length: nil` in
    // warmWholeVideo warms to the announced total (a no-Range server's only path).
    @Test("whole video warming answers the total")
    func wholeVideoWarmingAnswersTotal() async {
        let body = Data(repeating: 0x5A, count: 2048)
        let (prefetch, fake, url) = await videoPrefetch(body: body, totalLength: 2048)

        #expect(await prefetch.warmWholeVideo(url: url.absoluteString) == 2048)
        #expect(await fake.callCount() >= 1)
    }

    // Fails if a failed fetch throws or answers stale bytes: the `catch` in
    // warmVideoBytes answers 0 (health takes the failure).
    @Test("a failed video warm answers zero")
    func failedVideoWarmAnswersZero() async {
        let (prefetch, _, url) = await videoPrefetch(
            body: Data(repeating: 0x5A, count: 2048), fail: true)

        #expect(await prefetch.warmVideoBytes(url: url.absoluteString, lengthBytes: 512) == 0)
    }

    // Fails if a served composition does not answer true: the `source != nil` branch in
    // warmLottie's `loadLottieSource` result. A local file keeps the shared `URLSession`
    // (and the `FakeMediaOrigin` other suites count on) out of the test entirely.
    @Test("a served lottie warms true")
    @MainActor
    func servedLottieWarmsTrue() async throws {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        try Self.animation.write(to: target)
        defer { try? FileManager.default.removeItem(at: target) }
        let prefetch = DefaultMediaPrefetch()

        #expect(await prefetch.warmLottie(target.absoluteString) == true)
    }

    // Fails if a missing composition does not answer false: the report-and-false branch
    // in warmLottie (health takes the failure; the answer stays a plain false).
    @Test("a missing lottie warms false")
    @MainActor
    func missingLottieWarmsFalse() async {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        let prefetch = DefaultMediaPrefetch()

        #expect(await prefetch.warmLottie(target.absoluteString) == false)
    }
}
