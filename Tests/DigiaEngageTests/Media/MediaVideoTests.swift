import AVFoundation
import CoreVideo
import Foundation
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

// MediaVideo (D1 wrapper on A+B+C) + the StoryVideoPlayback D2 rewire (T9). Every test below
// names the one production line whose change fails it; see ai_docs/meaningful-tests.md.

private func mediaTestFileURL(_ name: String) -> URL {
    URL(string: "file:///tmp/media-video-test/\(UUID().uuidString)/\(name)")!
}

/// Polls an actor-side counter (the fake fetch client) on drained runloops.
@MainActor
private func waitForCalls(
    _ fake: FakeRangeFetchClient,
    timeout: TimeInterval = 10,
    _ want: (Int) -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if want(await fake.callCount()) { return true }
        ComponentTestHost.drainRunLoop(for: 0.02)
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return want(await fake.callCount())
}

private func mediaTestRemoteURL(_ name: String) -> URL {
    URL(string: "https://media-video-\(UUID().uuidString).test/\(name)")!
}

private final class MediaVideoFakeFactory: PlayerFactory {
    var creates = 0
    func makePlayer() -> AVQueuePlayer {
        creates += 1
        return AVQueuePlayer()
    }
}

private func mediaVideoTestPool(
    factory: MediaVideoFakeFactory,
    maxPlayers: Int = 2,
    onEvict: ((String) -> Void)? = nil
) -> VideoPlayerPool {
    VideoPlayerPool(factory: factory, maxPlayers: maxPlayers, onEvict: onEvict)
}

private func mediaVideoTestStore(
    client: FakeRangeFetchClient
) -> (MediaRangeCacheStore, URL) {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("digia-media-video-test-\(UUID().uuidString)", isDirectory: true)
    return (MediaRangeCacheStore(folder: folder, client: client), folder)
}

/// Synthesizes a tiny valid H.264 mp4 (one black 64x64 frame, 1 s long) so take-over seeks and
/// the D2 loader prove themselves against real AVFoundation parsing, with no network and no
/// checked-in binary fixture.
private func makeTinyMP4() async throws -> Data {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("digia-media-video-\(UUID().uuidString).mp4")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 64,
        AVVideoHeightKey: 64,
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)
    let buffer = try #require(status == kCVReturnSuccess && pixelBuffer != nil ? pixelBuffer : nil)
    CVPixelBufferLockBaseAddress(buffer, [])
    memset(
        CVPixelBufferGetBaseAddress(buffer),
        0,
        CVPixelBufferGetBytesPerRow(buffer) * 64)
    CVPixelBufferUnlockBaseAddress(buffer, [])
    while !input.isReadyForMoreMediaData {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    adaptor.append(buffer, withPresentationTime: .zero)
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        writer.finishWriting {
            if let error = writer.error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }
    let data = try Data(contentsOf: url)
    try? FileManager.default.removeItem(at: url)
    return data
}

@MainActor
private func mediaVideoPlayback(
    urlString: String,
    demand: StoryVideoLoadDemand,
    active: Bool,
    resourceLoader: MediaResourceLoader
) -> StoryVideoPlayback {
    let item = StoryItemConfig(type: .video, url: urlString, duration: 5_000)
    let playback = StoryVideoPlayback(
        urlString: urlString,
        purpose: .thumbnail(item),
        resourceLoader: resourceLoader
    )
    playback.campaignKey = "test-campaign"
    playback.update(
        state: StoryVideoPlaybackState(
            demand: demand,
            active: active,
            muted: true,
            repeatWindow: false,
            restartGeneration: 0
        ),
        events: StoryVideoPlaybackEvents()
    )
    return playback
}

@MainActor
@Suite("MediaVideo takeOver", .tags(.media, .unit))
struct MediaVideoTakeOverTests {
    private func loader() -> MediaResourceLoader { MediaResourceLoader() }

