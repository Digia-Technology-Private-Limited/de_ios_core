import Foundation

public typealias CustomKVHandler = @MainActor @Sendable ([String: String]) throws -> Void
public typealias DeepLinkHandler = @MainActor @Sendable (String) throws -> Void
public typealias OpenURLHandler = @MainActor @Sendable (String) throws -> Void

/// Optional host overrides for actions authored in Digia Engage.
public struct DigiaActionHandlers: Sendable {
    public let customKV: CustomKVHandler?
    public let deepLink: DeepLinkHandler?
    public let openURL: OpenURLHandler?

    public init(
        customKV: CustomKVHandler? = nil,
        deepLink: DeepLinkHandler? = nil,
        openURL: OpenURLHandler? = nil
    ) {
        self.customKV = customKV
        self.deepLink = deepLink
        self.openURL = openURL
    }
}
