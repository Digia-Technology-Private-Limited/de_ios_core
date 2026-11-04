import SwiftUI

internal import Lottie

/// What the media wrappers read from the SwiftUI environment: the health reporter and the Lottie
/// loader. The defaults front the SDK's own `reportMediaLoadFailed` and `loadLottieSource`; tests
/// supply a recording reporter or a scripted loader without touching SDK state. Images load
/// through the shared SDWebImage downloader, so there is no image loader here.
struct MediaServices: Sendable {
    /// Reports a media content fault: (campaign key, kind, cause). A nil key drops it.
    var reportHealth: @Sendable (String?, HealthMediaKind, String) -> Void
    /// Loads a Lottie animation; on failure, the health cause when the author can fix it.
    var loadLottie: @Sendable (URL) async -> (source: LottieAnimationSource?, failureCause: String?)

    static let sdk = MediaServices(
        reportHealth: { campaignKey, kind, cause in
            reportMediaLoadFailed(kind, cause: cause, campaignKey: campaignKey)
        },
        loadLottie: { await loadLottieSource($0) }
    )
}

private struct MediaServicesKey: EnvironmentKey {
    static let defaultValue = MediaServices.sdk
}

extension EnvironmentValues {
    var mediaServices: MediaServices {
        get { self[MediaServicesKey.self] }
        set { self[MediaServicesKey.self] = newValue }
    }
}