    // Fails if the same-URL skip is removed from `takeOver`: without the `holdsOrigin` guard
    // every re-take-over re-points the item (re-buffer, lost frame).
    @Test("the same url skips the item swap")
    func sameURLSkipsTheItemSwap() {
        let player = AVPlayer()
        let first = AVPlayerItem(url: mediaTestFileURL("same.mp4"))
        player.replaceCurrentItem(with: first)
        var looped: [Bool] = []
        var invalid = 0

        player.takeOver(
            spec: MediaSpec(url: first.assetURLString, fit: .cover),
            resourceLoader: loader(),
            setLooping: { looped.append($0) },
            onInvalidStart: { invalid += 1 }
        )

        #expect(player.currentItem === first)
        #expect(invalid == 0)
        #expect(looped == [false])
        #expect(player.isMuted == true)
    }

    // Fails if the swap is removed from `takeOver`: without `replaceCurrentItem` a URL change
    // keeps playing the old item.
    @Test("a url change swaps the item")
    func urlChangeSwapsTheItem() {
        let player = AVPlayer()
        let first = AVPlayerItem(url: mediaTestFileURL("one.mp4"))
        player.replaceCurrentItem(with: first)
        let secondURL = mediaTestFileURL("two.mp4")

        player.takeOver(
            spec: MediaSpec(url: secondURL.absoluteString, fit: .cover),
            resourceLoader: loader(),
            setLooping: { _ in },
            onInvalidStart: {}
        )

        #expect(player.currentItem !== first)
        #expect((player.currentItem?.asset as? AVURLAsset)?.url == secondURL)
    }

    // Fails if the volume line is removed from `takeOver`: a reused player keeps the previous
    // borrower's mute.
    @Test("takeOver applies the spec volume")
    func takeOverAppliesTheSpecVolume() {
        let player = AVPlayer()
        player.isMuted = true

        player.takeOver(
            spec: MediaSpec(url: mediaTestFileURL("v.mp4").absoluteString, muted: false),
            resourceLoader: loader(),
            setLooping: { _ in },
            onInvalidStart: {}
        )

        #expect(player.isMuted == false)
    }

    // Fails if the loop line is removed from `takeOver`: a reused player keeps looping (or
    // not) from its previous borrow.
    @Test("takeOver carries the loop flag to the owner")
    func takeOverCarriesTheLoopFlag() {
        let player = AVPlayer()
        var looped: [Bool] = []

        player.takeOver(
            spec: MediaSpec(url: mediaTestFileURL("v.mp4").absoluteString, loop: true),
            resourceLoader: loader(),
            setLooping: { looped.append($0) },
            onInvalidStart: {}
        )

        #expect(looped == [true])
    }

    // Fails if the seek line is removed from `takeOver`: a reused player keeps its old
    // playhead instead of starting at `startMs`.
    @Test("takeOver seeks to the spec start")
    func takeOverSeeksToTheSpecStart() async throws {
        let mp4 = try await makeTinyMP4()
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("digia-takeover-\(UUID().uuidString).mp4")
        try mp4.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let player = AVPlayer()

        player.takeOver(
            spec: MediaSpec(url: file.absoluteString, startMs: 500),
            resourceLoader: loader(),
            setLooping: { _ in },
            onInvalidStart: {}
        )

        #expect(await waitUntilMedia { abs(player.currentTime().seconds - 0.5) < 0.25 })
    }

    // Fails if the `max(startMs, 0)` coercion is removed from `takeOver`: a negative start
    // builds an invalid CMTime instead of degrading to zero.
    @Test("a negative startMs coerces to zero")
    func negativeStartMsCoercesToZero() async throws {
        let mp4 = try await makeTinyMP4()
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("digia-takeover-\(UUID().uuidString).mp4")
        try mp4.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let player = AVPlayer()
        var invalid = 0

        player.takeOver(
            spec: MediaSpec(url: file.absoluteString, autoplay: false, startMs: -500),
            resourceLoader: loader(),
            setLooping: { _ in },
            onInvalidStart: { invalid += 1 }
        )

        #expect(invalid == 0)
        #expect(await waitUntilMedia { player.currentItem?.status == .readyToPlay })
        #expect(player.currentTime().seconds < 0.25)
    }

