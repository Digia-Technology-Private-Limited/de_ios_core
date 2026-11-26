import Foundation
import SDWebImage
import UIKit
@testable import DigiaEngage

/// Serves the Test Kit's media for fixture images, so goldens draw deterministic
/// pixels with no network, like the Android (`TestkitImages` stand-in) and
/// Flutter (`serveTestkitMedia`) drivers do.
///
/// Fixture `{{TESTKIT_ASSET_ORIGIN}}` URLs resolve to `file://` URLs under the
/// mock-server directory. Existing files load straight off disk through
/// SDWebImage's default file handling and never reach here; a Test Kit asset
/// with no file behind it (like the canvas background's `image-1.png`) fails
/// there and the surface draws nothing. Those missing raster files are
/// claimed below and answered with the strawberry, exactly as the Android and
/// Flutter drivers substitute it, so a golden still shows the layout.
/// Every other http(s) image URL (the fixtures' picsum CDN pictures) is
/// answered with the Test Kit's `strawberry.jpg`, so a golden shows how the
/// picture is fitted instead of a loading placeholder — or nothing, when the
/// CDN times out. API traffic never reaches here: the driver's fake network is
/// injected as `overrideForTesting`, not through image loading. Test-only;
/// installed once per process from `bootForTest`.
final class YamlImageStubLoader: NSObject, SDImageLoader {
    private static var installed = false
    private static var strawberryImage: UIImage?
    private static var strawberryData: Data?

    static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        if let workspace = FixtureLoader.workspaceURL(),
           let data = try? Data(contentsOf: workspace
               .appendingPathComponent("testkit/mock-server/assets/strawberry.jpg")),
           let image = UIImage(data: data)
        {
            strawberryImage = image
            strawberryData = data
        }
        SDImageLoadersManager.shared.addLoader(YamlImageStubLoader())
        // SDWebImageManager.shared is born with the plain downloader as its
        // loader, so added loaders are never consulted; the property is
        // publicly readonly, so point it at the loaders manager through KVC
        // (test process only). Every image from here on is offered to the
        // stub above before the real internet.
        SDWebImageManager.shared.setValue(
            SDImageLoadersManager.shared, forKey: "imageLoader")
        // The SDK's pictures load through its own manager (and cache), which fronts the
        // downloader directly, so it gets the same treatment.
        DigiaImagePipeline.imageManager.setValue(
            SDImageLoadersManager.shared, forKey: "imageLoader")
    }

    func canRequestImage(for url: URL?) -> Bool {
        guard let url else { return false }
        // Fixture `file://` URLs (see above) bypass the http(s) branches:
        // SDWebImage's default file handling loads the ones that exist, so
        // only a missing raster Test Kit asset is claimed, for the strawberry
        // fallback below. `URLProtocol`-based fakes never see `file://` URLs
        // either, which is why `YamlTestkitURLProtocol` cannot catch these.
        if url.isFileURL {
            return Self.isMissingTestkitRasterFile(url)
        }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased()
        else { return false }
        // Never API traffic: those have their own fakes.
        if host == "app.digia.tech" { return false }
        // testkit.local/assets/* is served directly from disk below (SDWebImageDownloader's
        // custom URLSession does not inherit URLProtocol.registerClass).
        if host.hasSuffix("testkit.local") {
            return url.path.hasPrefix("/assets/") == true
        }
        // Reserved names that cannot resolve (RFC 2606): fail immediately instead of timing out.
        if host.hasSuffix(".invalid") || host == "cdn.example.com" { return true }
        // Without strawberry data there is nothing deterministic to serve.
        return Self.strawberryImage != nil
    }

    func requestImage(
        with url: URL?,
        options: SDWebImageOptions = [],
        context: [SDWebImageContextOption: Any]? = nil,
        progress progressBlock: SDImageLoaderProgressBlock?,
        completed completedBlock: SDImageLoaderCompletedBlock?
    ) -> SDWebImageOperation? {
        if let url, url.isFileURL {
            if Self.isMissingTestkitRasterFile(url),
               let image = Self.strawberryImage, let data = Self.strawberryData {
                // A Test Kit asset the mock server does not ship falls back
                // to the strawberry for raster images (as Flutter and Android
                // do); anything else fails, as the server would.
                completedBlock?(image, data, nil, true)
            } else {
                completedBlock?(
                    nil, nil,
                    NSError(
                        domain: SDWebImageErrorDomain,
                        code: SDWebImageError.invalidDownloadStatusCode.rawValue,
                        userInfo: [SDWebImageErrorDownloadStatusCodeKey: 404]),
                    true)
            }
            return nil
        }
        let host = url?.host?.lowercased() ?? ""
        if host.hasSuffix(".invalid") || host == "cdn.example.com" {
            completedBlock?(
                nil, nil,
                NSError(
                    domain: SDWebImageErrorDomain,
                    code: SDWebImageError.invalidDownloadStatusCode.rawValue,
                    userInfo: [SDWebImageErrorDownloadStatusCodeKey: 404]),
                true)
            return nil
        }
        if host.hasSuffix("testkit.local"), let url {
            let relative = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !relative.isEmpty, !relative.contains(".."),
               let file = FixtureLoader.workspaceURL()?
                   .appendingPathComponent("testkit/mock-server")
                   .appendingPathComponent(relative),
               let data = try? Data(contentsOf: file),
               let image = SDImageCodersManager.shared.decodedImage(with: data, options: nil) ?? UIImage(data: data)
            {
                completedBlock?(image, data, nil, true)
            } else if Self.isRasterImage(url), let image = Self.strawberryImage, let data = Self.strawberryData {
                // A Test Kit asset the mock server does not ship falls back
                // to the strawberry for raster images (as Flutter and Android
                // do); anything else fails, as the server would.
                completedBlock?(image, data, nil, true)
            } else {
                completedBlock?(
                    nil, nil,
                    NSError(
                        domain: SDWebImageErrorDomain,
                        code: SDWebImageError.invalidDownloadStatusCode.rawValue,
                        userInfo: [SDWebImageErrorDownloadStatusCodeKey: 404]),
                    true)
            }
            return nil
        }
        if let image = Self.strawberryImage, let data = Self.strawberryData {
            completedBlock?(image, data, nil, true)
        } else {
            completedBlock?(
                nil, nil,
                NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable, userInfo: nil),
                true)
        }
        return nil
    }

    func shouldBlockFailedURL(with url: URL, error: Error) -> Bool { false }

    private static let rasterExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "avif",
    ]

    /// A `file://` Test Kit asset with no file behind it and a raster
    /// extension: the canvas background loader (`FocalCanvasImage` through
    /// SDWebImage) reads fixture `file://` URLs straight off disk, so the
    /// mock server's absence never surfaces as http(s) traffic the stub's
    /// `testkit.local` branch or `YamlTestkitURLProtocol` could answer.
    private static func isMissingTestkitRasterFile(_ url: URL) -> Bool {
        guard url.isFileURL, isRasterImage(url),
              let workspace = FixtureLoader.workspaceURL()
        else { return false }
        let assets = workspace
            .appendingPathComponent("testkit/mock-server/assets").standardized.path
        let path = url.standardized.path
        guard path.hasPrefix(assets) else { return false }
        return !FileManager.default.fileExists(atPath: path)
    }

    private static func isRasterImage(_ url: URL) -> Bool {
        rasterExtensions.contains(url.pathExtension.lowercased())
    }
}
