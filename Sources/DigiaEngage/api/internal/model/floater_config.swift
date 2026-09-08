import SwiftUI

// Ported from Android `FloaterConfig.kt` / Flutter `pip_config.dart`. The "floater"
// campaign type: a small draggable window (the dashboard/analytics template name is
// "pip") that expands to full screen. Wire shape (see `ai_docs/pip-properties.md`,
// the normative contract):
//   media       { kind, url, aspectRatio, loop, autoplay, volume, startMuted }
//   collapsed   { widthFraction, position, marginDp{t,r,b,l}, heightDp?, cornerRadiusDp,
//                 border?{widthDp,color}, shadow, entryAnimation, exitAnimation }
//   expanded    { mediaFit, backgroundColor, scrimOpacity, showCloseButton, closePlacement,
//                 onClose, onBack, showPlaybackControls, showMute, unmuteOnExpand,
//                 transitionMs, iconSize, controlsMargin{t,r,b,l}, designWidth, canvas }
//   controls    { draggable, snapToEdge, showClose, showMute, showExpand, showCollapse,
//                 showPlayPause, showProgress, iconSize, margin{t,r,b,l} }
//   behavior    { onTap, initialState, onMediaEnd, autoDismissAfterMs, reshowOnReturn,
//                 pauseWhenObscured }
//
// `expanded.canvas` is a **campaign canvas** — the full-screen region is drawn by the
// shared canvas renderer (`CampaignCanvasView`), exactly like Flutter's `pip_config.dart`
// and Android's `FloaterConfig.kt`. This is NOT a nudge-style widget tree; floater's
// expanded content never reuses `NudgeColumn`/`NudgeColumnContent`.

private func colorToken(_ json: [String: Any], _ key: String, designTokens: DesignTokenCatalog)
    -> CampaignColor?
{
    try? designTokens.resolveColor(json[key])
}

enum FloaterMediaKind: Equatable {
    case video
    case image
    case gif
    case lottie

    static func from(_ value: String?) -> FloaterMediaKind {
        switch value {
        case "image": return .image
        case "gif": return .gif
        case "lottie": return .lottie
        default: return .video
        }
    }

    /// Only a media kind with a timeline exposes play/pause and a progress bar — matches
    /// Android's `FloaterMediaKind.isPlayable` (video || lottie); a plain image/GIF has no
    /// "paused" state a user can toggle.
    var isPlayable: Bool { self == .video || self == .lottie }
}

struct FloaterMediaConfig: Equatable {
    let kind: FloaterMediaKind
    let url: String
    /// 0 (unset) falls back to a 9:16 default in the renderer, matching Android/Flutter.
    let aspectRatio: CGFloat
    let loop: Bool
    let autoplay: Bool
    let volume: Float
    let startMuted: Bool

    /// Returns nil when there is nothing renderable — a floater with no media is not a
    /// degraded floater, it is not a floater (matches Android's `FloaterMediaConfig
    /// .fromJson` / Flutter's `PipMedia.fromJson`, both of which reject an empty URL).
    static func fromJson(_ json: [String: Any]?) -> FloaterMediaConfig? {
        guard let j = json else { return nil }
        let url = j.string("url").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        return FloaterMediaConfig(
            kind: FloaterMediaKind.from(j.nonBlankString("kind")),
            url: url,
            aspectRatio: CGFloat(j.double("aspectRatio", default: 0)),
            loop: j.bool("loop", default: true),
            autoplay: j.bool("autoplay", default: true),
            volume: Float(j.double("volume", default: 0.5)).clamped(0, 1),
            startMuted: j.bool("startMuted", default: true)
        )
    }
}

/// The four authorable corners — center/mid-edge positions are deliberately not offered
/// (ai_docs/pip-properties.md §5.1): a floating window there most reliably covers content
/// the user is reading.
enum FloaterCorner: Equatable {
    case topLeft, topRight, bottomLeft, bottomRight

    var isRight: Bool { self == .topRight || self == .bottomRight }
    var isBottom: Bool { self == .bottomLeft || self == .bottomRight }