    // Fails if the `mediaUsableURL` guard is removed from `takeOver`: a templated URL builds
    // an item for garbage instead of reporting `invalid_url`.
    @Test("an unusable url reports invalid start and keeps the item")
    func unusableURLReportsInvalidStart() {
        let player = AVPlayer()
        var causes: [String] = []
        var invalid = 0

        player.takeOver(
            spec: MediaSpec(url: "{{campaign.video}}"),
            resourceLoader: loader(),
            setLooping: { _ in },
            onInvalidStart: { invalid += 1; causes.append("invalid_url") }
        )

        #expect(invalid == 1)
        #expect(causes == ["invalid_url"])
        #expect(player.currentItem == nil)
    }
}

private extension AVPlayerItem {
    var assetURLString: String {
        ((asset as? AVURLAsset)?.url.absoluteString) ?? ""
    }
}

@MainActor
@Suite("MediaVideo borrow lifecycle", .tags(.media, .unit))
struct MediaVideoBorrowTests {
    private func coordinator(
        key: String? = "story-7",
        pool: VideoPlayerPool? = nil,
        loader: MediaResourceLoader? = nil
    ) -> MediaVideoCoordinator {
        MediaVideoCoordinator(
            keepAliveKey: key,
            pool: pool,
            resourceLoader: loader ?? MediaResourceLoader()
        )
    }

    private func spec(url: String, loop: Bool = false) -> MediaSpec {
        MediaSpec(url: url, loop: loop, autoplay: false)
    }

    // Fails if the owned path reuses the released player: without the fresh
    // `factory.makePlayer()` on URL change the old (detached) item keeps showing.
    @Test("an owned url change never reuses the released player")
    func ownedURLChangeBuildsAFreshPlayer() {
        let owner = coordinator(key: nil)
        let first = mediaTestFileURL("one.mp4").absoluteString
        let second = mediaTestFileURL("two.mp4").absoluteString

        owner.appear(spec: spec(url: first), playing: false, campaignKey: nil)
        let released = owner.activePlayer
        #expect(released != nil)

        owner.appear(spec: spec(url: second), playing: false, campaignKey: nil)

        #expect(owner.activePlayer !== released)
        #expect(released?.currentItem == nil)
        owner.disappear()
    }

    // Fails if a refused borrow builds around the pool: without the nil-borrow still branch
    // the view would mint an owned player and defeat eviction (D3).
    @Test("a refused borrow holds no player and gives up")
    func refusedBorrowHoldsNoPlayer() {
        let factory = MediaVideoFakeFactory()
        let pool = mediaVideoTestPool(factory: factory, maxPlayers: 1)
        let held = pool.obtain(
            key: "screen", url: mediaTestFileURL("screen.mp4"), priority: .onScreen)
        #expect(held != nil)
        var gaveUp = 0
        let rail = coordinator(pool: pool)
        let spec = self.spec(url: mediaTestRemoteURL("thumb.mp4").absoluteString)

        rail.appear(
            spec: spec, playing: false, campaignKey: nil, onGiveUp: { gaveUp += 1 })

        #expect(rail.activePlayer == nil)
        #expect(rail.gaveUp)
        #expect(gaveUp == 1)
        #expect(factory.creates == 1)
        rail.disappear()
        #expect(pool.heldKeys() == ["screen"])
    }

