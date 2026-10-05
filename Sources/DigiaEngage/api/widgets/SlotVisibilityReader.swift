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
        private var appActive = UIApplication.shared.applicationState == .active

        override init(frame: CGRect) {
            super.init(frame: frame)
            // Selector observers are removed with the view, so nothing leaks.
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(becameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
            center.addObserver(self, selector: #selector(resignedActive), name: UIApplication.willResignActiveNotification, object: nil)
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            check()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            check()
        }

        @objc private func becameActive() {
            appActive = true
            check()
        }

        @objc private func resignedActive() {
            appActive = false
            check()
        }

        func check() {
            var shown = window != nil && appActive
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
