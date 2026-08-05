import Foundation

public enum DigiaTestKitError: Error, Equatable {
    case invalidMockServerURL(String)
    case alreadyInitialized
    case unavailableInRelease
}

/// Test-harness controls for Digia Engage.
///
/// Call `useMockServer(_:)` before `Digia.initialize(_:)` in a debug/noop app. Release-mode
/// test apps must opt in explicitly with `allowInRelease: true`. This API is deliberately
/// separate from `DigiaConfig`, keeping arbitrary hosts out of normal initialization.
public enum DigiaTestKit {
    /// Route all Digia Engage SDK endpoints to `rootURL`, excluding the `/api/v1` suffix.
    public static func useMockServer(_ rootURL: String, allowInRelease: Bool = false) throws {
        try DigiaEndpointRegistry.useMockServer(rootURL, allowInRelease: allowInRelease)
    }
}
