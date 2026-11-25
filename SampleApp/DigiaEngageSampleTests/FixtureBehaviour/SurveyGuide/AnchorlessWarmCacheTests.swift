import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import DigiaEngage

extension HostedUITests {
/// An anchorless guide's picture when it is already in the image cache. The guide keeps its whole
/// layer hidden until the picture reports success. A plain bitmap in memory is drawn by `MediaImage`
/// directly and reports from a task; an SVG or an animated GIF still goes through WebImage, which
/// completes such a load at once, so `onSuccess` ran inside the guide's own view update. The
/// guide's `imageLoaded` write was dropped there, the layer stayed hidden and the step was dropped
/// after its 3 s limit. Other surfaces draw such a picture fine: they do not gate on `onSuccess`.
///
/// Two ways a picture is already cached: the guide is shown a second time in the same session, and
/// the next step's picture, which the guide warms while the current step shows.
///
/// The pictures are solid magenta (SVG, and the GIF's first frame, with yellow for its second) so
/// "drawn" is a share of the window in that colour, not a reading of the guide's state. Every URL
/// is this run's own: the image cache is on disk and outlives the process, and a picture left by an
/// earlier run would make the first show warm too.
@Suite("Anchorless guide: pictures already in the image cache", .serialized,
       .tags(.guide, .media, .behaviour, .integration))
@MainActor
struct AnchorlessWarmCacheTests {

    /// `svg` and `gif` are the pictures the memory-cache fast path does not draw; `png` is only the
    /// filler for step 1.
    private enum Format: String {
        case png, svg, gif
    }

    // Fails if: Sources/DigiaEngage/api/widgets/guide_overlay_view.swift `GuideStepOverlay`
    // `onSuccess: { DispatchQueue.main.async { imageLoaded = true } }` -> `onSuccess: { imageLoaded = true }`:
    // the second show never draws and the guide is dropped.
    @Test("a picture shown a second time in the session draws again", arguments: ["svg", "gif"])
    func shownAgainDraws(name: String) async throws {
        let format = try #require(Format(rawValue: name))
        let url = Self.url(format, "again")

        #expect(try await showAndWait(url, format), "the first show (cold cache) draws")
        #expect(try await showAndWait(url, format), "the second show (picture in memory) draws")
    }

    // Fails if: the same line. The prefetch the guide runs for the next step stores the picture in
    // memory as well as on disk, so step 2 is a warm load.
    @Test("the next step's picture, warmed while step 1 shows, draws when step 2 starts", arguments: ["svg", "gif"])
    func prefetchedNextStepDraws(name: String) async throws {
        let format = try #require(Format(rawValue: name))
        let showing = try showGuide([Self.url(.png, "filler-\(name)"), Self.url(format, "next")])
        defer { showing.end() }

        try #require(try await waitForPicture(.png, in: showing.window), "step 1 (the PNG filler) draws")
        // Step 1 has been up; the guide has been warming step 2's picture meanwhile.
        try await Task.sleep(nanoseconds: 1_200_000_000)
        SDKInstance.shared.advanceGuide()

        #expect(try await waitForPicture(format, in: showing.window), "step 2 draws")
    }

    // MARK: - Showing the guide

    private func showAndWait(_ url: String, _ format: Format) async throws -> Bool {
        let showing = try showGuide([url])
        defer { showing.end() }
        return try await waitForPicture(format, in: showing.window)
    }

    private func showGuide(_ urls: [String]) throws -> AnchorlessGuideHost.Showing {
        let campaign = try #require(
            try CampaignModel.fromJson(Self.campaign(urls), devicePlatform: "ios"), "The guide must decode")
        return try AnchorlessGuideHost.show(campaign, anchors: false) { Self.serve($0) }
    }

    /// Polls the window until the picture's colour fills a share of it, for at most 5 s (the guide
    /// itself gives up on a picture at 3 s).
    private func waitForPicture(_ format: Format, in window: UIWindow) async throws -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < 5 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let image = ComponentTestHost.renderImage(of: window)
            if Self.share(of: image, matching: { Self.isPicture(format, $0, $1, $2) }) > 0.03 { return true }
        }
        return false
    }

    // MARK: - Pictures

    private static let run = UUID().uuidString.prefix(8).lowercased()

    private static func url(_ format: Format, _ tag: String) -> String {
        "https://warm.test/\(run)-\(tag).\(format.rawValue)"
    }

    private static func isPicture(_ format: Format, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
        switch format {
        case .png: r < 70 && g > 200 && b > 200
        case .svg: r > 200 && g < 70 && b > 200
        case .gif: (r > 200 && g < 70 && b > 200) || (r > 200 && g > 200 && b < 70)
        }
    }

    private static func serve(_ url: URL) -> Data? {
        guard url.host == "warm.test", let format = Format(rawValue: url.pathExtension) else { return nil }
        switch format {
        case .png:
            return solid(UIColor(red: 0, green: 1, blue: 1, alpha: 1)).pngData()
        case .svg:
            return Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="300" height="300" viewBox="0 0 300 300">\
            <rect width="300" height="300" fill="#ff00ff"/></svg>
            """.utf8)
        case .gif:
            let frames = [UIColor(red: 1, green: 0, blue: 1, alpha: 1), UIColor(red: 1, green: 1, blue: 0, alpha: 1)]
            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                out, UTType.gif.identifier as CFString, frames.count, nil) else { return nil }
            CGImageDestinationSetProperties(destination, [
                kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0],
            ] as CFDictionary)
            for color in frames {
                guard let image = solid(color).cgImage else { return nil }
                CGImageDestinationAddImage(destination, image, [
                    kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: 0.4],
                ] as CFDictionary)
            }
            CGImageDestinationFinalize(destination)
            return out as Data
        }
    }

    private static func solid(_ color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
        }
    }

    /// The share of the image's pixels whose colour passes [matching].
    private static func share(of image: UIImage, matching: (UInt8, UInt8, UInt8) -> Bool) -> Double {
        guard let cgImage = image.cgImage else { return 0 }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var hits = 0
        for index in stride(from: 0, to: pixels.count, by: 4)
        where matching(pixels[index], pixels[index + 1], pixels[index + 2]) {
            hits += 1
        }
        return Double(hits) / Double(width * height)
    }

    // MARK: - The guide

    /// An anchorless spotlight whose steps each show one picture in a 300x100 cutout.
    private static func campaign(_ urls: [String]) -> [String: Any] {
        [
            "id": "id-anchorless-warm-cache",
            "campaignKey": "anchorless_warm_cache",
            "campaignType": "guide",
            "status": "active",
            "templateConfig": [
                "templateType": "spotlight",
                "designWidth": 360,
                "steps": urls.enumerated().map { index, url -> [String: Any] in
                    [
                        "id": "step_\(index)",
                        "stepId": "step_\(index)",
                        "sequenceOrder": index,
                        "layoutMode": "canvas",
                        "highlightShape": "rect",
                        "target": [
                            "type": "anchorless",
                            "version": 1,
                            "pageKey": "home",
                            "imageUrl": url,
                            "horizontal": ["frame": "window", "rule": ["kind": "centered", "width": 300.0]],
                            "vertical": [
                                "frame": "appContent",
                                "rule": ["kind": "topFixed", "topOffset": 150.0, "height": 100.0],
                            ],
                        ],
                        "canvas": [
                            "version": 2,
                            "canvasWidth": 280,
                            "canvasHeight": 90,
                            "children": [Any](),
                        ],
                    ]
                },
                "variables": [Any](),
            ],
        ]
    }
}
}
