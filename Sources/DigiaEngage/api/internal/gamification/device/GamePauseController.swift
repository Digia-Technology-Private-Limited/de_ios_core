import Foundation
import UIKit

/// Forwards the app lifecycle as pause/resume and holds an outcome that
/// arrives while paused until resume (contract pause and resume, rule B-8.3).
/// Standalone from the bridge: the bridge sets the callbacks, calls
/// `receiveOutcome` with each play result, and sends `pause`/`resume` plus the
/// held outcome from them.
///
/// Games run only where the core's iOS 17+ runtime gate allows.
@MainActor
final class GamePauseController<Outcome> {
    /// Called when the app backgrounds, before motion stops.
    var onPause: (() -> Void)?
    /// Called when the app returns, before any held outcome is delivered.
    var onResume: (() -> Void)?
    /// Called with each outcome: at once while open, or after `onResume`.
    var onOutcome: ((Outcome) -> Void)?

    private(set) var isPaused = false
    private var heldOutcome: Outcome?
    private let relay = GamePauseRelay()

    init() {
        relay.onBackground = { [weak self] in
            Task { @MainActor [weak self] in self?.pause() }
        }
        relay.onForeground = { [weak self] in
            Task { @MainActor [weak self] in self?.resume() }
        }
    }

    /// Receives a play result: delivered at once while open, held while paused.
    func receiveOutcome(_ outcome: Outcome) {
        if isPaused {
            heldOutcome = outcome
        } else {
            onOutcome?(outcome)
        }
    }

    /// Marks the game paused. Redundant calls are ignored.
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        onPause?()
    }

    /// Marks the game resumed, then delivers any outcome held while paused.
    /// Redundant calls are ignored.
    func resume() {
        guard isPaused else { return }
        isPaused = false
        onResume?()
        if let held = heldOutcome {
            heldOutcome = nil
            onOutcome?(held)
        }
    }
}

/// Forwards UIApplication lifecycle notifications to closures. A plain,
/// non-generic NSObject so it can use selectors — NotificationCenter holds it
/// weakly and unregisters on dealloc, so no cleanup API is needed.
private final class GamePauseRelay: NSObject {
    var onBackground: (() -> Void)?
    var onForeground: (() -> Void)?

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(didEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(willEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    @objc private func didEnterBackground() {
        onBackground?()
    }

    @objc private func willEnterForeground() {
        onForeground?()
    }
}
