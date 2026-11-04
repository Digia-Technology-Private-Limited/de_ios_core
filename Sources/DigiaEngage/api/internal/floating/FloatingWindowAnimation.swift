import SwiftUI

// The curves and spring behind every floating window's motion, shared by the PIP and the
// story floater so the two floaters move identically. Extracted verbatim from
// `api/widgets/floater_overlay_view.swift`; the story session's copies were the same
// values under `story`-prefixed names.

/// `SpringDescription(mass: 1, stiffness: 210, damping: 24)` in the Flutter
/// reference — `interpolatingSpring` takes these same physical units directly, so
/// unlike the Android port this needs no dampingRatio conversion.
let floatingSettleSpring = Animation.interpolatingSpring(mass: 1, stiffness: 210, damping: 24)

/// Same curve as Flutter's `Curves.easeOutBack` (`Cubic(0.34, 1.56, 0.64, 1.0)`) —
/// the y-overshoot past 1.0 is what makes a fly-in arrival bounce.
func floatingEaseOutBack(duration: Double) -> Animation {
    .timingCurve(0.34, 1.56, 0.64, 1, duration: duration)
}

func floatingEaseOutCubic(duration: Double) -> Animation {
    .timingCurve(0.215, 0.61, 0.355, 1, duration: duration)
}

func floatingEaseIn(duration: Double) -> Animation {
    .timingCurve(0.42, 0, 1, 1, duration: duration)
}

/// One window-length in the given direction, as a fraction of the window's own
/// current size — mirrors Flutter's `_flyOffset`. 1.4, not 1.0, so the window
/// clears its own footprint before the fade finishes rather than arriving
/// edge-to-edge with the screen boundary.
func floatingFlyOffset(_ direction: FloaterFlyDirection) -> CGSize {
    switch direction {
    case .left: return CGSize(width: -1.4, height: 0)
    case .right: return CGSize(width: 1.4, height: 0)
    case .top: return CGSize(width: 0, height: -1.4)
    case .bottom: return CGSize(width: 0, height: 1.4)
    }
}
