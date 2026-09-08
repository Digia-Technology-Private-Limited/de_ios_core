import SwiftUI

/// What a canvas widget reports about the user's interaction with it.
///
/// Canvas widgets deliberately know nothing about campaigns: a carousel is a carousel whether it
/// sits on an inline card, a nudge or a floater's window, and none of them can see the
/// `CEPTriggerPayload` an analytics event has to be attributed to. So a widget states *what
/// happened to it* in its own vocabulary, and the host that owns the payload decides which event
/// that is — the same division `onAction` already draws between "this was tapped" and "this is what
/// tapping means".
///
/// Everything here mirrors an event the legacy inline carousel and story already emit. That is the
/// point: a canvas carousel replaces a media carousel, so the numbers it produces have to be
/// comparable with the ones it replaced, or the migration silently resets every funnel. The Android
/// SDK's `CampaignCanvasAnalytics.kt` is the same vocabulary; the two are meant to stay in step.
///
/// Indices are **0-based** here and converted at the host, because the legacy events are 1-based and
/// a widget should not have to know the wire's convention.
enum CanvasInteraction: Equatable {
    /// A slide settled into view. `auto` distinguishes autoplay from a deliberate swipe.
    case carouselSlideViewed(index: Int, total: Int, auto: Bool)
    /// The story viewer was opened, at `index`.
    case storyOpened(index: Int, total: Int)
    /// A story page became visible.
    case storyPageViewed(index: Int, total: Int)
    /// The viewer was closed before the last page.
    case storyPageDismissed(index: Int, total: Int)
    /// The last page was reached. `timeToCompleteMs` is measured from the open.
    case storyCompleted(total: Int, timeToCompleteMs: Int?)
}

/// Which slide or page an action came from, when it came from inside one.
///
/// Carried on the action request rather than reported separately, because a click is already
/// travelling that way and splitting it across two channels would let the two disagree about which
/// step was showing.
struct CanvasStep: Equatable {
    enum Kind: Equatable { case carouselSlide, storyPage }
    let kind: Kind
    let index: Int
    let total: Int
}

/// A reporter, boxed so it can cross the environment.
///
/// A bare closure cannot: `EnvironmentKey.defaultValue` is a static, and a function type is not
/// `Sendable`, so the compiler refuses it under strict concurrency. Boxing it in an
/// `@unchecked Sendable` struct is the usual way out and is honest here — every widget that reports
/// and every host that maps runs on the main actor, so there is no shared mutable state to race
/// over, only a type the compiler cannot prove that about.
struct CanvasInteractionReporter: @unchecked Sendable {
    let report: (CanvasInteraction) -> Void

    /// A reporter that does nothing.
    static let none = CanvasInteractionReporter { _ in }

    init(_ report: @escaping (CanvasInteraction) -> Void) { self.report = report }

    func callAsFunction(_ interaction: CanvasInteraction) { report(interaction) }
}

private struct CanvasInteractionReporterKey: EnvironmentKey {
    /// A no-op, and that default is load-bearing rather than defensive: the same widgets draw in
    /// the dashboard's own preview and inside a floater's window, and neither is a campaign whose
    /// funnel these events belong to. Only a host that has a payload to attribute them to sets one.
    static let defaultValue = CanvasInteractionReporter.none
}

extension EnvironmentValues {
    /// Where a canvas widget sends its interactions.
    var canvasInteractions: CanvasInteractionReporter {
        get { self[CanvasInteractionReporterKey.self] }
        set { self[CanvasInteractionReporterKey.self] = newValue }
    }
}
