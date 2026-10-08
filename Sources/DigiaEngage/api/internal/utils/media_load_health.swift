import AVFoundation
import Foundation

internal import Lottie
internal import SDWebImageSwiftUI

private let log = DigiaLogger()

/// The `media_kind` wire value of `media_load_failed`, mapped explicitly.
enum HealthMediaKind: String {
    case image, lottie, video
}

/// Reports a media content fault. A `nil` cause is a network or server fault, which is not reported.
func reportMediaLoadFailed(_ kind: HealthMediaKind, cause: String?, campaignKey: String?) {
    guard let cause else { return }
    log.e(
        "Media failed to load (media_kind=\(kind.rawValue), cause=\(cause))",
        campaign: campaignKey,
        stage: .render,
        reason: TimelineReason.mediaLoadFailed,
        extras: ["media_kind": kind.rawValue, "cause": cause]
    )
}

/// The cause for a download that returned no usable media: a 4xx, or a 2xx that did not decode.
func mediaFailureCause(httpStatus: Int?) -> String? {
    switch httpStatus {
    case (400..<500)?: "http_4xx"
    case (200..<300)?: "decode"
    default: nil
    }
}

/// The cause for an SDWebImage load error.
func mediaFailureCause(imageError: Error) -> String? {
    let error = imageError as NSError
    guard error.domain == SDWebImageErrorDomain else { return nil }
    switch SDWebImageError.Code(rawValue: error.code) {
    case .invalidURL: return "invalid_url"
    case .badImageData: return "decode"
    case .invalidDownloadStatusCode:
        return mediaFailureCause(httpStatus: error.userInfo[SDWebImageErrorDownloadStatusCodeKey] as? Int)
    default: return nil
    }
}

/// The cause for a failed `AVPlayerItem`, from its HTTP error log or its decode error.
func mediaFailureCause(playerItem: AVPlayerItem) -> String? {
    if let status = playerItem.errorLog()?.events.last?.errorStatusCode, (400..<500).contains(status) {
        return "http_4xx"
    }
    switch (playerItem.error as? AVError)?.code {
    case .decodeFailed?, .fileFormatNotRecognized?, .failedToParse?: return "decode"
    default: return nil
    }
}

/// Loads a remote Lottie or dotLottie file through Lottie's own cache.
/// On failure, returns the health cause from the download's HTTP status.
func loadLottieSource(_ url: URL) async -> (source: LottieAnimationSource?, failureCause: String?) {
    let session = StatusRecordingLottieSession()
    if url.pathExtension.lowercased() == "lottie" {
        if let file = try? await DotLottieFile.loadedFrom(url: url, session: session) {
            return (file.animationSource, nil)
        }
    } else if let animation = await LottieAnimation.loadedFrom(url: url, session: session) {
        return (animation.animationSource, nil)
    }
    return (nil, mediaFailureCause(httpStatus: session.statusCode))
}

/// Records the HTTP status of the one download Lottie makes through it.
private final class StatusRecordingLottieSession: LottieURLSession, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: Int?

    var statusCode: Int? { lock.withLock { recorded } }

    func lottieDataTask(
        with url: URL,
        completionHandler: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void
    ) -> URLSessionDataTask? {
        URLSession.shared.dataTask(with: url) { data, response, error in
            self.lock.withLock { self.recorded = (response as? HTTPURLResponse)?.statusCode }
            completionHandler(data, response, error)
        }
    }
}
