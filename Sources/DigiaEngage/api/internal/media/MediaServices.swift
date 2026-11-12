import SwiftUI

internal import Lottie

/// The media layer's process-wide services: the health reporter and the Lottie loader every media
/// path reads, so one override reaches all of them. The widgets read them from the SwiftUI
/// environment, whose default is `current`; the floater's Lottie warm-up and the anchorless
/// guide's health report, which have no view, read `current` directly. The defaults front the
/// SDK's own `reportMediaLoadFailed` and `loadLottieSource`; tests replace them with `override`
/// and put the defaults back with `reset`. Images load through the shared SDWebImage downloader,
/// so there is no image loader here.
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

    /// The services in force: the SDK's, unless a test overrode them.
    static var current: MediaServices { store.value }

    /// Replaces the given services for the rest of the process, until `reset()`. Test only.
    static func override(
        reportHealth: (@Sendable (String?, HealthMediaKind, String) -> Void)? = nil,
        loadLottie: (@Sendable (URL) async -> (source: LottieAnimationSource?, failureCause: String?))? = nil
    ) {
        store.update { services in
            if let reportHealth { services.reportHealth = reportHealth }
            if let loadLottie { services.loadLottie = loadLottie }
        }
    }

    /// Puts the SDK's services back. Test only.
    static func reset() {
        store.update { $0 = .sdk }
    }

    private static let store = Store()

    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var services = MediaServices.sdk

        var value: MediaServices { lock.withLock { services } }

        func update(_ change: (inout MediaServices) -> Void) {
            lock.withLock { change(&services) }
        }
    }
}

private struct MediaServicesKey: EnvironmentKey {
    static var defaultValue: MediaServices { MediaServices.current }
}

extension EnvironmentValues {
    var mediaServices: MediaServices {
        get { self[MediaServicesKey.self] }
        set { self[MediaServicesKey.self] = newValue }
    }
}
