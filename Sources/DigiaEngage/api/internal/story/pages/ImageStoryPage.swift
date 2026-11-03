import SwiftUI

/// One image story in the viewer (T10): the full-screen image. Reports ready on appear — an
/// image has no first frame to wait for, so the viewer starts its time at once.
/// Mirrors Android `ImageStoryPage`.
@MainActor
struct ImageStoryPage: View {
    let item: StoryItemConfig
    let onReady: @MainActor @Sendable () -> Void

    var body: some View {
        ZStack {
            Color.black
            MediaImage(spec: MediaSpec(url: item.url, fit: item.boxFit.toMediaFit))
        }
        .onAppear { onReady() }
    }
}
