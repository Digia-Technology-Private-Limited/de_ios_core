import Foundation
import SwiftUI

internal import SDWebImageSwiftUI

/// The media layer's services (D17): the pool-lease source, the range-cache
/// store handle, the image loader and the health reporter the wrappers read,
/// supplied through the environment by the SDK instead of reaching for its
/// globals — so tests provide fakes without touching SDK state.
///
/// Lifetime is unchanged: the instance is created by the SDK and process-wide,
/// owned by the SDK — the pool rides the services container's video pool (one
/// per SDK initialization, itself the process singleton; released on teardown,
/// which also covers SDK re-init) and the store is the process-wide shared
/// registry (folder-scoped, outliving any single services graph). Non-view code
/// (`MediaVideoState`, prefetch drivers) receives its services directly
/// instead of reading the environment.
struct MediaServices: @unchecked Sendable {
    /// Borrows pooled players; nil when the SDK is not initialized (a keyed
    /// showing degrades to its still or its owned fallback — never a throw).
    /// Read on the main actor only: the SDK graph it fronts is main-actor
    /// owned, and every reader (views, video state) is main-actor bound.
    var pool: () -> VideoPlayerPool?
    /// The range-cache store video warms land in; nil degrades to the
    /// process-wide shared store, never a throw.
    var store: @Sendable () -> MediaRangeCacheStore?
    /// Image transport tests inject; production leaves nil for the shared
    /// SDWebImage path (the same manager `MediaImage` rendered through before).
    var imageLoader: (any SDImageLoader)?
    /// Health hook: (campaignKey, kind, cause). A nil campaignKey drops the
    /// event, matching what `reportMediaLoadFailed` already does for a nil key.
    var reportHealth: @Sendable (String?, HealthMediaKind, String?) -> Void

    /// No SDK behind it (previews, unit tests that only need the shape):
    /// every provider degrades, health is dropped. Never reads SDK globals,
    /// so a test using this can never observe SDK state.
    static var unconfigured: MediaServices {
        MediaServices(
            pool: { nil },
            store: { nil },
            imageLoader: nil,
            reportHealth: { _, _, _ in }
        )
    }
}

struct MediaServicesKey: EnvironmentKey {
    /// The SDK-backed services (built in `SDKServices.swift`, which owns the
    /// SDK wiring): hosts that provide nothing explicit behave exactly as
    /// before, and tests override with fakes through this same key.
    static let defaultValue = MediaServices.sdkDefault()
}

extension EnvironmentValues {
    var mediaServices: MediaServices {
        get { self[MediaServicesKey.self] }
        set { self[MediaServicesKey.self] = newValue }
    }
}
