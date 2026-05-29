import Foundation

public struct InAppPayload: Sendable, Codable, Equatable {
    public let id: String
    public let content: InAppPayloadContent
    public let cepContext: [String: String]

    public init(
        id: String,
        content: InAppPayloadContent,
        cepContext: [String: String] = [:]
    ) {
        self.id = id
        self.content = content
        self.cepContext = cepContext
    }
}

public struct InAppPayloadContent: Sendable, Codable, Equatable {
    /// Display type — e.g. "inline", "dialog", "bottomsheet", "overlay".
    public let type: String
    /// Placement key for inline campaigns.
    public let placementKey: String?
    /// Optional title text (fallback when no SDUI view is available).
    public let title: String?
    /// Optional body text (fallback when no SDUI view is available).
    public let text: String?
    /// The SDUI component or page ID to render.
    /// Matches `content['viewId']` in Flutter's equivalent.
    public let viewId: String?
    /// Optional command override — e.g. "SHOW_DIALOG", "SHOW_BOTTOM_SHEET", "SHOW_TOOLTIP", "SHOW_SPOTLIGHT".
    /// When absent the `type` field is used to determine presentation mode.
    public let command: String?
    /// Args passed into the rendered component/page.
    public let args: [String: JSONValue]
    /// Optional screen targeting for nudges.
    public let screenId: String?
    /// Anchor key referencing a registered DigiaAnchorView (used for SHOW_TOOLTIP / SHOW_SPOTLIGHT).
    public let anchorKey: String?
    /// Campaign key set by native CEP plugins (e.g. CleverTap). When present, the SDK resolves the
    /// full campaign from the CampaignStore and routes by campaignType, ignoring the typed fields.
    public let campaignKey: String?

    public init(
        type: String,
        placementKey: String? = nil,
        title: String? = nil,
        text: String? = nil,
        viewId: String? = nil,
        command: String? = nil,
        args: [String: JSONValue] = [:],
        screenId: String? = nil,
        anchorKey: String? = nil,
        campaignKey: String? = nil
    ) {
        self.type = type
        self.placementKey = placementKey
        self.title = title
        self.text = text
        self.viewId = viewId
        self.command = command
        self.args = args
        self.screenId = screenId
        self.anchorKey = anchorKey
        self.campaignKey = campaignKey
    }

    enum CodingKeys: String, CodingKey {
        case type
        case placementKey
        case title
        case text
        case viewId
        case command
        case args
        case screenId
        case anchorKey
        case campaignKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        placementKey = try container.decodeIfPresent(String.self, forKey: .placementKey)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        viewId = try container.decodeIfPresent(String.self, forKey: .viewId)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        args = try container.decodeIfPresent([String: JSONValue].self, forKey: .args) ?? [:]
        screenId = try container.decodeIfPresent(String.self, forKey: .screenId)
        anchorKey = try container.decodeIfPresent(String.self, forKey: .anchorKey)
        campaignKey = try container.decodeIfPresent(String.self, forKey: .campaignKey)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(placementKey, forKey: .placementKey)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(viewId, forKey: .viewId)
        try container.encodeIfPresent(command, forKey: .command)
        if !args.isEmpty {
            try container.encode(args, forKey: .args)
        }
        try container.encodeIfPresent(screenId, forKey: .screenId)
        try container.encodeIfPresent(anchorKey, forKey: .anchorKey)
        try container.encodeIfPresent(campaignKey, forKey: .campaignKey)
    }
}
