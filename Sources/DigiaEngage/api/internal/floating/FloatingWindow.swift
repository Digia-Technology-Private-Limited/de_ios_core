import SwiftUI
import UIKit

// The one floating window both floaters are drawn in (T9).
//
// The media floater (PIP) and the story floater are separate campaigns with separate
// orchestrators, but their windows are the same object: a small box that floats over the host
// app, rests in a configured corner, follows a finger, snaps (or flings) to a corner on release,
// flies or fades in and out, and draws the same shadow. That machinery lives here once. Each
// surface passes in only what is its own: the window's size, its content, its chrome, and what a
// tap or a dismiss means for its campaign (which event is reported, which orchestrator call ends
// the showing).
//
// Deliberately NOT shared: the pixels inside the box (the PIP's media and chrome pills, the
// story floater's canvas and × ), the PIP's grow-to-full-screen and the story's hero aperture.
// They draw differently and report differently, so unifying them would change what is on screen.
//
// Android parity: `internal/floating/FloatingWindow.kt` (the resting rect, the drag/settle state,
// the snap projection and its 450 pt/s fling threshold, the ease curves). iOS differences, none of
// them visible: the state is an `ObservableObject` instead of Compose state, the settle spring
// takes the Flutter reference's physical units directly (mass 1, stiffness 210, damping 24), and
// touches arrive through a UIKit shield (`FloaterCollapsedInteractionView`) rather than a pointer
// loop, because a SwiftUI `DragGesture` re-evaluating the whole window on every move could not
// keep pace with the finger.

/// The free space a window may rest in, in points: the screen less the safe area and the margins,
/// less the window's own size. A window larger than that space rests at the minimum.
struct FloatingWindowBounds: Equatable {
    let minX: CGFloat
    let maxX: CGFloat
    let minY: CGFloat
    let maxY: CGFloat

    init(minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat) {
        self.minX = minX
        self.maxX = maxX
        self.minY = minY
        self.maxY = maxY
    }

    init(screenSize: CGSize, safeInsets: EdgeInsets, margin: FloaterMargin, windowSize: CGSize) {
        self.init(
            minX: safeInsets.leading + margin.left,
            maxX: screenSize.width - safeInsets.trailing - margin.right - windowSize.width,
            minY: safeInsets.top + margin.top,
            maxY: screenSize.height - safeInsets.bottom - margin.bottom - windowSize.height
        )
    }

    var spanX: CGFloat { maxX - minX }
    var spanY: CGFloat { maxY - minY }
}

/// The window's resting rect. A committed `dragFraction` (where the last drag landed, as a fraction
/// of the free space) wins over the configured corner; either way the window is clamped back inside
/// the bounds. Recomputed on every layout, so a rotation or a safe-area change keeps the window in
/// the same corner of the new screen.
func floatingRestingRect(
    windowSize: CGSize,
    bounds: FloatingWindowBounds,
    position: FloaterCorner,
    dragFraction: FloaterFraction?
) -> CGRect {
    let left: CGFloat
    let top: CGFloat
    if let drag = dragFraction {
        left = bounds.minX + bounds.spanX * drag.x
        top = bounds.minY + bounds.spanY * drag.y
    } else {
        left = position.isRight ? bounds.maxX : bounds.minX
        top = position.isBottom ? bounds.maxY : bounds.minY
    }
    let clampedMaxX = bounds.maxX < bounds.minX ? bounds.minX : bounds.maxX
    let clampedMaxY = bounds.maxY < bounds.minY ? bounds.minY : bounds.maxY
    return CGRect(
        x: min(max(left, bounds.minX), clampedMaxX),
        y: min(max(top, bounds.minY), clampedMaxY),
        width: windowSize.width,
        height: windowSize.height
    )
}

/// The window's drag, fling, snap and entry/exit state, one per showing.
///
/// A touch under the 6 pt slop is a tap, not a drag. While the finger moves the window mirrors it
/// unclamped (the rubber-band feel; the clamp is applied at release, in `floatingRestingRect`). On
/// release the landing corner is committed through `onCommit`, and the visual position is carried
/// across as a residual the settle spring pulls in, so the window never teleports.
@MainActor
final class FloatingWindow: ObservableObject {
    /// Touches under this distance are taps, not drags.
    static let dragThreshold: CGFloat = 6
    /// A release at or above this speed (pt/s, Flutter's logical px/s) is a fling: the snap target
    /// is projected ahead of the finger. A slower drag lands where it was let go.
    nonisolated static let snapFlingMinVelocity: CGFloat = 450
    /// How far ahead a fling projects, in seconds of its release velocity.
    nonisolated static let snapFlingProjectionSeconds: CGFloat = 0.18

