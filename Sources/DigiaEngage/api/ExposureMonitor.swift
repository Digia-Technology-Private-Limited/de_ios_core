import UIKit

/// The exposure rule for `anchor_visible` and `slot_visible` (Flutter's `SlotExposure`).
enum ExposureGeometry {
    /// Share of the view that must be on screen for it to count as exposed.
    static let exposedFraction: CGFloat = 0.5

    /// Whether `rect` is exposed inside `clip` (the window and every clipping ancestor, intersected).
    /// A view larger than `clip` counts once it fills half of `clip`. An empty view has no area, so it
    /// is exposed once its top-left point is inside `clip`.
    static func isExposed(rect: CGRect, clip: CGRect) -> Bool {
        guard rect.isFinite, clip.isFinite else { return false }
        if rect.width <= 0 || rect.height <= 0 {
            return clip.width > 0 && clip.height > 0 && clip.contains(rect.origin)
        }
        let visible = rect.intersection(clip)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return false }
        return visible.area >= min(rect.area, clip.area) * exposedFraction
    }
}

/// Watches tracked views and calls back on each false-to-true change of their exposure: the app is
/// active, the view is in a window with no hidden or transparent ancestor, and `ExposureGeometry`
/// passes for the window and every clipping ancestor (a `UIScrollView` clips by default).
///
/// UIKit has no global scroll or layout callback, and a host can move, hide, clip or cover a view in
/// many ways (scroll, push, tab switch, React Native layout). So one repeating timer polls every
/// tracked view while anything is tracked; it stops when nothing is. Scrolling is the common case, so
/// the scroll views around tracked views are also observed and a scroll re-checks on the next turn
/// instead of waiting for the poll. A sheet or dialog presented over the view leaves it in its window,
/// so closing one is no new appearance.
@MainActor
final class ExposureMonitor {
    static let shared = ExposureMonitor()

    static let interval: TimeInterval = 0.25

    /// A seam so a test can stand in for the application state.
    var isAppActive: () -> Bool = { UIApplication.shared.applicationState == .active }

    private struct ID: Hashable {
        let view: ObjectIdentifier
        let tag: String
    }

    private final class Entry {
        weak var view: UIView?
        var onExposed: () -> Void
        var exposed = false

        init(view: UIView, onExposed: @escaping () -> Void) {
            self.view = view
            self.onExposed = onExposed
        }
    }

    private var entries: [ID: Entry] = [:]
    private var timer: Timer?
    private var checkScheduled = false
    /// One `contentOffset` observation per scroll view that holds a tracked view.
    private var scrollObservers: [ObjectIdentifier: ScrollObserver] = [:]

    private struct ScrollObserver {
        weak var scroll: UIScrollView?
        let observation: NSKeyValueObservation
    }

    /// Starts tracking `view` under `tag`. Tracking the same view and tag again only replaces the
    /// callback: its exposure state is kept, so a re-register is no new appearance.
    func track(_ view: UIView, tag: String, onExposed: @escaping () -> Void) {
        let id = ID(view: ObjectIdentifier(view), tag: tag)
        if let entry = entries[id], entry.view === view {
            entry.onExposed = onExposed
            return
        }
        entries[id] = Entry(view: view, onExposed: onExposed)
        startTimerIfNeeded()
        scheduleCheck()
    }

    func untrack(_ view: UIView, tag: String) {
        entries.removeValue(forKey: ID(view: ObjectIdentifier(view), tag: tag))
        stopTimerIfIdle()
    }

    /// Evaluates every tracked view now.
    func check() {
        for (id, entry) in entries {
            guard let view = entry.view else {
                entries.removeValue(forKey: id)
                continue
            }
            let exposed = isAppActive() && Self.isExposed(view)
            guard exposed != entry.exposed else { continue }
            entry.exposed = exposed
            if exposed { entry.onExposed() }
        }
        observeScrollAncestors()
        stopTimerIfIdle()
    }

    /// The exposure state of each live view tracked under `tag`, for tests.
    func exposures(tag: String) -> [Bool] {
        entries.filter { $0.key.tag == tag && $0.value.view != nil }.map(\.value.exposed)
    }

    func resetForTesting() {
        entries.removeAll()
        stopTimerIfIdle()
        isAppActive = { UIApplication.shared.applicationState == .active }
    }

    /// A newly tracked view is checked on the next turn, after the layout that mounted it.
    private func scheduleCheck() {
        guard !checkScheduled else { return }
        checkScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.checkScheduled = false
                self.check()
            }
        }
    }

    /// Keeps one observation on each scroll view around a tracked view, so a scroll re-checks at once.
    /// Rebuilt on every check, so a view that moves to another scroll view is followed within a poll.
    private func observeScrollAncestors() {
        var current: [ObjectIdentifier: UIScrollView] = [:]
        for entry in entries.values {
            var ancestor = entry.view?.superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView { current[ObjectIdentifier(scroll)] = scroll }
                ancestor = view.superview
            }
        }
        // Compared by instance too: a freed scroll view's address can be reused by a new one.
        for (id, observer) in scrollObservers where current[id] == nil || current[id] !== observer.scroll {
            observer.observation.invalidate()
            scrollObservers.removeValue(forKey: id)
        }
        for (id, scroll) in current where scrollObservers[id] == nil {
            let observation = scroll.observe(\.contentOffset) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scheduleCheck() }
            }
            scrollObservers[id] = ScrollObserver(scroll: scroll, observation: observation)
        }
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = Self.interval / 2
        // Common modes, so it keeps firing while the user drags a scroll view.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimerIfIdle() {
        guard entries.isEmpty else { return }
        timer?.invalidate()
        timer = nil
        scrollObservers.values.forEach { $0.observation.invalidate() }
        scrollObservers.removeAll()
    }

    static func isExposed(_ view: UIView) -> Bool {
        guard let window = view.window else { return false }
        var clip = window.bounds
        var ancestor: UIView? = view
        while let current = ancestor {
            if current.isHidden || current.alpha <= 0 { return false }
            if current !== view, current.clipsToBounds {
                clip = clip.intersection(current.convert(current.bounds, to: window))
            }
            if current === window { break }
            ancestor = current.superview
        }
        return ExposureGeometry.isExposed(rect: view.convert(view.bounds, to: window), clip: clip)
    }
}

private extension CGRect {
    var isFinite: Bool {
        isNull || (minX.isFinite && minY.isFinite && maxX.isFinite && maxY.isFinite)
    }

    var area: CGFloat { width * height }
}
