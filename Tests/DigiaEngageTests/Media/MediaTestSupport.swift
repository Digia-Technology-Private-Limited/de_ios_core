import Foundation
import Lottie
import SDWebImage
import SnapshotTesting
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

/// The fake HTTP origin for the media suites: a `URLProtocol` that logs every request (URL and
/// `User-Agent`), answers a scripted reply, and can hold a response until the test releases it.
///
/// The image wrapper renders through the real SDWebImage downloader and Lottie loads through
/// `URLSession.shared`; both honor a registered protocol, so only the HTTP layer is faked and
/// the caching, decoding and view updates under test are the SDK's own.
final class MediaOrigin: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        /// Answers with an HTTP status and body.
        case status(Int, Data)
        /// Fails the load with a transport error.
        case fail(URLError.Code)
    }

    struct Request: Sendable, Equatable {
        let url: URL
        let userAgent: String?
        var range: String? = nil
    }

    static let host = "media-fake.origin.test"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [URL: Reply] = [:]
    nonisolated(unsafe) private static var queued: [URL: [Reply]] = [:]
    nonisolated(unsafe) private static var held: Set<URL> = []
    nonisolated(unsafe) private static var parked: [URL: [MediaOrigin]] = [:]
    nonisolated(unsafe) private static var log: [Request] = []

    /// A fresh URL on the fake host, so request logs never leak across tests.
    static func url(_ name: String) -> URL {
        URL(string: rawURL(name))!
    }

    /// The same, unencoded: use this for template tokens (`{{…}}`), which `URL` would
    /// percent-encode before the wrapper ever sees them.
    static func rawURL(_ name: String) -> String {
        "https://\(host)/\(UUID().uuidString)/\(name)"
    }

    /// Answers `url` with `reply`. With `held`, the response waits for `release(_:)`.
    static func set(_ reply: Reply, for url: URL, held isHeld: Bool = false) {
        lock.withLock {
            replies[url] = reply
            if isHeld { held.insert(url) }
        }
    }

    /// Answers the next requests for `url` with `replies`, one each, in order; later requests get
    /// the reply set with `set(_:for:)`.
    static func queue(_ replies: [Reply], for url: URL) {
        lock.withLock { queued[url] = replies }
    }

    /// Delivers the responses held for `url` and stops holding it.
    static func release(_ url: URL) {
        let waiting = lock.withLock { () -> [MediaOrigin] in
            held.remove(url)
            return parked.removeValue(forKey: url) ?? []
        }
        waiting.forEach { $0.deliver() }
    }

    static func requests(for url: URL) -> [Request] {
        lock.withLock { log.filter { $0.url == url } }
    }

    /// Held requests for `url` still open: a request whose client cancelled it leaves.
    static func heldOpen(for url: URL) -> Int {
        lock.withLock { parked[url]?.count ?? 0 }
    }

    static func totalRequestCount() -> Int {
        lock.withLock { log.count }
    }

    static func reset() {
        lock.withLock {
            replies = [:]
            queued = [:]
            held = []
            parked = [:]
            log = []
        }
    }

    /// Routes the media loaders to this origin: the SDWebImage downloader's session gets the
    /// protocol in its configuration (SDWebImage fixes the session when the downloader is
    /// created, so the shared downloader's session is replaced once, same delegate and queue),
    /// and `URLSession.shared`, which Lottie uses, gets it from the global registry.
    static func install() {
        _ = routeDownloader
        URLProtocol.registerClass(MediaOrigin.self)
    }

    static func uninstall() { URLProtocol.unregisterClass(MediaOrigin.self) }

    /// A session routed to this origin, for the video range cache (`MediaServices.override(videoSession:)`),
    /// whose own session the global registry doesn't reach.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaOrigin.self]
        return URLSession(configuration: configuration)
    }

    /// Ends a test that installed the origin: unroutes it, clears its state and unregisters the health recorders and puts
    /// the SDK's media services back.
    static func end() {
        uninstall()
        reset()
        HealthRecorder.stopAll()
        MediaServices.reset()
    }

    private static let routeDownloader: Void = {
        let downloader = SDWebImageDownloader.shared
        guard let session = downloader.value(forKey: "session") as? URLSession else { return }
        let configuration = session.configuration.copy() as! URLSessionConfiguration
        configuration.protocolClasses = [MediaOrigin.self] + (configuration.protocolClasses ?? [])
        let routed = URLSession(
            configuration: configuration, delegate: session.delegate, delegateQueue: session.delegateQueue)
        downloader.setValue(routed, forKey: "session")
    }()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var finished = false

    /// The satisfiable slice of a `bytes=a-b` or `bytes=a-` header, nil without one.
    private static func byteRange(_ header: String?, count: Int) -> Range<Int>? {
        guard let header, header.hasPrefix("bytes=") else { return nil }
        let bounds = header.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let lower = Int(bounds[0]), lower < count else { return nil }
        let upper = Int(bounds[1]).map { min($0 + 1, count) } ?? count
        return lower < upper ? lower ..< upper : nil
    }

    override func startLoading() {
        guard let url = request.url else { return }
        let isHeld = Self.lock.withLock { () -> Bool in
            Self.log.append(Request(
                url: url, userAgent: request.value(forHTTPHeaderField: "User-Agent"),
                range: request.value(forHTTPHeaderField: "Range")))
            guard Self.held.contains(url) else { return false }
            Self.parked[url, default: []].append(self)
            return true
        }
        if !isHeld { deliver() }
    }

    override func stopLoading() {
        Self.lock.withLock {
            if let url = request.url { Self.parked[url]?.removeAll { $0 === self } }
        }
    }

    private func deliver() {
        guard let url = request.url, let client, !finished else { return }
        finished = true
        let reply = Self.lock.withLock { () -> Reply? in
            if var next = Self.queued[url], !next.isEmpty {
                let first = next.removeFirst()
                Self.queued[url] = next
                return first
            }
            return Self.replies[url]
        }
        switch reply ?? .fail(.notConnectedToInternet) {
        case let .status(code, body):
            // A 200 honours a `Range: bytes=a-b` request with a 206, as a CDN does, so the
            // video range cache can read through this origin.
            if code == 200, let range = Self.byteRange(request.value(forHTTPHeaderField: "Range"), count: body.count) {
                let slice = body.subdata(in: range)
                let response = HTTPURLResponse(
                    url: url, statusCode: 206, httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Length": "\(slice.count)", "Content-Type": "video/mp4",
                        "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(body.count)",
                    ])!
                client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(self, didLoad: slice)
                client.urlProtocolDidFinishLoading(self)
                return
            }
            let response = HTTPURLResponse(
                url: url, statusCode: code, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "\(body.count)"])!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: body)
            client.urlProtocolDidFinishLoading(self)
        case let .fail(code):
            client.urlProtocol(self, didFailWithError: URLError(code))
        }
    }
}

