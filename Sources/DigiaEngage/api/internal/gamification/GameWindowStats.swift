import Foundation

/// What one open game window did, for its analytics: the chance it opened with,
/// how many `/play` requests the skin sent (for `play` vs `play_again`), how many
/// plays landed an outcome, the latest refusal, and how long the game was visible
/// in the foreground after it showed. Fed from
/// the bridge's `http` answers and app foreground changes. Mirrors Android's
/// `GameWindowStats`.
final class GameWindowStats: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: () -> Int64
    /// The chance the window opened with; play again and play next do not move it.
    let chanceId: String
    private var playRequests = 0
    private var playCount = 0
    private var lastRefused = ""
    private var started = false
    private var foreground = true
    private var visibleSinceMs: Int64 = 0
    private var dwellTotalMs: Int64 = 0

    init(chanceId: String, clock: @escaping () -> Int64 = {
        Int64(ProcessInfo.processInfo.systemUptime * 1000)
    }) {
        self.chanceId = chanceId
        self.clock = clock
    }

    var plays: Int { lock.withLock { playCount } }
    var playRefused: String { lock.withLock { lastRefused } }

    /// Counts one `/play` request and returns its 1-based number in this window.
    func nextPlayNumber() -> Int {
        lock.withLock {
            playRequests += 1
            return playRequests
        }
    }

    /// One answered bridge `http` call. `response` is the http body
    /// (`{isSuccess, data:{response}}`); only `play` and `peek` count.
    func recordHttp(path: String, response: Any?) {
        guard path == "play" || path == "peek" else { return }
        lock.withLock {
            guard let body = response as? [String: Any],
                  let data = body["data"] as? [String: Any],
                  let answer = data["response"] as? [String: Any] else { return }
            if let refused = answer["refused"] as? String, !refused.isEmpty { lastRefused = refused }
            if path == "play", let outcome = answer["outcomeKey"] as? String, !outcome.isEmpty {
                playCount += 1
            }
        }
    }

    /// The game showed: dwell starts counting.
    func start() {
        lock.withLock {
            guard !started else { return }
            started = true
            if foreground { visibleSinceMs = clock() }
        }
    }

    func setForeground(_ value: Bool) {
        lock.withLock {
            guard value != foreground else { return }
            foreground = value
            guard started else { return }
            if value {
                visibleSinceMs = clock()
            } else {
                dwellTotalMs += clock() - visibleSinceMs
            }
        }
    }

    func dwellMs() -> Int64 {
        lock.withLock {
            guard started else { return 0 }
            return dwellTotalMs + (foreground ? clock() - visibleSinceMs : 0)
        }
    }
}
