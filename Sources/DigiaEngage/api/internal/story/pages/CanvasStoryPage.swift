import SwiftUI

/// One canvas story in the viewer (T8): the page canvas and the chrome canvas the author arranged,
/// drawn over the page's media (the same `ImageStoryPage` / `VideoStoryPage` a classic story
/// shows, which the viewer draws below its navigation layer, so an authored button still wins the
/// tap). Mirrors Android `CanvasStoryPage`; the layout is `main`'s canvas viewer's.
@MainActor
struct CanvasStoryPage: View {
    let page: CampaignCanvasStoryPage
    let chrome: CampaignCanvas
    let context: StoryViewerContext
    let total: Int
    let isDark: Bool
    let safeAreaInsets: EdgeInsets
    let showsOverlays: Bool
    let onAction: (CampaignCanvasActionRequest) -> Void

    var body: some View {
        let size = context.size
        // The width the chrome and page are scaled against: the full-bleed viewer minus the
        // device's unsafe margins.
        let contentWidth = max(0, size.width - safeAreaInsets.leading - safeAreaInsets.trailing)
        let safeHeight = max(0, size.height - safeAreaInsets.top - safeAreaInsets.bottom)
        // The page and the chrome are authored in one box (the safe content region of the design
        // device), fitted into the safe region whole: one scale that satisfies both axes, centred
        // across and resting on the bottom edge, with the chrome sharing the page's rect.
        let box = CGSize(
            width: max(page.canvas.width, chrome.width),
            height: max(page.canvas.height, chrome.height)
        )
        let scale = CanvasStoryViewer.storyBoxScale(
            box: box, available: CGSize(width: contentWidth, height: safeHeight))
        let index = context.index
        // The page an action came from travels with it, so a CTA inside story 3 reports as a step
        // click on story 3 rather than as an anonymous click on the card.
        let pageAction: (CampaignCanvasActionRequest) -> Void = { request in
            var stamped = request
            stamped.step = CanvasStep(kind: .storyPage, index: index, total: total)
            onAction(stamped)
        }
        ZStack(alignment: .top) {
            ScaledCanvasStage(
                canvas: page.canvas,
                width: page.canvas.width * scale,
                height: page.canvas.height * scale,
                cornerRadius: 0,
                isDark: isDark,
                onAction: pageAction
            )
            .frame(width: contentWidth, height: safeHeight, alignment: .bottom)
            .clipped()

            ScaledCanvasStage(
                canvas: chrome,
                width: chrome.width * scale,
                height: chrome.height * scale,
                cornerRadius: 0,
                isDark: isDark,
                onAction: pageAction,
                // Transparent by design: the page shows through, as on Flutter.
                showBackground: false
            )
            // At the top of the fitted box, which is where it was authored over the page.
            .frame(height: box.height * scale, alignment: .top)
            .frame(width: contentWidth, height: safeHeight, alignment: .bottom)
            .clipped()
            .environment(
                \.canvasStoryViewer,
                CanvasStoryViewerState(
                    index: index,
                    pageCount: total,
                    progress: CGFloat(context.progress),
                    muted: context.muted
                )
            )
            .environment(\.canvasStoryClose, CanvasStoryCallback(run: { MainActor.assumeIsolated { context.dismiss() } }))
            .environment(\.canvasStoryToggleMute, CanvasStoryCallback(run: { MainActor.assumeIsolated { context.toggleMute() } }))
        }
        .opacity(showsOverlays ? 1 : 0)
        .allowsHitTesting(showsOverlays)
        .accessibilityHidden(!showsOverlays)
        // Inside the safe region; the media behind still covers the whole screen.
        .padding(safeAreaInsets)
        .frame(width: size.width, height: size.height)
    }
}
