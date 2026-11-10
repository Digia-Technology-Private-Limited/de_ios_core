import SwiftUI
import UIKit

internal import DigiaMediaCache
internal import Lottie

/// The media layer's process-wide services: the health reporter, the Lottie loader and the video
/// range-cache loader every media path reads, so one override reaches all of them. The widgets read them from the SwiftUI
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
    /// The range-cache loader every remote video item reads through. One for the process:
    /// `AVURLAsset` holds its delegate weakly, so it must outlive any view.
    var videoLoader: MediaResourceLoader
    /// The range cache behind `videoLoader`, which `MediaPrefetch` warms.
    var videoStore: MediaRangeCacheStore
    /// The process-wide players keyed `MediaVideo`s lease; its items read through `videoLoader`.
    var videoPool: VideoPlayerPool

    static let sdk: MediaServices = {
        let loader = MediaResourceLoader(store: MediaRangeCacheStore.shared())
        let pool = VideoPlayerPool(
            onCeilingRefused: reportVideoPoolCeiling,
            makeItem: { mediaVideoItem(for: $0, loader: loader) })
        observeMemoryPressure(of: pool)
        return MediaServices(
            reportHealth: { campaignKey, kind, cause in
                reportMediaLoadFailed(kind, cause: cause, campaignKey: campaignKey)
            },
            loadLottie: { await loadLottieSource($0) },
            videoLoader: loader,
            videoStore: MediaRangeCacheStore.shared(),
            videoPool: pool
        )
    }()

    /// The services in force: the SDK's, unless a test overrode them.
    static var current: MediaServices { store.value }

    /// Replaces the given services for the rest of the process, until `reset()`. Test only.
    static func override(
        reportHealth: (@Sendable (String?, HealthMediaKind, String) -> Void)? = nil,
        loadLottie: (@Sendable (URL) async -> (source: LottieAnimationSource?, failureCause: String?))? = nil,
        videoSession: URLSession? = nil,
        videoPool: VideoPlayerPool? = nil
    ) {
        // A fresh cache folder per override, so no test reads another's bytes.
        let videoStore = videoSession.map { session in
            MediaRangeCacheStore(
                folder: FileManager.default.temporaryDirectory
                    .appendingPathComponent("digia-media-video-test-\(UUID().uuidString)", isDirectory: true),
                client: URLSessionRangeFetchClient(session: session))
        }
        store.update { services in
            if let reportHealth { services.reportHealth = reportHealth }
            if let loadLottie { services.loadLottie = loadLottie }
            if let videoStore {
                let loader = MediaResourceLoader(store: videoStore)
                services.videoStore = videoStore
                services.videoLoader = loader
                services.videoPool = VideoPlayerPool(makeItem: { mediaVideoItem(for: $0, loader: loader) })
            }
            if let videoPool { services.videoPool = videoPool }
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

private let mediaServicesLog = DigiaLogger()

/// OD-24: a video on screen got no player because the phone is at its live-player ceiling.
/// Campaignless, so the health sink sends it once per session; it tunes the ceilings. iOS has no
/// media performance class, so it sends "0".
@MainActor
private func reportVideoPoolCeiling() {
    let deviceClass = deviceClassFor(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
    mediaServicesLog.w(
        "Video player ceiling reached; a video shows its still",
        stage: .render,
        reason: TimelineReason.videoPoolCeiling,
        extras: [
            "device_class": "\(deviceClass)",
            "media_performance_class": "0",
            "ceiling": "\(livePlayerCeiling(poolSize: maxPoolPlayers(deviceClass: deviceClass)))",
        ])
}

/// A memory warning or the app entering the background releases idle video players (OD-24).
/// Observed for the process: the SDK's pool lives as long as the process.
private func observeMemoryPressure(of pool: VideoPlayerPool) {
    for name in [UIApplication.didReceiveMemoryWarningNotification, UIApplication.didEnterBackgroundNotification] {
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak pool] _ in
            MainActor.assumeIsolated { pool?.onMemoryPressure() }
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