    // Fails if eviction is invisible: without the `currentItem` nil KVO the view keeps
    // showing a detached (frozen) frame instead of its still. `release` detaches exactly the
    // way an eviction does.
    @Test("a detached borrow degrades to the still")
    func detachedBorrowDegradesToStill() async {
        let factory = MediaVideoFakeFactory()
        let pool = mediaVideoTestPool(factory: factory)
        let borrower = coordinator(pool: pool)
        let spec = self.spec(url: mediaTestFileURL("clip.mp4").absoluteString)
        borrower.appear(spec: spec, playing: false, campaignKey: nil)
        #expect(borrower.activePlayer != nil)

        pool.release()

        #expect(await waitUntilMedia { borrower.degraded })
        #expect(borrower.activePlayer == nil)
        #expect(borrower.gaveUp)
        borrower.disappear()
    }

    // Fails if appear/disappear are unpaired: without `giveBack` the key stays held and the
    // pool leaks a slot.
    @Test("disappear gives the borrow back")
    func disappearGivesTheBorrowBack() {
        let factory = MediaVideoFakeFactory()
        let pool = mediaVideoTestPool(factory: factory)
        let borrower = coordinator(pool: pool)
        let spec = self.spec(url: mediaTestFileURL("clip.mp4").absoluteString)

        borrower.appear(spec: spec, playing: false, campaignKey: nil)
        #expect(pool.heldKeys() == ["story-7"])

        borrower.disappear()

        #expect(pool.heldKeys().isEmpty)
    }

    // Fails if a same-key re-appear re-points: without the pool handover + take-over skip the
    // borrowed frame is lost on every re-show (rotation, PIP drag).
    @Test("the same key and url hands over the same player without re-pointing")
    func sameKeyAndURLHandsOver() {
        let factory = MediaVideoFakeFactory()
        let pool = mediaVideoTestPool(factory: factory)
        let borrower = coordinator(pool: pool)
        let url = mediaTestFileURL("clip.mp4").absoluteString
        borrower.appear(spec: spec(url: url), playing: false, campaignKey: nil)
        let first = borrower.activePlayer
        let firstItem = first?.currentItem
        #expect(first != nil)

        borrower.appear(spec: spec(url: url), playing: false, campaignKey: nil)

        #expect(borrower.activePlayer === first)
        #expect(borrower.activePlayer?.currentItem === firstItem)
        #expect(factory.creates == 1)
        borrower.disappear()
    }

    // Fails if the loop flag never reaches the pool entry: without the `setLooping` closure
    // wiring the borrowed player loops (or not) per its previous borrow.
    @Test("the loop flag reaches the pool entry at take-over")
    func loopFlagReachesThePoolEntry() {
        let factory = MediaVideoFakeFactory()
        let pool = mediaVideoTestPool(factory: factory)
        let borrower = coordinator(pool: pool)
        let spec = self.spec(url: mediaTestFileURL("clip.mp4").absoluteString, loop: true)

        borrower.appear(spec: spec, playing: false, campaignKey: nil)

        #expect(pool.isLooping(key: "story-7"))
        borrower.disappear()
        #expect(!pool.isLooping(key: "story-7"))
    }

    // Fails if decoder exhaustion is misreported: without the `.decoderTemporarilyUnavailable`
    // check a -11839 error falls through to `network`, hiding a device fault the dashboard
    // should flag as `decode`.
    @Test("decoder exhaustion maps to decode")
    func decoderExhaustionMapsToDecode() {
        let exhausted = NSError(domain: AVFoundationErrorDomain, code: -11839)
        let unknown = NSError(domain: AVFoundationErrorDomain, code: -11800)

        #expect(mediaVideoDecoderCause(error: exhausted) == "decode")
        #expect(mediaVideoDecoderCause(error: unknown) == nil)
        #expect(mediaVideoDecoderCause(error: nil) == nil)
    }