    static func from(_ value: String?) -> FloaterCorner {
        switch value {
        case "top_left": return .topLeft
        case "top_right": return .topRight
        case "bottom_left": return .bottomLeft
        default: return .bottomRight
        }
    }

    /// `last_position` wire vocabulary — matches the corner the window snapped to.
    var wire: String {
        switch self {
        case .topLeft: return "top_left"
        case .topRight: return "top_right"
        case .bottomLeft: return "bottom_left"
        case .bottomRight: return "bottom_right"
        }
    }
}

/// Per-side spacing in points. Absolute, unlike the fractional width: a margin is a gap
/// from an edge, and a gap that scales with the screen looks wrong on a tablet. Matches
/// Flutter's `PipEdges` / Android's `FloaterEdges` wire shape (`marginDp{top,right,
/// bottom,left}`, default 16 each side) — NOT a `{x,y}` fraction pair.
struct FloaterMargin: Equatable {
    let left: CGFloat
    let top: CGFloat
    let right: CGFloat
    let bottom: CGFloat

    static func fromJson(
        _ json: [String: Any]?,
        default fallback: FloaterMargin = FloaterMargin(left: 16, top: 16, right: 16, bottom: 16)
    ) -> FloaterMargin {
        let j = json ?? [:]
        return FloaterMargin(
            left: CGFloat(j.double("left", default: Double(fallback.left))),
            top: CGFloat(j.double("top", default: Double(fallback.top))),
            right: CGFloat(j.double("right", default: Double(fallback.right))),
            bottom: CGFloat(j.double("bottom", default: Double(fallback.bottom)))
        )
    }
}

enum FloaterEntryAnimationType: Equatable {
    case appear, fadeIn, flyIn

    static func from(_ value: String?) -> FloaterEntryAnimationType {
        switch value {
        case "fade_in": return .fadeIn
        case "fly_in": return .flyIn
        default: return .appear
        }
    }
}

enum FloaterExitAnimationType: Equatable {
    case none, fadeOut, flyOut

    static func from(_ value: String?) -> FloaterExitAnimationType {
        switch value {
        case "fade_out": return .fadeOut
        case "fly_out": return .flyOut
        default: return .none
        }
    }
}

/// The edge a `fly_in`/`fly_out` window travels from/to.
enum FloaterFlyDirection: Equatable {
    case left, right, top, bottom

    static func from(_ value: String?) -> FloaterFlyDirection {
        switch value {
        case "left": return .left
        case "top": return .top
        case "bottom": return .bottom
        default: return .right
        }
    }
}

struct FloaterEntryAnimation: Equatable {
    let type: FloaterEntryAnimationType
    let from: FloaterFlyDirection
    let durationMs: Int

    static func fromJson(_ json: [String: Any]?) -> FloaterEntryAnimation {
        let j = json ?? [:]
        return FloaterEntryAnimation(
            type: FloaterEntryAnimationType.from(j.nonBlankString("type")),
            from: FloaterFlyDirection.from(j.nonBlankString("from")),
            durationMs: j.int("durationMs", default: 300)
        )
    }
}

/// How the collapsed window leaves. `.none` tears down instantly.
struct FloaterExitAnimation: Equatable {
    let type: FloaterExitAnimationType
    let to: FloaterFlyDirection
    let durationMs: Int

    static func fromJson(_ json: [String: Any]?) -> FloaterExitAnimation {
        // The `exitAnimation` object being absent entirely (not just its `type` field)
        // means "use the default exit," which is `.fadeOut` — matching Flutter's
        // `PipExitAnimation()` / Android's `FloaterExitAnimation()` data-class default,
        // both of which are constructed whole (bypassing their `type` enum's own
        // `.none`-on-unrecognized fallback) exactly when the wire object is null. Only
        // an explicitly-authored `type` that fails to parse falls through to `.none`.
        guard let j = json else {
            return FloaterExitAnimation(type: .fadeOut, to: .right, durationMs: 200)
        }
        return FloaterExitAnimation(
            type: FloaterExitAnimationType.from(j.nonBlankString("type")),
            to: FloaterFlyDirection.from(j.nonBlankString("to")),
            durationMs: j.int("durationMs", default: 200)
        )
    }
}

