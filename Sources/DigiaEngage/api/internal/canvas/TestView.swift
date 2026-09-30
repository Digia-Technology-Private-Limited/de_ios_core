import SwiftUI

/// TestView
///
/// Wraps `content` with an `accessibilityIdentifier` for automated testing (Maestro, XCUITest,
/// etc.) by element `id`.
///
/// Automatically drops the identifier in release builds so there is zero overhead or
/// accessibility tree pollution in production.
struct TestView<Content: View>: View {
    let id: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if DEBUG
        if id.isEmpty {
            content()
        } else {
            content().accessibilityIdentifier(id)
        }
        #else
        content()
        #endif
    }
}
