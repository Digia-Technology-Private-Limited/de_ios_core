import SwiftUI

/// Where a story viewer reads the slow-network verdict from: the SDK's one shared source
/// (`SDKServices.slowNetworkSource`), so every viewer — inline, canvas, floater — judges the
/// same network and shares one measured throughput. Without an initialized SDK (previews,
/// hosts that never initialized) a single process-wide source stands in; the environment
/// override is the test seam.
enum StorySlowNetwork {
    private static let fallback = PathSlowNetworkSource()

    @MainActor
    static func source(override: (any SlowNetworkSource)?) -> any SlowNetworkSource {
        override ?? SDKInstance.shared.services?.slowNetworkSource ?? fallback
    }
}

private struct StorySlowNetworkKey: EnvironmentKey {
    static let defaultValue: (any SlowNetworkSource)? = nil
}

extension EnvironmentValues {
    /// Replaces the SDK's slow-network source for the viewers below (tests).
    var storySlowNetwork: (any SlowNetworkSource)? {
        get { self[StorySlowNetworkKey.self] }
        set { self[StorySlowNetworkKey.self] = newValue }
    }
}