struct FloaterCollapsedConfig: Equatable {
    let widthFraction: CGFloat
    let position: FloaterCorner
    let margin: FloaterMargin
    /// Explicit height in points; 0 = derive from `FloaterMediaConfig.aspectRatio`. Its
    /// presence on the wire *is* the sizing mode. Parsed for schema completeness/wire
    /// stability, matching Android's identical field — the renderer does not currently
    /// act on it there either (`ai_docs/pip-properties.md` doesn't expose it in the
    /// dashboard editor yet), so this stays parse-only here too rather than diverging.
    let heightDp: CGFloat
    let cornerRadiusDp: CGFloat
    let borderWidthDp: CGFloat
    let borderColor: CampaignColor?
    /// Parsed for schema completeness, matching Android — not yet rendered on either
    /// native platform (Compose has no direct `BoxShadow`-equivalent modifier as cheap
    /// as Flutter's, so both native SDKs deferred it rather than approximate it).
    let shadow: Bool
    let entryAnimation: FloaterEntryAnimation
    let exitAnimation: FloaterExitAnimation

    var hasFixedHeight: Bool { heightDp > 0 }

    static func fromJson(
        _ json: [String: Any]?, designTokens: DesignTokenCatalog = .empty
    ) -> FloaterCollapsedConfig {
        let j = json ?? [:]
        let border = j.object("border")
        return FloaterCollapsedConfig(
            widthFraction: CGFloat(j.double("widthFraction", default: 0.35)).clamped(0.25, 0.7),
            position: FloaterCorner.from(j.nonBlankString("position")),
            margin: FloaterMargin.fromJson(j.object("marginDp")),
            heightDp: CGFloat(j.double("heightDp", default: 0)),
            cornerRadiusDp: CGFloat(j.double("cornerRadiusDp", default: 12)),
            borderWidthDp: CGFloat(border?.double("widthDp", default: 0) ?? 0),
            borderColor: border.flatMap { colorToken($0, "color", designTokens: designTokens) },
            shadow: j.bool("shadow", default: true),
            entryAnimation: FloaterEntryAnimation.fromJson(j.object("entryAnimation")),
            exitAnimation: FloaterExitAnimation.fromJson(j.object("exitAnimation"))
        )
    }
}

/// What the × / back-gesture / swipe-to-collapse resolve to in full screen.
enum FloaterExpandedClose: Equatable {
    case collapse, dismiss

    static func from(_ value: String?) -> FloaterExpandedClose {
        value == "dismiss" ? .dismiss : .collapse
    }
}

/// Full screen: the media fills the screen and `canvas` is composited on top, drawn by
/// the shared canvas renderer — the same system nudge's canvas-layout-mode content uses
/// (`CampaignCanvasView`), not a second content model.
struct FloaterExpandedConfig: Equatable {
    let canvas: CampaignCanvas
    /// The logical width the canvas rects were authored against.
    let designWidth: CGFloat
    let backgroundColor: CampaignColor?
    let scrimOpacity: Double
    /// `true` = cover (crop to fill), matching `mediaFit: "cover"` (the default);
    /// `false` = contain.
    let cover: Bool
    let showCloseButton: Bool
    /// `true` when the × sits in the top-left rather than the top-right.
    let closeOnLeft: Bool
    let onClose: FloaterExpandedClose
    /// Separate from `onClose` — the back gesture (Android) / swipe-down-to-collapse
    /// (iOS, since there is no OS back gesture reaching a floating window) is "undo the
    /// last step", while × is an explicit "I am done with this". Defaults to `.collapse`
    /// for that reason; an author who wants back to end the campaign can say so.
    let onBack: FloaterExpandedClose
    let showPlaybackControls: Bool
    let showMute: Bool
    let unmuteOnExpand: Bool
    /// The grow/collapse geometry transition's duration — matches Flutter's
    /// `pip_config.dart` default.
    let transitionMs: Int
    /// Size of the expanded chrome pills (mute/expand-collapse/close), points.
    let iconSize: CGFloat
    /// Padding around the expanded chrome row. `top` is added to the safe-area inset, not
    /// a replacement for it.
    let controlsMargin: FloaterMargin