/// Records every `media_load_failed` record the real logger emits, off the main actor. A
/// `DiagnosticSink` on `DigiaLogger`, so production's own guard (no campaign key or cause, no
/// report) decides what arrives, and the report of any path reaches it (the wrappers and the
/// floater alike) until `MediaOrigin.end()` unregisters it.
final class HealthRecorder: DiagnosticSink, @unchecked Sendable {
    struct Record: Equatable {
        let campaignKey: String?
        let kind: HealthMediaKind
        let cause: String
    }

    private static let activeLock = NSLock()
    nonisolated(unsafe) private static var active: [HealthRecorder] = []

    /// Unregisters every recorder created since the last call.
    static func stopAll() {
        let recorders = activeLock.withLock { () -> [HealthRecorder] in
            defer { active = [] }
            return active
        }
        recorders.forEach { DigiaLogger.unregisterSink($0) }
    }

    private let lock = NSLock()
    private var records: [Record] = []

    var all: [Record] { lock.withLock { records } }

    init() {
        Self.activeLock.withLock { Self.active.append(self) }
        DigiaLogger.registerSink(self)
    }

    func accepts(_ record: TimelineRecord) -> Bool {
        record.reason?.wire == TimelineReason.mediaLoadFailed.wire
    }

    func emit(_ record: TimelineRecord) {
        guard let kind = record.extras["media_kind"].flatMap(HealthMediaKind.init(rawValue:)),
            let cause = record.extras["cause"]
        else { return }
        lock.withLock { records.append(Record(campaignKey: record.campaignKey, kind: kind, cause: cause)) }
    }
}