    // Fails if item failure stays silent: without the `noteItemFailed` report an unreachable
    // video degrades the picture but never fires `onError` and never reports health. The
    // failure is deterministic: every fetch throws, AVFoundation fails the item, the absence
    // of an author-fixable cause falls back to `network`.
    @Test("an unreachable video degrades with network")
    func unreachableVideoDegradesWithNetwork() async {
        let factory = MediaVideoFakeFactory()
        let pool = mediaVideoTestPool(factory: factory)
        let fake = FakeRangeFetchClient()
        await fake.enableFailAllCalls()
        let url = mediaTestRemoteURL("gone.mp4")
        let (store, _) = mediaVideoTestStore(client: fake)
        let owner = coordinator(pool: pool, loader: MediaResourceLoader(store: store))
        var causes: [String] = []
        owner.appear(
            spec: spec(url: url.absoluteString),
            playing: true,
            campaignKey: "test-campaign",
            onError: { causes.append($0) }
        )

        #expect(await waitUntilMedia(timeout: 10) { owner.failed })
        #expect(owner.showPlayer == false)
        #expect(causes == ["network"])
        owner.disappear()
    }

    // Fails if take-over stops routing remote items through the range cache: without the
    // `holdsOrigin` plain-remote rejection the pool's freshly re-pointed plain item is kept
    // and the video streams around the D2 loader (the double-download class of bug, back).
    @Test("a borrowed remote item reads through the range cache")
    func borrowedRemoteItemReadsThroughTheCache() async {
        let factory = MediaVideoFakeFactory()
        let pool = mediaVideoTestPool(factory: factory)
        let fake = FakeRangeFetchClient()
        let (store, _) = mediaVideoTestStore(client: fake)
        let loader = MediaResourceLoader(store: store)
        let borrower = coordinator(pool: pool, loader: loader)
        let url = mediaTestRemoteURL("clip.mp4").absoluteString

        borrower.appear(spec: spec(url: url), playing: false, campaignKey: nil)
        let first = borrower.activePlayer
        #expect(first != nil)
        let assetURL = (first?.currentItem?.asset as? AVURLAsset)?.url
        #expect(assetURL?.scheme == MediaResourceLoader.scheme)
        #expect(MediaResourceLoader.originURL(from: assetURL!) == URL(string: url))

        borrower.appear(spec: spec(url: url), playing: false, campaignKey: nil)

        #expect(borrower.activePlayer === first)
        borrower.disappear()
    }
}