    /// Returns nil when the expanded canvas is missing or unparseable — with
    /// `onTap: expand` as the default, a floater that cannot open is a dead end, so the
    /// whole campaign is dropped rather than shipped half-working (matches Android's
    /// `FloaterExpandedConfig.fromJson` / Flutter's `PipExpanded.fromJson`).
    static func fromJson(
        _ json: [String: Any]?, designTokens: DesignTokenCatalog = .empty
    ) -> FloaterExpandedConfig? {
        guard let j = json, let canvasJson = j.object("canvas"), !canvasJson.isEmpty else {
            return nil
        }
        let canvas: CampaignCanvas
        do {
            canvas = try CampaignCanvasParser(designTokens: designTokens).parse(canvasJson)
        } catch {
            DigiaLog.warning(
                "[FloaterConfig] rejected Canvas campaign: \(error.localizedDescription)")
            return nil
        }
        let rawDesignWidth = CGFloat(
            j.double("designWidth", default: Double(defaultCampaignCanvasDesignWidth)))
        return FloaterExpandedConfig(
            canvas: canvas,
            designWidth: rawDesignWidth.isFinite && rawDesignWidth > 0
                ? rawDesignWidth : defaultCampaignCanvasDesignWidth,
            backgroundColor: colorToken(j, "backgroundColor", designTokens: designTokens),
            scrimOpacity: j.double("scrimOpacity", default: 0.55).clamped(0, 1),
            cover: j.string("mediaFit", default: "cover") != "contain",
            showCloseButton: j.bool("showCloseButton", default: true),
            closeOnLeft: j.string("closePlacement", default: "top_right") == "top_left",
            onClose: FloaterExpandedClose.from(j.nonBlankString("onClose")),
            onBack: FloaterExpandedClose.from(j.nonBlankString("onBack")),
            showPlaybackControls: j.bool("showPlaybackControls", default: false),
            showMute: j.bool("showMute", default: true),
            unmuteOnExpand: j.bool("unmuteOnExpand", default: false),
            transitionMs: j.int("transitionMs", default: 500),
            iconSize: CGFloat(j.double("iconSize", default: 20)).clamped(14, 32),
            // Wire key is `controlsMarginDp`, not `controlsMargin` — the dashboard's
            // `pipCampaignConfig.ts` follows the `...Dp` suffix convention every other
            // absolute-size field in this contract uses. Reading the wrong key silently
            // no-op'd: a configured value never reached the SDK, always falling back to the
            // hardcoded default (same bug found and fixed on Android's `FloaterConfig.kt`).
            controlsMargin: FloaterMargin.fromJson(
                j.object("controlsMarginDp"),
                default: FloaterMargin(left: 12, top: 4, right: 12, bottom: 0)
            )
        )
    }
}

struct FloaterControlsConfig: Equatable {
    let draggable: Bool
    let snapToCorner: Bool
    let showClose: Bool
    let showMute: Bool
    let showExpand: Bool
    let showCollapse: Bool
    let showPlayPause: Bool
    let showProgress: Bool
    /// Size of the collapsed chrome pills (mute/expand/close), points. `16`, not the
    /// pre-2026 fixed `12` this default replaced — matches `pip_config.dart`'s own note
    /// that `12` read too small against a real device.
    let iconSize: CGFloat
    /// Padding around the collapsed chrome pills, points.
    let margin: FloaterMargin

    static func fromJson(_ json: [String: Any]?) -> FloaterControlsConfig {
        let j = json ?? [:]
        return FloaterControlsConfig(
            draggable: j.bool("draggable", default: true),
            snapToCorner: j.bool("snapToEdge", default: true),
            showClose: j.bool("showClose", default: true),
            showMute: j.bool("showMute", default: true),
            showExpand: j.bool("showExpand", default: true),
            showCollapse: j.bool("showCollapse", default: true),
            showPlayPause: j.bool("showPlayPause", default: false),
            showProgress: j.bool("showProgress", default: false),
            iconSize: CGFloat(j.double("iconSize", default: 16)).clamped(10, 24),
            // Wire key is `marginDp` — see the matching note on `expanded.controlsMarginDp`
            // above; same mismatch, same silent no-op symptom.
            margin: FloaterMargin.fromJson(
                j.object("marginDp"),
                default: FloaterMargin(left: 4, top: 4, right: 4, bottom: 4)
            )
        )
    }
}