/// Counts callbacks. A class so a closure can bump it.
final class CallCount: @unchecked Sendable {
    var value = 0
}

/// Polls `condition` on drained runloops, like the canvas renderer suites.
@MainActor
func waitUntilMedia(timeout: TimeInterval = 10.0, condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        ComponentTestHost.drainRunLoop(for: 0.02)
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

/// The fixed stage every media test draws on: one 240x120 box, centred on the 390x844 golden
/// frame, over the striped host screen the nudge goldens use. The campaign key of the media is
/// `MediaStage.campaign`. The box clips its content, as every surface that shows media does.
enum MediaStage {
    static let campaign = "test-campaign"
    static let size = CGSize(width: 240, height: 120)

    @MainActor
    static func mount<Content: View>(_ content: Content) -> UIWindow {
        let device = ViewImageConfig.engageGolden
        let window = ComponentTestHost.makeWindow(frame: CGRect(origin: .zero, size: device.size!))
        let root = ComponentTestHost.makeDeviceHost(device: device, style: .striped, scrimColor: nil)
        let stage = ComponentTestHost.mountDialog(
            rootView: content.environment(\.digiaCampaignKey, campaign)
                .frame(width: size.width, height: size.height).clipped(), dialogSize: size, in: root)
        if #available(iOS 16.4, *) {
            stage.safeAreaRegions = []
        }
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.view.layoutIfNeeded()
        ComponentTestHost.drainRunLoop(for: 0.05)
        return window
    }

    /// Compares what the stage shows with `goldens/ios/media/<name>.png`.
    @MainActor
    static func assertGolden(_ window: UIWindow, named name: String) {
        ComponentTestHost.drainRunLoop(for: 0.3)
        assertSurfaceGolden(
            ComponentTestHost.settledImage(of: window), surface: "media", named: name, precision: 1.0,
            perceptualPrecision: 0.98)
    }
}

/// The bytes of a Test Kit asset (`testkit/mock-server/assets/`), to serve from the fake origin.
func testkitAsset(_ name: String) throws -> Data {
    let workspace = try #require(FixtureLoader.workspaceURL())
    return try Data(contentsOf: workspace.appendingPathComponent("testkit/mock-server/assets/\(name)"))
}

/// A 4x4 PNG of one solid color.
func solidPNG(_ color: UIColor) -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).pngData { context in
        color.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    }
}

/// A 4x4 PNG whose left half is opaque red and whose right half is fully transparent, so a
/// stale layer behind a loaded picture shows through on the right.
func halfTransparentPNG() -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    return UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).pngData { context in
        UIColor.red.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 4))
    }
}

/// The color of one pixel of a 1x render. Used by the one test whose proof is a pixel (the memory
/// cache hit that must draw on the first render, which no callback can tell from a blank one).
func pixelColor(of image: UIImage, atX x: Int, y: Int) -> UIColor? {
    guard let cgImage = image.cgImage, x < cgImage.width, y < cgImage.height,
        let crop = cgImage.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))
    else { return nil }
    var pixels = [UInt8](repeating: 0, count: 4)
    guard
        let context = CGContext(
            data: &pixels, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    else { return nil }
    context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return UIColor(
        red: CGFloat(pixels[0]) / 255, green: CGFloat(pixels[1]) / 255, blue: CGFloat(pixels[2]) / 255, alpha: 1)
}

/// Whether two colors are within `tolerance` on every channel.
func colorsNearly(_ left: UIColor, _ right: UIColor, tolerance: CGFloat = 0.05) -> Bool {
    var (lr, lg, lb, la) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
    var (rr, rg, rb, ra) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
    left.getRed(&lr, green: &lg, blue: &lb, alpha: &la)
    right.getRed(&rr, green: &rg, blue: &rb, alpha: &ra)
    return abs(lr - rr) <= tolerance && abs(lg - rg) <= tolerance && abs(lb - rb) <= tolerance
}