    @Published private(set) var dragTranslation: CGSize = .zero
    @Published private(set) var isDragging = false
    @Published private(set) var settleResidual: CGSize = .zero
    @Published private(set) var alpha: Double = 1
    /// The fly-in/out offset, as a fraction of the window's own size.
    @Published private(set) var flyOffsetFraction: CGSize = .zero

    /// How far the window is drawn from its resting rect: the finger while dragging, else the
    /// settle spring's residual.
    var delta: CGSize { isDragging ? dragTranslation : settleResidual }

    /// One touch-move. A new touch beats an in-flight spring: grabbing the window mid-bounce takes
    /// control at once instead of fighting it.
    func dragChanged(_ translation: CGSize, draggable: Bool, closing: Bool) {
        guard draggable, !closing else { return }
        if !isDragging {
            guard hypot(translation.width, translation.height) > Self.dragThreshold else { return }
            isDragging = true
            settleResidual = .zero
        }
        dragTranslation = translation
    }

    /// The release. Commits the landing fraction through `onCommit` (the orchestrator records it,
    /// which moves the resting rect) and springs the window from where the finger left it.
    func dragEnded(
        translation: CGSize,
        velocity: CGVector,
        resting: CGRect,
        bounds: FloatingWindowBounds,
        draggable: Bool,
        closing: Bool,
        snapToCorner: Bool,
        onCommit: (FloaterFraction) -> Void
    ) {
        guard !closing else { return }
        guard draggable, isDragging, hypot(translation.width, translation.height) > Self.dragThreshold else {
            isDragging = false
            dragTranslation = .zero
            return
        }
        let visualLeft = resting.minX + translation.width
        let visualTop = resting.minY + translation.height
        let fraction = floatingReleaseFraction(
            visualOrigin: CGPoint(x: visualLeft, y: visualTop), velocity: velocity,
            bounds: bounds, snapToCorner: snapToCorner)
        let landingX = bounds.spanX <= 0 ? bounds.minX : bounds.minX + bounds.spanX * fraction.x
        let landingY = bounds.spanY <= 0 ? bounds.minY : bounds.minY + bounds.spanY * fraction.y

        onCommit(fraction)
        isDragging = false
        dragTranslation = .zero
        settleResidual = CGSize(width: visualLeft - landingX, height: visualTop - landingY)
        withAnimation(floatingSettleSpring) {
            settleResidual = .zero
        }
    }

    /// Arriving overshoots and settles, matching how releasing a drag feels. `fullscreen` (a PIP
    /// that opens expanded) needs no arrival: the content is already there.
    func runEntry(_ entry: FloaterEntryAnimation, fullscreen: Bool) {
        if fullscreen || entry.type == .appear {
            alpha = 1
            return
        }
        alpha = 0
        let flies = entry.type == .flyIn
        flyOffsetFraction = flies ? floatingFlyOffset(entry.from) : .zero
        let duration = Double(entry.durationMs) / 1000
        withAnimation(flies ? floatingEaseOutBack(duration: duration) : floatingEaseOutCubic(duration: duration)) {
            alpha = 1
            flyOffsetFraction = .zero
        }
    }

    /// Leaving accelerates away: an overshoot on exit reads as a glitch, since there is nothing left
    /// on screen for it to settle against. A full-screen window has nothing to fly or fade away.
    func runExit(_ exit: FloaterExitAnimation, fullscreen: Bool) {
        guard exit.type != .none, !fullscreen else { return }
        let flies = exit.type == .flyOut
        let duration = Double(exit.durationMs) / 1000
        withAnimation(flies ? floatingEaseOutCubic(duration: duration) : floatingEaseIn(duration: duration)) {
            alpha = 0
            if flies { flyOffsetFraction = floatingFlyOffset(exit.to) }
        }
    }
}

