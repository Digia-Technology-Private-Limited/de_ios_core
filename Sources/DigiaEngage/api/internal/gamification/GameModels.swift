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

/// The software keyboard's overlap with the game surface, for
/// `viewport.keyboardInset.bottom`. The surface never resizes for the
/// keyboard; the skin keeps its form above this inset itself.
enum GameKeyboardInset {
    /// How far a docked keyboard reaches up from the surface's bottom edge,
    /// in points (CSS px). 0 when hidden, off screen, or floating/undocked
    /// (an iPad split or floating keyboard does not sit on the bottom edge).
    static func bottom(keyboard: CGRect, surface: CGRect) -> Double {
        guard keyboard.intersects(surface), keyboard.maxY >= surface.maxY - 0.5 else { return 0 }
        return Double(max(0, surface.maxY - keyboard.minY))
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
    /// The page committed but the skin sent no `ready` within 5 s.
    case readyTimeout
    /// The page did not commit within 15 s of the load starting.
    case loadTimeout
    case bundleLoadFailed
    case renderError
    case unsupportedWebView
    /// A second open while a game is already open; the request never loads.
    case busy
    /// The skin closed itself before `ready`: it cannot run on this SDK (VER-4).
    case bridgeVersionUnsupported
    /// The skin closed itself before `ready` for any other reason.
    case closedBeforeReady
    /// The web content process died before `ready`.
    case webProcessTerminated
    /// An entry or rewards open sent no `ready` within 15 s, wall clock,
    /// whatever phase it was in. A direct open times out through the
    /// presentation coordinator instead.
    case openTimeout
    /// A skin `http` call (`state`, `play` or `getRewards`) had no answer
    /// within 30 s. Reported by `game_open_failed` even when the game was
    /// already showing: the stuck window closes through the normal close path,
    /// and the hang still counts as an open failure.
    case httpTimeout

    var wireValue: String {
        switch self {
        case .readyTimeout: return "ready_timeout"
        case .loadTimeout: return "load_timeout"
        case .bundleLoadFailed: return "bundle_load_failed"
        case .renderError: return "render_error"
        case .unsupportedWebView: return "unsupported_webview"
        case .busy: return "busy"
        case .bridgeVersionUnsupported: return "bridge_version_unsupported"
        case .closedBeforeReady: return "closed_before_ready"
        case .webProcessTerminated: return "web_process_terminated"
        case .openTimeout: return "open_timeout"
        case .httpTimeout: return "http_timeout"
        }
    }
}

/// The `init` message body. Built once per session from the open
/// request and the live facts; a repeated `ready` re-sends this same message.
struct GameInitPayload {
    /// The one surface value the skin ever sees.
    static let surface = "fullScreen"

    var chanceId: String
    var campaignId: String
    /// The campaign key, for skins that call `state` with it.
    var campaignKey: String
    var skinId: String
    var skinVersion: Int
    var values: [String: JSONValue]
    var slots: [GamificationSlotConfig]
    var viewportWidth: Double
    var viewportHeight: Double
    var safeArea: GameSafeArea
    /// `viewport.keyboardInset.bottom` at build time; 0 when no keyboard.
    var keyboardBottom: Double = 0
    var colorScheme: String
    var fontFamily: String?
    var themeFonts: [[String: String]]
    var device: GameDeviceInfo

    func message() -> [String: Any] {
        var theme: [String: Any] = ["colorScheme": colorScheme, "fonts": themeFonts]
        if let fontFamily { theme["fontFamily"] = fontFamily }
        return [
            "bridgeVersion": GameBridge.bridgeVersion,
            "chanceId": chanceId,
            "campaignKey": campaignKey,
            "campaign": [
                "id": campaignId, "campaignKey": campaignKey,
                "skinId": skinId, "skinVersion": skinVersion,
            ],
            "values": Self.jsonObject(values),
            "slots": slots.map { ["outcomeKey": $0.outcomeKey, "values": Self.jsonObject($0.values)] },
            "surface": Self.surface,
            "viewport": [
                "width": viewportWidth, "height": viewportHeight,
                "safeArea": safeArea.payload,
                "keyboardInset": ["bottom": keyboardBottom],
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
    /// Fires once the skin's CTA op has run, with the op as the skin sent it
    /// (`copy`, `openLink`, `share`, or a passthrough op like `requestReview`)
    /// and, for `openLink` only, the link it opens. The surface reports it as a
    /// Digia-only Clicked. A skin `close` never fires this.
    var onCta: (@MainActor (String, String?) -> Void)?
    /// Fires once when the skin sends `ready` and the game becomes visible.
    var onShown: (@MainActor () -> Void)?
    /// Fires after each answered skin `http` call with the validated path,
    /// the sent body and the answered body, for the window's play stats.
    var onHttpAnswer: (@MainActor (String, [String: Any]?, Any?) -> Void)?
    /// Fires when a watched skin `http` call (`state`, `play`, `getRewards`)
    /// hangs with no answer: the path and how long it hung in milliseconds.
    /// The surface reports it; the presentation then closes the game through
    /// the normal close path.
    var onHttpTimeout: (@MainActor (String, Int) -> Void)?
    /// Fires when the app enters (`true`) or leaves (`false`) the foreground
    /// while the game is open, for the window's dwell time.
    var onForeground: (@MainActor (Bool) -> Void)?
    /// The payload this delivery was routed with, for the game's analytics events.
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
    /// The open's analytics timing: shared by the surface and the presentation.
    var timing = GameOpenTiming(intentAt: MonotonicClock.nowSeconds())
}

/// One open's analytics timing, from the intent (trigger or tap) to `ready`
/// or a failure. `warm` is `game`, `engine` or `none`; `stage` is how far the
/// open got: `grant`, `download`, `load`, `commit` or `ready`. Mirrors
/// Android's `GameOpenTiming`.
final class GameOpenTiming {
    /// `MonotonicClock.nowSeconds()` at the intent, in seconds.
    let intentAt: TimeInterval
    var warm: String?
    var stage: String = GameOpenTiming.stageDownload

    static let stageGrant = "grant"
    static let stageDownload = "download"
    static let stageLoad = "load"
    static let stageCommit = "commit"
    static let stageReady = "ready"

    init(intentAt: TimeInterval) {
        self.intentAt = intentAt
    }

    /// Milliseconds since the intent.
    var msElapsed: Int64 { GameOpenTiming.ms(since: intentAt) }

    static func ms(since intentAt: TimeInterval) -> Int64 {
        Int64(max(0, (MonotonicClock.nowSeconds() - intentAt) * 1000))
    }
}
