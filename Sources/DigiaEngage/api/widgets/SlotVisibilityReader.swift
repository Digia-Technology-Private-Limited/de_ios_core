import SwiftUI
import UIKit

/// Reports whether the slot is on screen: in a window, with no hidden view
/// above it, while the app is active. SwiftUI's appear events miss hidden
/// UIKit and React Native hosts, so the slot checks the view hierarchy itself.
struct SlotVisibilityReader: UIViewRepresentable {
    @Binding var visible: Bool

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.onChange = { visible = $0 }
        view.check()
    }

    final class ProbeView: UIView {
        var onChange: ((Bool) -> Void)?
        private var reported: Bool?
        private var activeObserver: NSObjectProtocol?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            activeObserver = window == nil ? nil : NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
            check()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            check()
        }

        func check() {
            var shown = window != nil && UIApplication.shared.applicationState == .active
            var view: UIView? = self
            while shown, let current = view {
                shown = !current.isHidden
                view = current.superview
            }
            guard shown != reported else { return }
            reported = shown
            // SwiftUI state must not change during a view update.
            DispatchQueue.main.async { [onChange] in onChange?(shown) }
        }
    }
}
