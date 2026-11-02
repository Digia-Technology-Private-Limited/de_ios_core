import SwiftUI
import UIKit

// The drag-to-reposition and tap-to-open shield both floating windows sit behind.
///
/// A `UIPanGestureRecognizer` + `UITapGestureRecognizer` pair on a plain `UIView`, rather than
/// a SwiftUI `DragGesture`: a `DragGesture` updating state on every touch-move forces the whole
/// session body (geometry, media, chrome) to re-evaluate on each move event, which proved too
/// expensive to keep pace with the finger — visible flicker/lag, the box trailing behind rather
/// than tracking it. `UIPanGestureRecognizer` delivers through UIKit's own responder chain, not
/// SwiftUI's diffing. Extracted verbatim from `api/widgets/floater_overlay_view.swift`; shared
/// with the story floater's own window — the gesture contract is identical, and a second copy
/// of a shield tuned this carefully is the last thing this SDK needs.
struct FloaterCollapsedInteractionView: UIViewRepresentable {
    let activeRect: CGRect
    let draggable: Bool
    let tapExpands: Bool
    let closing: Bool
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: (CGSize, CGSize) -> Void
    let onTap: () -> Void
    let chromeButtonBounds: [CGRect]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> FloaterTouchShieldView {
        let view = FloaterTouchShieldView()

        let pan = UIPanGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.cancelsTouchesInView = true
        pan.delaysTouchesBegan = true
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        context.coordinator.pan = pan

        let tap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = true
        tap.delaysTouchesBegan = true
        tap.delegate = context.coordinator
        tap.require(toFail: pan)
        view.addGestureRecognizer(tap)
        context.coordinator.tap = tap

        return view
    }

    func updateUIView(_ uiView: FloaterTouchShieldView, context: Context) {
        uiView.isUserInteractionEnabled = draggable || tapExpands
        uiView.activeRect = activeRect
        uiView.excludedRects = chromeButtonBounds
        context.coordinator.update(
            draggable: draggable,
            tapExpands: tapExpands,
            closing: closing,
            onDragChanged: onDragChanged,
            onDragEnded: onDragEnded,
            onTap: onTap
        )
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var pan: UIPanGestureRecognizer?
        weak var tap: UITapGestureRecognizer?

        private var draggable = false
        private var tapExpands = false
        private var closing = false
        private var onDragChanged: (CGSize) -> Void = { _ in }
        private var onDragEnded: (CGSize, CGSize) -> Void = { _, _ in }
        private var onTap: () -> Void = {}

        func update(
            draggable: Bool,
            tapExpands: Bool,
            closing: Bool,
            onDragChanged: @escaping (CGSize) -> Void,
            onDragEnded: @escaping (CGSize, CGSize) -> Void,
            onTap: @escaping () -> Void
        ) {
            self.draggable = draggable
            self.tapExpands = tapExpands
            self.closing = closing
            self.onDragChanged = onDragChanged
            self.onDragEnded = onDragEnded
            self.onTap = onTap
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard draggable, !closing else { return }
            let translationPoint = recognizer.translation(in: recognizer.view)
            let translation = CGSize(width: translationPoint.x, height: translationPoint.y)
            switch recognizer.state {
            case .began, .changed:
                onDragChanged(translation)
            case .ended:
                let velocity = recognizer.velocity(in: recognizer.view)
                let projected = CGSize(
                    width: translation.width + velocity.x * 0.18,
                    height: translation.height + velocity.y * 0.18
                )
                onDragEnded(translation, projected)
            case .cancelled, .failed:
                onDragEnded(translation, translation)
            default:
                break
            }
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, tapExpands, !closing else { return }
            onTap()
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === pan {
                return draggable && !closing
            }
            if gestureRecognizer === tap {
                return tapExpands && !closing
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }
    }
}

final class FloaterTouchShieldView: UIView {
    var activeRect: CGRect = .null
    // Chrome button pill rects (mute/expand/close) this shield must never resolve as
    // its own hit target for. Checked here, not just inside `handleTap`'s own
    // suppression of `onTap()` — a check that runs only *after* a recognizer has
    // already claimed the touch does nothing to stop `cancelsTouchesInView`/
    // `delaysTouchesBegan` from having already intercepted and delayed it, starving
    // the real SwiftUI `Button` underneath (mute/expand/close) of ever receiving it.
    // Rejecting these points at `hitTest` itself means the shield is never even a
    // candidate over a button, so whatever's genuinely on top there resolves instead.
    var excludedRects: [CGRect] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !activeRect.isNull, activeRect.contains(point),
            !excludedRects.contains(where: { $0.contains(point) })
        else {
            return nil
        }
        return super.hitTest(point, with: event)
    }
}
