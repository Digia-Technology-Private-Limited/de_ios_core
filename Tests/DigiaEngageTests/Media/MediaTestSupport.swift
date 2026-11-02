import Foundation
import SDWebImage
import SwiftUI
import UIKit

@testable import DigiaEngage

/// The fake image loader for the `MediaImage` suite. `MediaImage` renders through the real
/// SDWebImage stack (`WebImage` → `SDWebImageManager.shared` → memory/disk cache), and only the
/// transport is faked: this loader is appended to `SDImageLoadersManager.shared` (highest
/// priority) and answers for its own host, while every other host falls through to the real
/// downloader. That keeps production and test on the same load path — the fake counts requests,
/// scripts replies and hang/error/image outcomes, but the caching, decoding and view updates
/// under test are all SDWebImage's own.
final class FakeImageLoader: NSObject, SDImageLoader {
    enum Reply: Sendable {
        /// Never answers: the load stays in flight until the view goes away.
        case hang
        /// Answers with a decoded image, as a finished fetch would.
        case image(UIImage)
        /// Fails the load with this error.
        case error(NSError)
    }

    static let host = "media-fake.origin.test"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [URL: Reply] = [:]
    nonisolated(unsafe) private static var counts: [URL: Int] = [:]
    nonisolated(unsafe) private static var total = 0

    nonisolated(unsafe) static let shared = FakeImageLoader()

    /// A fresh URL on the fake host, so request counts never leak across tests.
    static func url(_ name: String) -> URL {
        URL(string: "https://\(host)/\(UUID().uuidString)/\(name)")!
    }

    /// An SDWebImage-flavored HTTP error, so `mediaFailureCause(imageError:)` maps it.
    static func httpError(status: Int) -> NSError {
        NSError(
            domain: SDWebImageErrorDomain,
            code: SDWebImageError.Code.invalidDownloadStatusCode.rawValue,
            userInfo: [SDWebImageErrorDownloadStatusCodeKey: status]
        )
    }

    static func set(_ reply: Reply, for url: URL) {
        lock.withLock { replies[url] = reply }
    }

    static func requestCount(for url: URL) -> Int {
        lock.withLock { counts[url, default: 0] }
    }

    static func totalRequestCount() -> Int {
        lock.withLock { total }
    }

    static func reset() {
        lock.withLock {
            replies = [:]
            counts = [:]
            total = 0
        }
    }

    func canRequestImage(for url: URL?) -> Bool {
        url?.host == Self.host
    }

    func shouldBlockFailedURL(with url: URL, error: any Error) -> Bool { false }

    func requestImage(
        with url: URL?, options: SDWebImageOptions, context: [SDWebImageContextOption: Any]?,
        progress: SDImageLoaderProgressBlock?, completed: SDImageLoaderCompletedBlock?
    ) -> (any SDWebImageOperation)? {
        guard let url, let completed else { return nil }
        Self.lock.withLock {
            Self.counts[url, default: 0] += 1
            Self.total += 1
        }
        let reply = Self.lock.withLock { Self.replies[url] }
            ?? .error(URLError(.notConnectedToInternet) as NSError)
        let operation = FakeImageOperation()
        let finished = SendableCompleted(block: completed)
        switch reply {
        case .hang:
            break
        case let .image(uiImage):
            let image = SendableImage(value: uiImage)
            DispatchQueue.main.async {
                if !operation.isCancelled { finished.call(image.value, nil, nil, true) }
            }
        case let .error(error):
            DispatchQueue.main.async {
                if !operation.isCancelled { finished.call(nil, nil, error, true) }
            }
        }
        return operation
    }
}

private final class FakeImageOperation: NSObject, SDWebImageOperation, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var isCancelled: Bool { lock.withLock { stopped } }

    func cancel() { lock.withLock { stopped = true } }
}

/// ObjC blocks are not `Sendable`; this box carries one across queues. The block itself runs
/// on the main queue, like a real fetch completion.
private struct SendableCompleted: @unchecked Sendable {
    let block: SDImageLoaderCompletedBlock

    func call(_ image: UIImage?, _ data: Data?, _ error: NSError?, _ finished: Bool) {
        block(image, data, error, finished)
    }
}

/// `UIImage` is immutable after decoding; this box carries one across queues.
private struct SendableImage: @unchecked Sendable {
    let value: UIImage
}

