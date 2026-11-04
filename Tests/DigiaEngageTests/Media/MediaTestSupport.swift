import Foundation
import SDWebImage
import SwiftUI
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
    }

    static let host = "media-fake.origin.test"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [URL: Reply] = [:]
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

    static func totalRequestCount() -> Int {
        lock.withLock { log.count }
    }

    static func reset() {
        lock.withLock {
            replies = [:]
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

    override func startLoading() {
        guard let url = request.url else { return }
        let isHeld = Self.lock.withLock { () -> Bool in
            Self.log.append(Request(url: url, userAgent: request.value(forHTTPHeaderField: "User-Agent")))
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
        switch Self.lock.withLock({ Self.replies[url] }) ?? .fail(.notConnectedToInternet) {
        case let .status(code, body):
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

/// Records every health report off the main actor: the recording reporter the wrappers read
/// from `MediaServices`.
final class HealthRecorder: @unchecked Sendable {
    struct Record: Equatable {
        let campaignKey: String?
        let kind: HealthMediaKind
        let cause: String
    }

    private let lock = NSLock()
    private var records: [Record] = []

    var all: [Record] { lock.withLock { records } }

    var services: MediaServices {
        MediaServices { [self] key, kind, cause in
            lock.withLock { records.append(Record(campaignKey: key, kind: kind, cause: cause)) }
        }
    }
}

struct RGB: Equatable {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
}

/// The rendered center pixel, for asserting what the user would see without goldens.
func centerPixel(of image: UIImage) -> RGB? {
    pixel(of: image, atX: 0.5, y: 0.5)
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

/// The rendered pixel at a fraction of the image's width and height (0...1).
func pixel(of image: UIImage, atX fx: CGFloat, y fy: CGFloat) -> RGB? {
    guard let cgImage = image.cgImage else { return nil }
    let x = min(cgImage.width - 1, Int(CGFloat(cgImage.width) * fx))
    let y = min(cgImage.height - 1, Int(CGFloat(cgImage.height) * fy))
    guard let crop = cgImage.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
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
