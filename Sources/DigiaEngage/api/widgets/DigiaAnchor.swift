import SwiftUI
import UIKit

/// Marks SwiftUI content as a guide anchor. The content renders unchanged; an
/// invisible UIKit view behind it is registered under `anchorKey`, so the guide
/// can track it and scroll it into view inside `ScrollView` or `List`.
@MainActor
public struct DigiaAnchor<Content: View>: View {
    private let anchorKey: String
    private let content: Content

    public init(anchorKey: String, @ViewBuilder content: () -> Content) {
        self.anchorKey = anchorKey
        self.content = content()
    }

    public var body: some View {
        content.background(DigiaAnchorProbe(anchorKey: anchorKey))
    }
}

/// The invisible view registered for a SwiftUI anchor. `DigiaAnchorView`
/// registers on entering a window, unregisters on leaving it, and re-registers
/// when the key changes.
private struct DigiaAnchorProbe: UIViewRepresentable {
    let anchorKey: String

    func makeUIView(context: Context) -> DigiaAnchorView {
        let view = DigiaAnchorView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.anchorKey = anchorKey
        return view
    }

    func updateUIView(_ uiView: DigiaAnchorView, context: Context) {
        uiView.anchorKey = anchorKey
    }
}