@MainActor
@Suite("MediaVideo still layers", .tags(.media, .component), .serialized)
struct MediaVideoComponentTests {
    private static let blurHash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj"
    private static let redDot: UIImage = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).image {
            context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }()

    private func mount(
        _ spec: MediaSpec,
        key: String? = "story-7",
        pool: VideoPlayerPool? = nil,
        loader: MediaResourceLoader? = nil
    ) -> UIWindow {
        mountMedia(
            MediaVideo(spec: spec, keepAliveKey: key, playing: false, pool: pool, resourceLoader: loader)
                .environment(\.digiaCampaignKey, "test-campaign")
                .environment(\.mediaImageLoader, FakeImageLoader.shared)
                .frame(width: 200, height: 200)
        )
    }

    private func renderedCenter(_ window: UIWindow) -> RGB? {
        centerPixel(of: ComponentTestHost.renderImage(of: window.rootViewController!.view))
    }

    private func hasPlayerLayer(in view: UIView) -> Bool {
        var found = false
        func walk(_ current: UIView) {
            if current.layer is AVPlayerLayer {
                found = true
                return
            }
            current.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    // Fails if the poster is not the top still below the (transparent) player layer: without
    // the poster-over-blur branch the tile shows blur/backdrop while the fetch is in flight.
    @Test("the poster shows before the first frame with no spinner")
    func posterShowsBeforeFirstFrame() async throws {
        defer { FakeImageLoader.reset() }
        let fake = FakeRangeFetchClient()
        let url = mediaTestRemoteURL("clip.mp4")
        await fake.setDelay(60_000_000_000)
        let (store, _) = mediaVideoTestStore(client: fake)
        let loader = MediaResourceLoader(store: store)
        let poster = FakeImageLoader.url("poster.png")
        FakeImageLoader.set(.image(Self.redDot), for: poster)
        let factory = MediaVideoFakeFactory()
        let pool = mediaVideoTestPool(factory: factory)

        let window = mount(
            MediaSpec(url: url.absoluteString, posterURL: poster.absoluteString),
            pool: pool,
            loader: loader
        )
        defer { ComponentTestHost.unmount(window) }

        #expect(await waitUntilMedia { FakeImageLoader.requestCount(for: poster) > 0 })
        #expect(await waitForCalls(fake, timeout: 5) { $0 > 0 })
        #expect(await waitUntilMedia(timeout: 10) {
            renderedCenter(window).map { pixelsNearly($0, RGB(r: 1, g: 0, b: 0)) } ?? false
        })
        let middle = renderedCenter(window)
        #expect(middle != nil)
        #expect(pixelsNearly(middle!, RGB(r: 1, g: 0, b: 0)))
        #expect(!hasActivityIndicator(in: window.rootViewController!.view))
    }

    // Fails if a refused borrow builds a player anyway: the tile must show the shared dark
    // backdrop (no layer, no spinner) instead of an empty box.
    @Test("a refused borrow shows the backdrop with no player")
    func refusedBorrowShowsBackdrop() async {
        defer { FakeImageLoader.reset() }
        let factory = MediaVideoFakeFactory()
        let pool = mediaVideoTestPool(factory: factory, maxPlayers: 1)
        let held = pool.obtain(
            key: "screen", url: mediaTestFileURL("screen.mp4"), priority: .onScreen)
        #expect(held != nil)
        let fake = FakeRangeFetchClient()
        let (store, _) = mediaVideoTestStore(client: fake)
        let loader = MediaResourceLoader(store: store)

        let window = mount(
            MediaSpec(url: mediaTestRemoteURL("thumb.mp4").absoluteString),
            key: "rail-1",
            pool: pool,
            loader: loader
        )
        defer { ComponentTestHost.unmount(window) }

        ComponentTestHost.drainRunLoop(for: 0.3)
        let middle = renderedCenter(window)
        #expect(middle != nil)
        #expect(pixelsNearly(middle!, RGB(r: 0.1, g: 0.1, b: 0.1)))
        #expect(!hasPlayerLayer(in: window.rootViewController!.view))
        #expect(!hasActivityIndicator(in: window.rootViewController!.view))
    }

    // Fails if the spinner arm is removed: with no poster and no blur the tile must show a
    // spinner after `spinnerDelaySeconds`, never a bare backdrop wait.
    @Test("a still-less load shows the spinner", .tags(.slow))
    func stillLessLoadShowsSpinner() async {
        defer { FakeImageLoader.reset() }
        let fake = FakeRangeFetchClient()
        await fake.setDelay(60_000_000_000)
        let (store, _) = mediaVideoTestStore(client: fake)
        let loader = MediaResourceLoader(store: store)
        let factory = MediaVideoFakeFactory()
        let pool = mediaVideoTestPool(factory: factory)

        let window = mount(
            MediaSpec(url: mediaTestRemoteURL("slow.mp4").absoluteString),
            pool: pool,
            loader: loader
        )
        defer { ComponentTestHost.unmount(window) }

        #expect(await waitForCalls(fake, timeout: 5) { $0 > 0 })
        #expect(await waitUntilMedia(timeout: 5) {
            hasActivityIndicator(in: window.rootViewController!.view)
        })
    }
}