/// Lets a test change the URL of a mounted wrapper, and redraw it without changing anything it
/// reads (`redraw()` re-evaluates the host's body, so the wrapper is rebuilt with the same input).
final class MediaModel: ObservableObject {
    @Published var url: String
    @Published private(set) var redraws = 0

    init(url: String) { self.url = url }

    func redraw() { redraws += 1 }
}

/// Small pictures and animations served from the fake origin, so the suites need no extra files.
enum MediaFixtures {
    static let blurHash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj"

    /// The Test Kit files the media goldens are built from (`testkit/mock-server/assets/media/`),
    /// as the catalog `testkit/contracts/media-goldens.md` names them.
    static func asset(_ name: String) -> Data {
        guard let data = try? testkitAsset(name) else {
            preconditionFailure("Test Kit asset \(name) not found")
        }
        return data
    }

    /// Four coloured quadrants in a black frame: cropping, centring and stretching are visible.
    static var quadrants: Data { asset("media/quadrants.png") }
    /// A PNG with transparent areas, so the page must show through a loaded picture.
    static var transparentFrame: Data { asset("media/transparent-frame.png") }
    /// A two-frame GIF, red then blue, one second each.
    static var twoFrames: Data { asset("media/two-frames.gif") }
    /// The quadrants as a static WebP.
    static var quadrantsWebP: Data { asset("media/quadrants.webp") }
    /// A 100x100 Lottie, 60 frames at 30 fps: an orange square slides from left to right.
    static var marker: Data { asset("media/marker.json") }

    /// The catalog's tint, `#E91E63`.
    static let tint = Color(red: 0xE9 / 255, green: 0x1E / 255, blue: 0x63 / 255)

    /// The bytes of a GIF header followed by nothing a decoder can read.
    static let brokenGIF = Data("GIF89a-this-is-not-an-image".utf8)

    /// A page that is not a picture, as an error page served with a 200.
    static let htmlPage = Data("<html><body><h1>Sign in to continue</h1></body></html>".utf8)

    /// Text that looks like an SVG that was cut off.
    static let brokenSVG = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="120" height="120"><rect x="#.utf8)

