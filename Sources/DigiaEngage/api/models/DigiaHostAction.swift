import Foundation

public enum DigiaHostAction: Sendable, Equatable {
    case openURL(String)
    case deepLink(String)
    case customKV([String: String])
}

public enum EngageSurface: String, Sendable, Equatable {
    case nudge
    case guide
    case inline
}

public struct HostActionContext: Sendable, Equatable {
    public let campaignId: String
    public let campaignKey: String
    public let surface: EngageSurface

    public init(campaignId: String, campaignKey: String, surface: EngageSurface) {
        self.campaignId = campaignId
        self.campaignKey = campaignKey
        self.surface = surface
    }
}

public typealias HostActionHandler =
    @MainActor @Sendable (_ action: DigiaHostAction, _ context: HostActionContext) async -> Bool?