@MainActor
@Suite("StoryVideoPlayback D2", .tags(.media, .component), .serialized)
struct StoryVideoPlaybackD2Tests {
    // R-A Q2, answered with a real asset: a real mp4 served through the fake fetcher is parsed
    // by real AVFoundation through the real D2 loader (real resource-loading requests, real
    // adapter once-guard). The first view fetches each byte range ONCE; the second view — a
    // new store on the same folder — fetches NOTHING.
    // Fails if playback bypasses the range cache: a direct stream refetches on the second
    // view, and a whole-file download fetches ranges the player never asked for.
    @Test("a real asset plays through the cache once then serves from disk")
    func realAssetFetchesOnceThenServesFromDisk() async throws {
        let mp4 = try await makeTinyMP4()
        let url = mediaTestRemoteURL("story.mp4")
        let fake = FakeRangeFetchClient()
        await fake.setBehavior(
            url: url, body: mp4, contentType: "video/mp4", totalLength: nil, rangeSupported: true)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("digia-story-d2-test-\(UUID().uuidString)", isDirectory: true)
        let firstStore = MediaRangeCacheStore(folder: folder, client: fake)
        let firstLoader = MediaResourceLoader(store: firstStore)
        let first = mediaVideoPlayback(
            urlString: url.absoluteString,
            demand: .poster(.eligible),
            active: false,
            resourceLoader: firstLoader
        )
        defer { first.tearDown() }

        #expect(await waitUntilMedia(timeout: 15) { first.poster != nil })
        let firstCalls = await fake.callCount()
        #expect(firstCalls > 0)
        let ranges = await fake.recordedRanges()
        #expect(Set(ranges.map { "\($0)" }).count == ranges.count)

        let secondStore = MediaRangeCacheStore(folder: folder, client: fake)
        let secondLoader = MediaResourceLoader(store: secondStore)
        let second = mediaVideoPlayback(
            urlString: url.absoluteString,
            demand: .playback(.eligible),
            active: true,
            resourceLoader: secondLoader
        )
        defer { second.tearDown() }
        #expect(await waitUntilMedia(timeout: 15) {
            second.player?.currentItem?.status == .readyToPlay
        })
        ComponentTestHost.drainRunLoop(for: 1.0)

        #expect(await fake.callCount() == firstCalls)
    }

    // Fails if file URLs route through the range cache: a local file must play directly (as
    // on Android's scheme routing) with zero fetcher calls.
    @Test("a local file plays directly with no fetches")
    func localFilePlaysDirectly() async throws {
        let mp4 = try await makeTinyMP4()
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("digia-story-local-\(UUID().uuidString).mp4")
        try mp4.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let fake = FakeRangeFetchClient()
        let (store, _) = mediaVideoTestStore(client: fake)
        let loader = MediaResourceLoader(store: store)
        let playback = mediaVideoPlayback(
            urlString: file.absoluteString,
            demand: .playback(.eligible),
            active: true,
            resourceLoader: loader
        )
        defer { playback.tearDown() }

        #expect(await waitUntilMedia(timeout: 15) { playback.player != nil })
        playback.playerLayerDidBecomeReady()
        #expect(await fake.callCount() == 0)
    }

    // Fails if an unusable URL no longer degrades synchronously: without the
    // `mediaUsableURL` guard the failure surfaces late (or never) instead of reporting
    // `invalid_url`.
    @Test("a templated url fails fast without fetching")
    func templatedURLFailsFast() async {
        let fake = FakeRangeFetchClient()
        let (store, _) = mediaVideoTestStore(client: fake)
        let loader = MediaResourceLoader(store: store)
        var failed = false
        let item = StoryItemConfig(type: .video, url: "{{campaign.video}}", duration: 5_000)
        let playback = StoryVideoPlayback(
            urlString: item.url, purpose: .thumbnail(item), resourceLoader: loader)
        defer { playback.tearDown() }
        playback.update(
            state: StoryVideoPlaybackState(
                demand: .playback(.eligible),
                active: true,
                muted: true,
                repeatWindow: false,
                restartGeneration: 0
            ),
            events: StoryVideoPlaybackEvents(onFailed: { failed = true })
        )

        #expect(await waitUntilMedia { failed })
        #expect(await fake.callCount() == 0)
        #expect(playback.player == nil)
    }
}
