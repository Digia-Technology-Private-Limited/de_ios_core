import Foundation

/// Test-harness controls for Digia Engage.
public enum DigiaTestKit {
    public enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case alreadyInitialized
        case releaseModeDisabled
        case invalidRootUrl(String)

        public var description: String {
            switch self {
            case .alreadyInitialized:
                return "DigiaTestKit.overrideBaseUrl must be called before Digia.initialize()."
            case .releaseModeDisabled:
                return "DigiaTestKit is disabled for release builds. Pass allowInRelease: true only in a dedicated release-mode test app."
            case .invalidRootUrl(let url):
                return "Mock server root must be an absolute HTTP(S) origin with no path, credentials, query, or fragment (got: \(url))"
            }
        }
    }

    /// Route all Digia Engage SDK endpoints to [rootUrl], excluding `/api/v1`.
    /// Must be called before `Digia.initialize`.
    ///
    /// A dedicated release-mode test build can pass `allowInRelease: true`;
    /// ordinary release builds reject the override.
    public static func overrideBaseUrl(
        _ rootUrl: String,
        allowInRelease: Bool = false
    ) throws {
        guard !DigiaEndpoints.isInitialized else {
            throw Error.alreadyInitialized
        }
        guard DigiaDebugDetection.isDebugBuild() || allowInRelease else {
            throw Error.releaseModeDisabled
        }
        try DigiaEndpoints.setTestRoot(rootUrl)
    }

    /// Resets all endpoint and test state to defaults. Use in SDK tests only.
    public static func resetForTest() {
        DigiaEndpoints.resetForTest()
    }
}
