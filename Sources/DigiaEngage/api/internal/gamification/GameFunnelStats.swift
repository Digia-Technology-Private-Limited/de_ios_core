import Foundation

/// What one open game window did, for its analytics: its latest chance,
/// how many `/play` requests the skin sent (for `play` vs `play_again`), how many
/// plays landed an outcome, the latest refusal, and how long the game was visible
/// in the foreground after it showed. Fed from
/// the bridge's `http` answers and app foreground changes. Mirrors Android's
/// `GameFunnelStats`.
final class GameFunnelStats: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: () -> Int64
    private var latestChanceId: String
    private var playRequests = 0
    private var playCount = 0
    private var lastRefused = ""
    private var started = false
    private var foreground = true
    private var visibleSinceMs: Int64 = 0
    private var dwellTotalMs: Int64 = 0

    init(chanceId: String, clock: @escaping () -> Int64 = {
        Int64(MonotonicClock.nowMs())
    }) {
        latestChanceId = chanceId
        self.clock = clock
    }

    /// The window's latest chance: the one it opened with, then whichever chance
    /// the last `state`/`play`/`peek` answer named. `state` names the chance the game
    /// will actually play (an older unplayed one can win over a fresh grant); play next
    /// moves it.
    var chanceId: String { lock.withLock { latestChanceId } }

    var plays: Int { lock.withLock { playCount } }
    var playRefused: String { lock.withLock { lastRefused } }

    /// Counts one `/play` request and returns its 1-based number in this window.
    func nextPlayNumber() -> Int {
        lock.withLock {
            playRequests += 1
            return playRequests
        }
    }

    /// One answered bridge `http` call. `request` is the skin's request body, `response`
    /// the http body (`{isSuccess, data:{response}}`); only `state`, `play` and `peek` count.
    func recordHttp(path: String, request: [String: Any]? = nil, response: Any?) {
        guard path == "state" || path == "play" || path == "peek" else { return }
        lock.withLock {
            guard let body = response as? [String: Any],
                  let data = body["data"] as? [String: Any],
                  let answer = data["response"] as? [String: Any] else { return }
            // The answer's chanceId wins; the play answer has none today, so the skin's
            // request body supplies it.
            // A `state` request names the chance it asked about, not the one it answered
            // with, so only its answer counts.
            if let next = answer["chanceId"] as? String, !next.isEmpty {
                latestChanceId = next
            } else if path != "state", let next = request?["chanceId"] as? String, !next.isEmpty {
                latestChanceId = next
            }
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