/// Where a release lands, as a fraction of the free space in each axis. Snapping picks the corner
/// the window is heading for: a quick flick often ends before the window crosses the half-way
/// line, so a release at fling speed is projected `snapFlingProjectionSeconds` ahead; a slower
/// drag's small tail velocity is ignored. Without snapping the window stays where it was let go.
func floatingReleaseFraction(
    visualOrigin: CGPoint,
    velocity: CGVector,
    bounds: FloatingWindowBounds,
    snapToCorner: Bool
) -> FloaterFraction {
    func axis(_ position: CGFloat, _ min: CGFloat, _ span: CGFloat, _ velocity: CGFloat) -> CGFloat {
        guard span > 0 else { return 0 }
        guard snapToCorner else { return Swift.min(Swift.max((position - min) / span, 0), 1) }
        let projected = abs(velocity) < FloatingWindow.snapFlingMinVelocity
            ? position
            : position + velocity * FloatingWindow.snapFlingProjectionSeconds
        return (projected - min) / span >= 0.5 ? 1 : 0
    }
    return FloaterFraction(
        x: axis(visualOrigin.x, bounds.minX, bounds.spanX, velocity.dx),
        y: axis(visualOrigin.y, bounds.minY, bounds.spanY, velocity.dy)
    )
}

/// One window-length in the given direction, as a fraction of the window's own size. 1.4, not 1.0,
/// so the window clears its own footprint before the fade finishes.
private func floatingFlyOffset(_ direction: FloaterFlyDirection) -> CGSize {
    switch direction {
    case .left: return CGSize(width: -1.4, height: 0)
    case .right: return CGSize(width: 1.4, height: 0)
    case .top: return CGSize(width: 0, height: -1.4)
    case .bottom: return CGSize(width: 0, height: 1.4)
    }
}

/// `SpringDescription(mass: 1, stiffness: 210, damping: 24)` in the Flutter reference.
let floatingSettleSpring = Animation.interpolatingSpring(mass: 1, stiffness: 210, damping: 24)

/// Flutter's `Curves.easeOutBack` (`Cubic(0.34, 1.56, 0.64, 1.0)`): the overshoot makes a fly-in
/// arrival bounce.
func floatingEaseOutBack(duration: Double) -> Animation {
    .timingCurve(0.34, 1.56, 0.64, 1, duration: duration)
}

func floatingEaseOutCubic(duration: Double) -> Animation {
    .timingCurve(0.215, 0.61, 0.355, 1, duration: duration)
}

func floatingEaseIn(duration: Double) -> Animation {
    .timingCurve(0.42, 0, 1, 1, duration: duration)
}

/// Flutter's `Curves.easeInOutQuart` (`Cubic(0.77, 0.0, 0.175, 1.0)`), the curve both floaters
/// grow and collapse on, so the two expand identically.
func floatingEaseInOutQuart(duration: Double) -> Animation {
    .timingCurve(0.77, 0, 0.175, 1, duration: duration)
}

extension View {
    /// The shadow both floaters draw, from Flutter's `BoxShadow(color: Color(0x73000000),
    /// blurRadius: 24, offset: Offset(0, 8))`. A cheap no-op when not applied, rather than a
    /// different view, so it animates instead of popping.
    func floatingWindowShadow(_ applied: Bool) -> some View {
        shadow(
            color: applied ? Color.black.opacity(0.45) : .clear,
            radius: applied ? 12 : 0,
            x: 0,
            y: applied ? 8 : 0
        )
    }
}

// MARK: - Touch shield

/// The window's drag and tap, through UIKit gesture recognizers rather than a SwiftUI
/// `DragGesture`: a `DragGesture` updating state on every touch-move re-evaluates the whole window
/// (media and chrome) on every move and could not keep pace with the finger. The shield is a plain
/// `UIViewRepresentable` in the same flat SwiftUI tree as the window (no nested hosting
/// controller), and claims only touches inside `activeRect` and outside the chrome's buttons.
///
/// `onDragEnded` receives the translation and the release velocity (pt/s); `FloatingWindow`
/// decides what the velocity means.
struct FloaterCollapsedInteractionView: UIViewRepresentable {
    let activeRect: CGRect
    let draggable: Bool
    let tapExpands: Bool
    let closing: Bool
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: (CGSize, CGVector) -> Void
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
        private var onDragEnded: (CGSize, CGVector) -> Void = { _, _ in }
        private var onTap: () -> Void = {}

        func update(
            draggable: Bool,
            tapExpands: Bool,
            closing: Bool,
            onDragChanged: @escaping (CGSize) -> Void,
            onDragEnded: @escaping (CGSize, CGVector) -> Void,
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
                onDragEnded(translation, CGVector(dx: velocity.x, dy: velocity.y))
            case .cancelled, .failed:
                onDragEnded(translation, .zero)
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