/// The fake HTTP origin for the `MediaLottie` suite. Lottie downloads through
/// `URLSession.shared` (via `loadLottieSource`), which honors registered protocols — the
/// `MediaFloaterLottieProtocol` precedent. Registered per test on its own host.
final class FakeMediaOrigin: URLProtocol {
    enum Reply: Sendable {
        /// Answers with an HTTP status and body.
        case status(Int, Data)
        /// Fails the load with a transport error.
        case fail(URLError.Code)
    }

    static let host = "media-fake.origin.test"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [URL: Reply] = [:]
    nonisolated(unsafe) private static var total = 0

    /// A fresh URL on the fake host, so request counts never leak across tests.
    static func url(_ name: String) -> URL {
        URL(string: rawURL(name))!
    }

    /// The same, unencoded: use this for template tokens (`{{…}}`), which `URL` would
    /// percent-encode before the wrapper ever sees them — production hands the wrapper the
    /// raw campaign string, encoding included or not.
    static func rawURL(_ name: String) -> String {
        "https://\(host)/\(UUID().uuidString)/\(name)"
    }

    static func install() { URLProtocol.registerClass(FakeMediaOrigin.self) }

    static func uninstall() { URLProtocol.unregisterClass(FakeMediaOrigin.self) }

    static func set(_ reply: Reply, for url: URL) {
        lock.withLock { replies[url] = reply }
    }

    static func totalRequestCount() -> Int {
        lock.withLock { total }
    }

    static func reset() {
        lock.withLock {
            replies = [:]
            total = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var finished = false

    override func startLoading() {
        guard let url = request.url, let client else { return }
        Self.lock.withLock { Self.total += 1 }
        switch Self.lock.withLock({ Self.replies[url] }) ?? .fail(.notConnectedToInternet) {
        case let .status(code, body):
            let response = HTTPURLResponse(
                url: url, statusCode: code, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "\(body.count)"])!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: body)
            client.urlProtocolDidFinishLoading(self)
            finished = true
        case let .fail(code):
            client.urlProtocol(self, didFailWithError: URLError(code))
            finished = true
        }
    }

    override func stopLoading() {
        if !finished { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)) }
        finished = true
    }
}

/// Records failure causes off the main actor, same probe shape as `LottieRuntimeProbe`.
final class CauseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var causes: [String] = []

    var all: [String] { lock.withLock { causes } }

    func record(_ cause: String) { lock.withLock { causes.append(cause) } }
}

struct RGB: Equatable {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
}

/// The rendered center pixel, for asserting what the user would see without goldens. Drawn
/// through a fixed RGBA context so the reader never depends on the source bitmap order.
func centerPixel(of image: UIImage) -> RGB? {
    guard let cgImage = image.cgImage else { return nil }
    let width = cgImage.width
    let height = cgImage.height
    guard width > 0, height > 0 else { return nil }
    guard
        let crop = cgImage.cropping(
            to: CGRect(x: width / 2, y: height / 2, width: 1, height: 1))
    else { return nil }
    var pixels = [UInt8](repeating: 0, count: 4)
    guard
        let context = CGContext(
            data: &pixels, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue)
    else { return nil }
    context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return RGB(
        r: CGFloat(pixels[0]) / 255, g: CGFloat(pixels[1]) / 255, b: CGFloat(pixels[2]) / 255)
}

func pixelsNearly(_ left: RGB, _ right: RGB, tolerance: CGFloat = 0.12) -> Bool {
    abs(left.r - right.r) <= tolerance
        && abs(left.g - right.g) <= tolerance
        && abs(left.b - right.b) <= tolerance
}

/// The center of the decoded BlurHash: what the still layer should show.
func blurCenter(_ hash: String) -> RGB? {
    guard let decoded = BlurHashDecoder.decode(hash, width: 32, height: 32) else { return nil }
    return centerPixel(of: decoded)
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

/// Mounts a 200×200 media view on white, like the canvas renderer suites.
@MainActor
func mountMedia<Content: View>(_ view: Content) -> UIWindow {
    let (window, _) = ComponentTestHost.mount(
        rootView: AnyView(view),
        size: CGSize(width: 200, height: 200),
        backgroundColor: .white
    )
    return window
}

/// The walking helper for "is the spinner up" without pixel-flakiness.
@MainActor
func hasActivityIndicator(in view: UIView) -> Bool {
    var found = false
    func walk(_ current: UIView) {
        if current is UIActivityIndicatorView { found = true; return }
        current.subviews.forEach(walk)
    }
    walk(view)
    return found
}
