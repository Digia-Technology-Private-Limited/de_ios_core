import Foundation
@testable import DigiaEngage

/// Serves image URLs so anchorless crops and other `URLSession` image loads
/// never hit the real network in tests, like the Android (`TestkitImages`
/// stand-in) and Flutter (`installYamlMediaStandIn`) drivers do:
/// - `testkit.local/assets/*` is served from the Test Kit's mock-server
///   directory on disk, so an anchorless crop can point at a controlled
///   per-format file (crop_stripes.png/.webp/.svg) instead of the strawberry
///   stand-in. A Test Kit asset with no file behind it falls back to the
///   strawberry for raster images (as Flutter and Android do), and 404s
///   otherwise, as the server would, so unloadable crops still drop.
/// - Every other external http(s) image URL (the fixtures' picsum and CDN
///   pictures) is answered with the Test Kit's `strawberry.jpg`, so a golden
///   shows how the picture is fitted instead of a loading placeholder.
/// - Reserved hosts (`.invalid`, `cdn.example.com`) fail, as the degradation
///   tests assert. API traffic (`app.digia.tech`, `dev.digia.tech`) is never
///   intercepted: the driver's network is injected as `overrideForTesting`,
///   not through image loading.
///
/// Fixture `{{TESTKIT_ASSET_ORIGIN}}` placeholders resolve to `file://` URLs
/// that never reach here. Installed once per process from `bootForTest`, like
/// the image stub loader.
final class YamlTestkitURLProtocol: URLProtocol {
    private static var installed = false
    private static var strawberryData: Data?

    private static let rasterExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "avif",
    ]

    static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        if let workspace = FixtureLoader.workspaceURL(),
           let data = try? Data(contentsOf: workspace
               .appendingPathComponent("testkit/mock-server/assets/strawberry.jpg"))
        {
            strawberryData = data
        }
        URLProtocol.registerClass(YamlTestkitURLProtocol.self)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url,
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host?.lowercased()
        else { return false }
        // Never API traffic: those have their own fakes.
        if host == "app.digia.tech" || host == "dev.digia.tech" { return false }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else { return }
        let host = url.host?.lowercased() ?? ""
        // Reserved names that cannot resolve (RFC 2606) fail, as do the
        // degradation fixtures' example CDN crops: the guide drops them.
        if host.hasSuffix(".invalid") || host == "cdn.example.com" {
            answer(status: 404, data: Data())
            return
        }
        if host.hasSuffix("testkit.local"), url.path.hasPrefix("/assets/") {
            let relative = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !relative.isEmpty, !relative.contains(".."),
               let file = FixtureLoader.workspaceURL()?
                   .appendingPathComponent("testkit/mock-server")
                   .appendingPathComponent(relative),
               let data = try? Data(contentsOf: file)
            {
                answer(status: 200, data: data)
                return
            }
            // A Test Kit asset the mock server does not ship falls back to
            // the strawberry for raster images, as Flutter and Android do.
            if Self.isRasterImage(url), let strawberry = Self.strawberryData {
                answer(status: 200, data: strawberry)
            } else {
                answer(status: 404, data: Data())
            }
            return
        }
        // Every other external http(s) URL serves the strawberry stand-in for
        // images, mirroring Android's stand-in and Flutter's; anything else
        // 404s, as the server would.
        if Self.isImageURL(url), let strawberry = Self.strawberryData {
            answer(status: 200, data: strawberry)
        } else {
            answer(status: 404, data: Data())
        }
    }

    override func stopLoading() {}

    private func answer(status: Int, data: Data) {
        guard let url = request.url else { return }
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func isRasterImage(_ url: URL) -> Bool {
        rasterExtensions.contains(url.pathExtension.lowercased())
    }

    private static func isImageURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return rasterExtensions.contains(ext) || ext == "svg"
    }
}