enum FloaterOnMediaEnd: Equatable {
    case loop, collapse, dismiss, keepLastFrame

    static func from(_ value: String?) -> FloaterOnMediaEnd {
        switch value {
        case "collapse": return .collapse
        case "dismiss": return .dismiss
        case "keepLastFrame", "keep_last_frame": return .keepLastFrame
        default: return .loop
        }
    }
}

struct FloaterBehaviorConfig: Equatable {
    /// `behavior.onTap: { type: "expand" }` is the only supported action today; a link
    /// action is technically parseable but degenerate (turns the floater into a banner)
    /// and out of scope for this pass — this field is `true` unless the dashboard ever
    /// authors something else.
    let tapExpands: Bool
    let startExpanded: Bool
    let onMediaEnd: FloaterOnMediaEnd
    let autoDismissAfterMs: Int?
    /// Whether returning to the same screen shows the floater again. Schema-only — not
    /// exposed in the dashboard editor, and not acted on by Flutter or Android either
    /// (matches both — see their own `reshowOnReturn` doc comments). Parsed here purely
    /// so this field round-trips instead of being silently dropped if a dashboard ever
    /// starts sending it.
    let reshowOnReturn: Bool
    /// Schema-only, not editor-exposed — both default `false` (2026-08 decision). A
    /// collapsed floater keeps playing behind an obscuring modal unless a campaign
    /// author explicitly opts in.
    let pauseWhenObscured: Bool

    static func fromJson(_ json: [String: Any]?) -> FloaterBehaviorConfig {
        let j = json ?? [:]
        let onTap = j.object("onTap")
        return FloaterBehaviorConfig(
            tapExpands: (onTap?.string("type", default: "expand") ?? "expand") == "expand",
            startExpanded: j.string("initialState", default: "collapsed") == "expanded",
            onMediaEnd: FloaterOnMediaEnd.from(j.nonBlankString("onMediaEnd")),
            autoDismissAfterMs: j.positiveInt("autoDismissAfterMs"),
            reshowOnReturn: j.bool("reshowOnReturn", default: false),
            pauseWhenObscured: j.bool("pauseWhenObscured", default: false)
        )
    }
}

struct FloaterConfig: Equatable {
    let media: FloaterMediaConfig
    let collapsed: FloaterCollapsedConfig
    let expanded: FloaterExpandedConfig
    let controls: FloaterControlsConfig
    let behavior: FloaterBehaviorConfig
    let variableSchemas: [VariableSchema]

    /// `templateConfig` is the top-level object the campaign wraps this in (matching
    /// nudge/survey). Returns nil when the campaign could not render meaningfully — no
    /// media, or no expanded canvas to open.
    static func fromJson(
        _ templateConfig: [String: Any], designTokens: DesignTokenCatalog = .empty
    ) -> FloaterConfig? {
        guard let media = FloaterMediaConfig.fromJson(templateConfig.object("media")) else {
            return nil
        }
        guard
            let expanded = FloaterExpandedConfig.fromJson(
                templateConfig.object("expanded"), designTokens: designTokens
            )
        else { return nil }
        return FloaterConfig(
            media: media,
            collapsed: FloaterCollapsedConfig.fromJson(
                templateConfig.object("collapsed"), designTokens: designTokens
            ),
            expanded: expanded,
            controls: FloaterControlsConfig.fromJson(templateConfig.object("controls")),
            behavior: FloaterBehaviorConfig.fromJson(templateConfig.object("behavior")),
            variableSchemas: NudgeConfig.parseVariableSchemas(templateConfig)
        )
    }
}

extension Comparable {
    fileprivate func clamped(_ lower: Self, _ upper: Self) -> Self {
        min(max(self, lower), upper)
    }
}
