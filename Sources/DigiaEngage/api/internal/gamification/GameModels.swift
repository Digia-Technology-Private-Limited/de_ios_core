import Foundation
import UIKit

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

/// Which nudge-style container a game opens in. Wire strings match the web
/// view contract's `surface` values (`dialog` | `bottomSheet` | `fullScreen`).
enum GameContainerType: String, Equatable, Sendable {
    case bottomSheet
    case dialog
    case fullScreen
}

/// `safeArea` sent in `init`, in CSS px (== points). Full screen reports the
/// system insets, a bottom sheet the bottom inset only, a dialog zero — the
/// skin pads itself and never reads `env()`.
struct GameSafeArea: Equatable, Sendable {
    var top: CGFloat
    var right: CGFloat
    var bottom: CGFloat
    var left: CGFloat

    static let zero = GameSafeArea(top: 0, right: 0, bottom: 0, left: 0)

    static func forContainer(_ container: GameContainerType, system: UIEdgeInsets) -> GameSafeArea {
        switch container {
        case .fullScreen:
            return GameSafeArea(
                top: system.top, right: system.right,
                bottom: system.bottom, left: system.left)
        case .bottomSheet:
            return GameSafeArea(top: 0, right: 0, bottom: system.bottom, left: 0)
        case .dialog:
            return .zero
        }
    }
}

/// Where the bundle loads from. Until the T11 cache lands, routing passes
/// `.remoteEntry` (the campaign's `bundleUrl`); after that it passes the
/// cached folder and the web view never needs the network to load.
enum GameBundleSource: Equatable, Sendable {
    case localFolder(URL)
    case remoteEntry(URL)
}

/// Why a game closed without the user finishing it. T12 sends these as
/// `game_failed` reasons; until then they are logged and handed to `onFailure`.
enum GameFailure: String, Equatable, Sendable {
    case readyTimeout
    case bundleLoadFailed
    case renderError
    case unsupportedWebView
}

/// The `init` message body. T7 fills what it knows (surface, safe area,
/// locale, bridge version); T8 merges `extra` (`values`, `slots`, `sensors`,
/// `device`) without touching this file's shape.
struct GameInitPayload {
    var surface: GameContainerType
    var safeArea: GameSafeArea
    var locale: String
    var showMute: Bool = false
    var bridgeVersion: Int = GameBridge.bridgeVersion
    var extra: [String: Any] = [:]

    /// BCP 47 tag (`en-IN`), the shape the contract's `locale` needs.
    static var deviceLocale: String {
        let identifier = Locale.current.identifier
        guard !identifier.isEmpty else { return "en" }
        return identifier.replacingOccurrences(of: "_", with: "-")
    }

    func message() -> [String: Any] {
        var payload: [String: Any] = [
            "type": "init",
            "surface": surface.rawValue,
            // CGFloat does not bridge to JSON; encode as Double explicitly so
            // script(for:) never silently returns nil on a real payload.
            "safeArea": [
                "top": Double(safeArea.top), "right": Double(safeArea.right),
                "bottom": Double(safeArea.bottom), "left": Double(safeArea.left),
            ],
            "locale": locale,
            "showMute": showMute,
            "bridgeVersion": bridgeVersion,
        ]
        for (key, value) in extra { payload[key] = value }
        return payload
    }
}

/// The plain input routing calls to open a game: bundle location, container
/// plus sizing, campaign id, and outcome/close/failure callbacks. T8 adds the
/// play outcome delivery on this same input; nothing here changes shape.
struct GameOpenRequest {
    var campaignKey: String
    var container: GameContainerType
    var source: GameBundleSource
    /// Fixed content height for the sheet and dialog surfaces. Full screen
    /// ignores it and fills the window.
    var height: CGFloat = 480
    var showMute: Bool = false
    var onClose: (@MainActor () -> Void)?
    var onFailure: (@MainActor (GameFailure) -> Void)?}
