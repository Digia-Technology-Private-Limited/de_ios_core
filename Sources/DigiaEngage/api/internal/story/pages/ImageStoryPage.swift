import SwiftUI

/// One image story in the viewer (T8): the full-screen picture through `MediaImage`. It reports
/// ready on appear: an image has no first frame to wait for, so its time starts at once, as on
/// `main`. A picture with no URL draws nothing and its time still runs. Mirrors Android
/// `ImageStoryPage`.
@MainActor
struct ImageStoryPage: View {
    let item: StoryItemConfig
    let onReady: @MainActor () -> Void

    var body: some View {
        ZStack {
            Color.black
            if !item.url.isEmpty {
                StoryImage(url: item.url, fit: item.boxFit.toMediaFit)
            }
        }
        .onAppear { onReady() }
    }
}
