import Foundation

public enum DigiaTestKitError: Error, Equatable {
    case invalidMockServerURL(String)
}

/// Test-harness controls for Digia Engage.
///
/// Call `useMockServer(_:)` before `Digia.initialize(_:)` in a debug/noop app. This API is
/// deliberately separate from `DigiaConfig`, keeping arbitrary hosts out of the production
/// initialization contract.
public enum DigiaTestKit {
    /// Route all Digia Engage SDK endpoints to `rootURL`, excluding the `/api/v1` suffix.
    public static func useMockServer(_ rootURL: String) throws {
        try DigiaEndpointRegistry.useMockServer(rootURL)
    }

    /// Clear the test override and return to the environment selected by `DigiaConfig`.
    public static func clearMockServer() {
        DigiaEndpointRegistry.clearMockServer()
    }
}
