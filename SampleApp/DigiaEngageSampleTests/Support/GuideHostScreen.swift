import SwiftUI
@testable import DigiaEngage

/// A host screen carrying the anchors the `guide-spotlight-journey` steps point at, so
/// each step has something on screen to highlight.
struct GuideHostScreen: View {
    var body: some View {
        VStack(spacing: 16) {
            DigiaAnchor(anchorKey: "home_header_search") { Color.gray.opacity(0.2).frame(height: 44) }
            DigiaAnchor(anchorKey: "category_chips") { Color.blue.opacity(0.2).frame(height: 40) }
            Spacer().frame(height: 140)
            DigiaAnchor(anchorKey: "home_carousel") { Color.teal.opacity(0.3).frame(height: 180) }
            Spacer()
        }
        .padding(16)
    }
}
