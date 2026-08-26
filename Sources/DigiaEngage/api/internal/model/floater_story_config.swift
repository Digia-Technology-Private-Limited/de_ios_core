import SwiftUI

// The `floaterStory` template: a small floating **canvas** window that opens a
// full-screen story when tapped.
//
// The floater family's second member. A PiP (`floater_config.swift`) is a media window
// that expands into the same media; this one has no media of its own — its window is an
// authored canvas, and a tap opens the very viewer a canvas story rail opens. So the two
// share the *window* vocabulary (corner, margins, drag, snap, close, auto-dismiss) and
// reuse its types outright (`FloaterCorner`, `FloaterMargin`, `FloaterEntryAnimation`,
// `FloaterExitAnimation`), and share nothing else.
//
// Wire shape — the dashboard's `floaterStoryConfig.ts` is the other half of this
// contract, and the key names are load-bearing on both sides:
//   designWidth
//   collapsed  { widthFraction, aspectRatio, position, marginDp{t,r,b,l}, cornerRadiusDp,
//                border?{widthDp,color}, shadow, entryAnimation, exitAnimation }
//   controls   { draggable, snapToEdge, showClose, iconSize, marginDp{t,r,b,l} }
//   behavior   { onTap{type:"showStory"}, scope, onStoryEnd, autoDismissAfterMs,
//                reshowOnReturn, pauseWhenObscured }
//   canvas     <canvas>       // the window's content
//   story      <story props>  // pages + chromeCanvas, as a canvasStory widget carries them
//
// `story` is deliberately the `digia/canvasStory` widget's props with the rail fields
// removed, so `CampaignCanvasParser.parseStandaloneStory` reads it unchanged — a story is
// a story whether a rail or a floating window opened it.

private func floaterStoryColorToken(
    _ json: [String: Any], _ key: String, designTokens: DesignTokenCatalog
) -> CampaignColor? {
    try? designTokens.resolveColor(json[key])
}

/// What a finished or closed story leaves behind.
enum FloaterStoryEnd: Equatable {
    /// Back to the small window, so the user can watch again. The default, and the
    /// reason a floater is a floater rather than a one-shot overlay.
    case collapse
    /// The story was the point of the campaign; watching it ends the showing.
    case dismiss

    static func from(_ value: String?) -> FloaterStoryEnd {
        value == "dismiss" ? .dismiss : .collapse
    }
}

/// The small, draggable window: where it sits and how it is drawn.
struct FloaterStoryWindowConfig: Equatable {
    /// Width as a fraction of screen width.
    let widthFraction: CGFloat
    /// width ÷ height. Derived by the dashboard from the window canvas's own shape, so
    /// the SDK never has to guess a ratio the author did not choose.
    let aspectRatio: CGFloat
    let position: FloaterCorner
    let margin: FloaterMargin
    let cornerRadiusDp: CGFloat
    let borderWidthDp: CGFloat
    let borderColor: CampaignColor?
    let shadow: Bool
    let entryAnimation: FloaterEntryAnimation
    let exitAnimation: FloaterExitAnimation

    static func fromJson(
        _ json: [String: Any]?, designTokens: DesignTokenCatalog = .empty
    ) -> FloaterStoryWindowConfig {
        let j = json ?? [:]
        let border = j.object("border")
        let ratio = CGFloat(j.double("aspectRatio", default: 0.72))
        return FloaterStoryWindowConfig(
            // Clamped, not trusted: a window wider than the screen cannot be dragged
            // back into it, and one under ~30dp cannot be reliably tapped.
            widthFraction: CGFloat(j.double("widthFraction", default: 0.32))
                .clampedToFloaterStoryRange(0.08, 0.9),
            aspectRatio: ratio > 0 ? ratio : 0.72,
            position: FloaterCorner.from(j.nonBlankString("position")),
            margin: FloaterMargin.fromJson(j.object("marginDp")),
            cornerRadiusDp: CGFloat(j.double("cornerRadiusDp", default: 16)),
            borderWidthDp: CGFloat(border?.double("widthDp", default: 0) ?? 0),
            borderColor: border.flatMap {
                floaterStoryColorToken($0, "color", designTokens: designTokens)
            },
            shadow: j.bool("shadow", default: true),
            entryAnimation: FloaterEntryAnimation.fromJson(j.object("entryAnimation")),
            exitAnimation: FloaterExitAnimation.fromJson(j.object("exitAnimation"))
        )
    }
}

/// Affordances on the small window.
struct FloaterStoryControlsConfig: Equatable {
    let draggable: Bool
    /// Snaps to one of the four corners on release.
    let snapToCorner: Bool
    /// The × is always top-right; this only decides whether it is drawn. An author who
    /// turns it off is expected to draw their own close on the canvas and give it Hide.
    let showClose: Bool
    let iconSize: CGFloat
    let margin: FloaterMargin

