import Foundation

/// Reports a story's frames, shared by the inline story and the story
/// floater.
///
/// Moved verbatim from `SDKInstance` (inline story lifecycle section); only
/// the receiver changed. Mirrors Flutter's `StoryReporter` (PR #253). The two
/// `reportClassic*` methods are iOS-only (classic RN bridge) and move with
/// their surface's reporter.
@MainActor
final class StoryReporter {
    init(_ ctx: SurfaceContext) { self.ctx = ctx }

    private let ctx: SurfaceContext

    /// A story was opened (ring/thumbnail tapped) — drives open rate.
    func reportStoryOpened(_ payload: CEPTriggerPayload) {
        ctx.events.toDigia(StoriesEvent.Opened(), payload: payload)
    }

    /// The CEP's click names the story opened, `story_item_<n>` (1-based), as on Flutter.
    func reportClassicStoryOpened(_ payload: CEPTriggerPayload, index: Int) {
        ctx.events.clicked(payload: payload, elementId: "story_item_\(index + 1)")
    }

    /// A story frame became visible. `itemIndex` is 1-based; `itemTotal` = frames.
    func reportStoryStepViewed(_ payload: CEPTriggerPayload, itemIndex: Int, itemTotal: Int) {
        ctx.events.toDigia(
            StoriesEvent.StepViewed(itemIndex: itemIndex, itemTotal: itemTotal), payload: payload)
    }

    /// A CTA inside a story frame was tapped.
    func reportStoryStepClicked(
        _ payload: CEPTriggerPayload,
        itemIndex: Int,
        ctaLabel: String?,
        actionType: String?,
        actionUrl: String?
    ) {
        ctx.events.toDigia(
            StoriesEvent.StepClicked(
                itemIndex: itemIndex,
                ctaLabel: ctaLabel,
                actionType: actionType,
                actionUrl: actionUrl
            ),
            payload: payload
        )
    }

    /// Story closed before the last frame. `itemIndex` is the 1-based frame on close.
    func reportStoryStepDismissed(_ payload: CEPTriggerPayload, itemIndex: Int) {
        ctx.events.toDigia(StoriesEvent.StepDismissed(itemIndex: itemIndex), payload: payload)
    }

    /// Last story frame viewed. `itemTotal` = frames; `timeToCompleteMs` from open.
    func reportStoryCompleted(
        _ payload: CEPTriggerPayload, itemTotal: Int, timeToCompleteMs: Int64?
    ) {
        ctx.events.toDigia(
            StoriesEvent.Completed(itemTotal: itemTotal, timeToCompleteMs: timeToCompleteMs),
            payload: payload
        )
    }
}