    /// A short variant of `marker.json` for the tests that need the playhead to reach the end quickly
    /// (not a golden). A 100x100 animation: a blue ground, a white disc and an orange square that slides from the
    /// left to the right over `frames` frames at 30 fps. At frame 0 the square is at the left, at
    /// the middle of the animation it is at the centre. The disc runs off the top and bottom of a
    /// 240x120 cover crop and stretches into an ellipse when filled.
    static func markerAnimation(frames: Int) -> Data {
        let still = #"{"a":0,"k":[0,0,0]}"#
        func layer(index: Int, name: String, position: String, shape: String, color: String) -> String {
            #"""
            {"ddd":0,"ind":\#(index),"ty":4,"nm":"\#(name)","sr":1,"ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":\#(position),"a":\#(still),"s":{"a":0,"k":[100,100,100]}},"ao":0,"shapes":[{"ty":"gr","it":[\#(shape),{"ty":"fl","c":{"a":0,"k":\#(color)},"o":{"a":0,"k":100},"r":1},{"ty":"tr","p":{"a":0,"k":[0,0]},"a":{"a":0,"k":[0,0]},"s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}}]}],"ip":0,"op":\#(frames),"st":0,"bm":0}
            """#
        }
        let slide =
            #"{"a":1,"k":[{"t":0,"s":[15,35,0],"i":{"x":[1],"y":[1]},"o":{"x":[0],"y":[0]}},{"t":\#(frames),"s":[85,35,0]}]}"#
        let centre = #"{"a":0,"k":[50,50,0]}"#
        let square = layer(
            index: 1, name: "square", position: slide,
            shape: #"{"ty":"rc","d":1,"s":{"a":0,"k":[16,16]},"p":{"a":0,"k":[0,0]},"r":{"a":0,"k":0}}"#,
            color: "[1,0.6,0,1]")
        let disc = layer(
            index: 2, name: "disc", position: centre,
            shape: #"{"ty":"el","d":1,"s":{"a":0,"k":[60,60]},"p":{"a":0,"k":[0,0]}}"#,
            color: "[1,1,1,1]")
        let ground = layer(
            index: 3, name: "ground", position: centre,
            shape: #"{"ty":"rc","d":1,"s":{"a":0,"k":[100,100]},"p":{"a":0,"k":[0,0]},"r":{"a":0,"k":0}}"#,
            color: "[0.15,0.39,0.92,1]")
        return Data(
            #"{"v":"5.7.4","fr":30,"ip":0,"op":\#(frames),"w":100,"h":100,"nm":"marker","ddd":0,"assets":[],"layers":[\#(square),\#(disc),\#(ground)]}"#
                .utf8)
    }

    /// A `.lottie` archive that lists an animation it does not contain (no `animations/` folder).
    static let dotLottieWithoutAnimations = Data(
        base64Encoded:
            "UEsDBBQAAAAIAE29ZF08yhboRgAAAE0AAAANAAAAbWFuaWZlc3QuanNvbqtWKkstKs7Mz1OyUlAyVNJRUEpPzUstSizJLwKJpGSmZybqlqQWl4CkEvMycxNLgIqLgXLR1UqZKSA1uYlF2alFSrWxtQBQSwECFAMUAAAACABNvWRdPMoW6EYAAABNAAAADQAAAAAAAAAAAAAAgAEAAAAAbWFuaWZlc3QuanNvblBLBQYAAAAAAQABADsAAABxAAAAAAA="
    )!
}

extension MediaStage {
    /// An image on the stage.
    @MainActor
    static func image(
        url: String, fit: MediaFit = .cover, blurHash: String? = nil, tintColor: Color? = nil,
        focalX: CGFloat = 0.5, focalY: CGFloat = 0.5, zoom: CGFloat = 1,
        onSuccess: (() -> Void)? = nil, onFailure: (() -> Void)? = nil
    ) -> UIWindow {
        mount(
            MediaImage(
                url: url, fit: fit, blurHash: blurHash, tintColor: tintColor, focalX: focalX,
                focalY: focalY, zoom: zoom, onSuccess: onSuccess, onFailure: onFailure))
    }

    /// An animation on the stage.
    @MainActor
    static func lottie(
        url: String, fit: MediaFit = .cover, blurHash: String? = nil, loop: Bool = true,
        autoplay: Bool = true, freezeAt: CGFloat? = nil
    ) -> UIWindow {
        mount(
            MediaLottie(
                url: url, fit: fit, blurHash: blurHash, loop: loop, autoplay: autoplay,
                freezeAt: freezeAt))
    }
}

extension MediaStage {
    /// Every Lottie animation view on the stage.
    @MainActor
    static func lottieViews(in window: UIWindow) -> [LottieAnimationView] {
        var found: [LottieAnimationView] = []
        func walk(_ view: UIView) {
            if let lottie = view as? LottieAnimationView { found.append(lottie) }
            view.subviews.forEach(walk)
        }
        if let root = window.rootViewController?.view { walk(root) }
        return found
    }

    /// The animation view once it holds a parsed animation.
    @MainActor
    static func animationView(in window: UIWindow) async -> LottieAnimationView? {
        _ = await waitUntilMedia { lottieViews(in: window).first?.animation != nil }
        ComponentTestHost.drainRunLoop(for: 0.1)
        return lottieViews(in: window).first(where: { $0.animation != nil })
    }

    /// Counts the loads the Lottie loader finishes, so a test can wait for a load that is meant to
    /// report nothing.
    @MainActor
    static func countLottieLoads() -> CallCount {
        let finished = CallCount()
        MediaServices.override(loadLottie: { url in
            let loaded = await MediaServices.sdk.loadLottie(url)
            await MainActor.run { finished.value += 1 }
            return loaded
        })
        return finished
    }
}
