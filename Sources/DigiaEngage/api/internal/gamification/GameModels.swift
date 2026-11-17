import Foundation
import UIKit

/// `safeArea` sent in `init`, in CSS px (== points). The game is always full
/// screen, so it reports the system insets — the skin pads itself and never
/// reads `env()`.
struct GameSafeArea: Equatable, Sendable {
    var top: CGFloat
    var right: CGFloat
    var bottom: CGFloat
    var left: CGFloat

    static let zero = GameSafeArea(top: 0, right: 0, bottom: 0, left: 0)

    static func fullScreen(system: UIEdgeInsets) -> GameSafeArea {
        GameSafeArea(
            top: system.top, right: system.right,
            bottom: system.bottom, left: system.left)
    }

    var payload: [String: Any] {
        // CGFloat does not bridge to JSON; encode as Double explicitly so the
        // `__receive` script never silently returns nil on a real payload.
        ["top": Double(top), "right": Double(right), "bottom": Double(bottom), "left": Double(left)]
    }
}

/// Why a game closed without the user finishing it. Failures log with the
/// reason and settle through the coordinator, whose delivery outcome records
/// the analytics; the surface itself stays silent.
///
/// `wireValue` is the cross-stack contract: it reaches the `game_open_failed`
/// analytics event from three runtimes and must match character for
/// character (Android's `GameFailureReason.wireValue`).
enum GameFailure: String, Equatable, Sendable {
    case readyTimeout
    case bundleLoadFailed
    case renderError
    case unsupportedWebView
    /// A second open while a game is already open; the request never loads.
    case busy

    var wireValue: String {
        switch self {
        case .readyTimeout: return "ready_timeout"
        case .bundleLoadFailed: return "bundle_load_failed"
        case .renderError: return "render_error"
        case .unsupportedWebView: return "unsupported_webview"
        case .busy: return "busy"
        }
    }
}

/// The `init` message body. Built once per session from the open
/// request and the live facts; a repeated `ready` re-sends this same message.
struct GameInitPayload {
    /// The one surface value the skin ever sees.
    static let surface = "fullScreen"

    /// What the skin may feature-detect on. Versions never gate features.
    static let capabilities = [
        "http", "event", "log", "haptics", "sensor", "storage",
        "action.copy", "action.openLink", "action.close", "action.steps",
        "viewport", "device", "lifecycle",
    ]

    var chanceId: String
    var campaignId: String
    /// The campaign key, for skins that call `state` with it.
    var campaignKey: String
    var skinId: String
    var skinVersion: Int
    var values: [String: JSONValue]
    var slots: [GamificationSlotConfig]
    var showMute: Bool
    var viewportWidth: Double
    var viewportHeight: Double
    var safeArea: GameSafeArea
    var colorScheme: String
    var fontFamily: String?
    var themeFonts: [[String: String]]
    var device: GameDeviceInfo

    func message() -> [String: Any] {
        var theme: [String: Any] = ["colorScheme": colorScheme, "fonts": themeFonts]
        if let fontFamily { theme["fontFamily"] = fontFamily }
        return [
            "bridgeVersion": GameBridge.bridgeVersion,
            "capabilities": Self.capabilities,
            "chanceId": chanceId,
            // Flat beside `type` for skins built before the envelope: the
            // whole message repeats flat there in `sendInit`.
            "campaignKey": campaignKey,
            "campaign": [
                "id": campaignId, "campaignKey": campaignKey,
                "skinId": skinId, "skinVersion": skinVersion,
            ],
            "values": Self.jsonObject(values),
            "slots": slots.map { ["outcomeKey": $0.outcomeKey, "values": $0.values] },
            "surface": Self.surface,
            "showMute": showMute,
            "viewport": [
                "width": viewportWidth, "height": viewportHeight,
                "safeArea": safeArea.payload,
            ],
            "theme": theme,
            "device": device.payload,
        ]
    }

    static func jsonObject(_ value: [String: JSONValue]) -> [String: Any] {
        value.mapValues(jsonValue)
    }

    private static func jsonValue(_ value: JSONValue) -> Any {
        switch value {
        case .string(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .array(let v): return v.map(jsonValue)
        case .object(let v): return v.mapValues(jsonValue)
        case .null: return NSNull()
        }
    }
}

/// The plain input routing calls to open a game: the cached skin file, the
/// chance and skin identity the bridge answers with, and the exactly-once
/// close/failure callbacks. The game is always full screen.
struct GameOpenRequest {
    var campaignKey: String
    var campaignId: String
    var skinId: String
    var skinVersion: Int
    var chanceId: String
    /// Live-test invocation this game was opened for; the skin's `state` call
    /// carries it so a draft campaign answers instead of refusing `notFound`.
    /// Nil for organic opens.
    var testInvocationId: String?
    var projectId: String
    var userId: String
    /// The cached `index.html`. Download-then-show resolves this before the
    /// request is built, so the web view never needs the network to load.
    var entryFile: URL
    /// The folder holding `entryFile`, for `loadFileURL` read access.
    var bundleRoot: URL
    var showMute: Bool = false
    /// Fires on close with why: `user` for the close button and back, `skin`
    /// for the skin's own `close`, `cta` for a handoff op. Mirrors Android's
    /// `GameOpenRequest.onClose`.
    var onClose: (@MainActor (String) -> Void)?
    var onFailure: (@MainActor (GameFailure) -> Void)?
    /// Fires once the skin's CTA op (or `{steps:[...]}` run) has run, with the
    /// op (`copy`, `openLink`, `share`, ...; `steps` for a steps run). The
    /// caller reports the click. A skin `close` never fires this.
    var onCta: (@MainActor (String) -> Void)?
    /// Fires once when the skin sends `ready` and the game becomes visible.
    var onShown: (@MainActor () -> Void)?
    /// The payload this delivery was routed with, for skin-event analytics.
    var payload: CEPTriggerPayload
    /// `direct`, `inlineTeaser`, `floating` or `rewards`. Carried for the
    /// `game_` health events.
    var entry: String
    /// The campaign theme family, when the host sets none.
    var themeFontFamily: String?
    /// The campaign theme fonts.
    var themeFonts: [[String: String]] = []
    /// `init.values`: the marketer's field values, carried opaquely.
    var values: [String: JSONValue] = [:]
    /// `init.slots`: outcome-keyed slot values, read whenever present.
    var slots: [GamificationSlotConfig] = []
}
