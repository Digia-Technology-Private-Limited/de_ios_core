import AVFoundation
import Foundation

// MARK: - Streaming through a forced content type (ExoPlayer parity)

/// Builds AVURLAssets that stream remote videos whose HTTP `Content-Type` isn't
/// a video MIME type.
///
/// AVPlayer trusts the server's `Content-Type` to decide an asset's format, so a
/// host like `raw.githubusercontent.com` — which serves `.mp4` as
/// `application/octet-stream` with `X-Content-Type-Options: nosniff` — makes
/// AVFoundation refuse to play, even though the same URL plays on Android.
/// Android's ExoPlayer ignores `Content-Type` and sniffs the container instead.
///
/// To match ExoPlayer we route the asset through an
/// `AVAssetResourceLoaderDelegate`: it streams the bytes via HTTP range requests
/// (no full pre-download) and reports a forced, extension-derived content type
/// to AVFoundation. For http(s) URLs that already serve a correct video type
/// this is transparent; non-http(s) URLs (e.g. local files) are returned as-is.
enum DigiaVideoStreaming {
    // Only used for its stable address as an associated-object key; never read
    // or mutated as a value, so unchecked concurrency access is safe.
    nonisolated(unsafe) private static var delegateKey: UInt8 = 0

    static func makeAsset(for url: URL) -> AVURLAsset {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return AVURLAsset(url: url)
        }

        // Swap the scheme to a custom one so AVFoundation hands all loading to
        // our delegate instead of trying (and failing) to play it directly.
        components.scheme = DigiaStreamingResourceLoaderDelegate.scheme
        guard let proxyURL = components.url else { return AVURLAsset(url: url) }

        let asset = AVURLAsset(url: proxyURL)
        let delegate = DigiaStreamingResourceLoaderDelegate(originalURL: url)
        asset.resourceLoader.setDelegate(delegate, queue: DispatchQueue(label: "tech.digia.video.resourceloader"))
        // `setDelegate` does not retain the delegate, so tie its lifetime to the
        // asset's.
        objc_setAssociatedObject(asset, &delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return asset
    }
}

/// Streams a remote video via HTTP byte-range requests and reports a forced
/// content type, so AVPlayer plays sources whose `Content-Type` isn't a video
/// MIME type. Mirrors Android's ExoPlayer (container sniffing + progressive
/// streaming). See `DigiaVideoStreaming`.
final class DigiaStreamingResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    static let scheme = "digiastream"

    private let originalURL: URL
    private let contentTypeUTI: String
    private let session = URLSession(configuration: .default)

    init(originalURL: URL) {
        self.originalURL = originalURL
        switch originalURL.pathExtension.lowercased() {
        case "mov": contentTypeUTI = "com.apple.quicktime-movie"
        case "m4v": contentTypeUTI = "com.apple.m4v-video"
        default: contentTypeUTI = "public.mpeg-4"
        }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        var request = URLRequest(url: originalURL)
        if let dataRequest = loadingRequest.dataRequest {
            let start = dataRequest.requestedOffset
            if dataRequest.requestsAllDataToEndOfResource {
                request.setValue("bytes=\(start)-", forHTTPHeaderField: "Range")
            } else {
                let end = start + Int64(dataRequest.requestedLength) - 1
                request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            }
        }

        let task = session.dataTask(with: request) { [contentTypeUTI] data, response, error in
            if let error {
                loadingRequest.finishLoading(with: error)
                return
            }
            if let info = loadingRequest.contentInformationRequest, let response {
                info.contentType = contentTypeUTI
                info.isByteRangeAccessSupported = true
                info.contentLength = Self.totalLength(from: response)
            }
            if let dataRequest = loadingRequest.dataRequest, let data {
                dataRequest.respond(with: data)
            }
            loadingRequest.finishLoading()
        }
        task.resume()
        return true
    }

    private static func totalLength(from response: URLResponse) -> Int64 {
        // For a 206 response, derive the full length from "Content-Range:
        // bytes a-b/TOTAL"; otherwise fall back to the response length.
        if let http = response as? HTTPURLResponse,
           let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
           let totalPart = contentRange.split(separator: "/").last,
           let total = Int64(totalPart) {
            return total
        }
        return response.expectedContentLength
    }
}

struct DigiaVideoPlaybackBundle {
    let player: AVPlayer
    let looper: AVPlayerLooper?

    static func make(url: URL, looping: Bool) -> DigiaVideoPlaybackBundle {
        make(asset: DigiaVideoStreaming.makeAsset(for: url), looping: looping)
    }

    static func make(asset: AVURLAsset, looping: Bool) -> DigiaVideoPlaybackBundle {
        let item = AVPlayerItem(asset: asset)
        if looping {
            let queuePlayer = AVQueuePlayer(playerItem: item)
            let looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
            return DigiaVideoPlaybackBundle(player: queuePlayer, looper: looper)
        }
        return DigiaVideoPlaybackBundle(player: AVPlayer(playerItem: item), looper: nil)
    }
}
