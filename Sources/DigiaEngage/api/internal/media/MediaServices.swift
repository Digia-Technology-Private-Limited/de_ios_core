import SwiftUI

/// What the media wrappers read from the SwiftUI environment: the health reporter. The default
/// fronts the SDK's own `reportMediaLoadFailed`; tests supply a recording one without touching
/// SDK state. Images load through the shared SDWebImage downloader, so there is no loader here.
struct MediaServices: Sendable {
    /// Reports a media content fault: (campaign key, kind, cause). A nil key or cause drops it.
    var reportHealth: @Sendable (String?, HealthMediaKind, String?) -> Void

    static let sdk = MediaServices(
        reportHealth: { campaignKey, kind, cause in
            reportMediaLoadFailed(kind, cause: cause, campaignKey: campaignKey)
        }
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