    static func fromJson(_ json: [String: Any]?) -> FloaterStoryControlsConfig {
        let j = json ?? [:]
        return FloaterStoryControlsConfig(
            draggable: j.bool("draggable", default: true),
            snapToCorner: j.bool("snapToEdge", default: true),
            showClose: j.bool("showClose", default: true),
            iconSize: CGFloat(j.double("iconSize", default: 18))
                .clampedToFloaterStoryRange(10, 32),
            margin: FloaterMargin.fromJson(
                j.object("marginDp"),
                default: FloaterMargin(left: 6, top: 6, right: 6, bottom: 6)
            )
        )
    }
}

/// How the window becomes the full-screen story, and how it comes back.
///
/// SDK-owned rather than payload-authored: the dashboard no longer emits transition type or
/// duration for `floaterStory`, and letting old payloads override it made Android and iOS drift.
/// The story always uses `hero`, where the full-screen story is already mounted inside the small
/// window's aperture before the aperture expands, then the same path reverses on collapse.
enum FloaterStoryTransitionType: Equatable {
    case hero
}

/// One direction of the window↔story transition.
struct FloaterStoryTransition: Equatable {
    let type: FloaterStoryTransitionType
    let duration: TimeInterval

    /// True when there is nothing to animate — the story simply appears.
    var isInstant: Bool { duration <= 0 }

    static let sdkExpand = FloaterStoryTransition(type: .hero, duration: 0.32)
    static let sdkCollapse = FloaterStoryTransition(type: .hero, duration: 0.24)
}

/// Lifecycle and interaction behaviour.
struct FloaterStoryBehaviorConfig: Equatable {
    let onStoryEnd: FloaterStoryEnd
    /// How the window opens into the story.
    let expandTransition: FloaterStoryTransition
    /// Shorter than the expand by default: the user has already decided to leave, so a collapse
    /// that matches the open feels slow.
    let collapseTransition: FloaterStoryTransition
    /// Window timeout; `nil` = never. The clock stops while the story is open — a user
    /// watching a story is engaged, and pulling the campaign out from under them would
    /// be hostile.
    let autoDismissAfterMs: Int?
    let reshowOnReturn: Bool
    let pauseWhenObscured: Bool

    static func fromJson(_ json: [String: Any]?) -> FloaterStoryBehaviorConfig {
        let j = json ?? [:]
        return FloaterStoryBehaviorConfig(
            onStoryEnd: FloaterStoryEnd.from(j.nonBlankString("onStoryEnd")),
            expandTransition: .sdkExpand,
            collapseTransition: .sdkCollapse,
            autoDismissAfterMs: j.positiveInt("autoDismissAfterMs"),
            reshowOnReturn: j.bool("reshowOnReturn", default: false),
            pauseWhenObscured: j.bool("pauseWhenObscured", default: false)
        )
    }
}

/// A fully parsed story-floater campaign.
struct FloaterStoryConfig: Equatable {
    /// The window's content.
    let canvas: CampaignCanvas
    /// The story a tap opens — its pages and its chrome layer, exactly as the canvas
    /// story widget carries them, so the viewer cannot tell the two apart.
    let story: CampaignCanvasWidget
    /// The logical width the window canvas and the story pages were authored at.
    let designWidth: CGFloat
    let window: FloaterStoryWindowConfig
    let controls: FloaterStoryControlsConfig
    let behavior: FloaterStoryBehaviorConfig
    let variableSchemas: [VariableSchema]

    /// Returns `nil` when the campaign could not render meaningfully — no window canvas,
    /// or no readable story to open. Both are the whole campaign: a window with nothing
    /// in it is an invisible tap target, and a window that opens nothing is a decoration.
    static func fromJson(
        _ templateConfig: [String: Any], designTokens: DesignTokenCatalog = .empty
    ) -> FloaterStoryConfig? {
        guard let canvasJSON = templateConfig.object("canvas") else { return nil }
        let parser = CampaignCanvasParser(designTokens: designTokens)
        guard let canvas = try? parser.parse(canvasJSON) else { return nil }
        guard let story = parser.parseStandaloneStory(templateConfig.object("story")) else {
            return nil
        }
        let designWidth = CGFloat(templateConfig.double("designWidth", default: 360))
        return FloaterStoryConfig(
            canvas: canvas,
            story: story,
            designWidth: designWidth > 0 ? designWidth : 360,
            window: FloaterStoryWindowConfig.fromJson(
                templateConfig.object("collapsed"), designTokens: designTokens
            ),
            controls: FloaterStoryControlsConfig.fromJson(templateConfig.object("controls")),
            behavior: FloaterStoryBehaviorConfig.fromJson(templateConfig.object("behavior")),
            variableSchemas: NudgeConfig.parseVariableSchemas(templateConfig)
        )
    }
}

extension Comparable {
    fileprivate func clampedToFloaterStoryRange(_ lower: Self, _ upper: Self) -> Self {
        min(max(self, lower), upper)
    }
}
