import Foundation

/// What one open game window did, for its Dismissed event: the latest chance
/// played or peeked, how many plays landed an outcome, the latest refusal, and
/// how long the game was visible in the foreground after it showed. Fed from
/// the bridge's `http` answers and app foreground changes. Mirrors Android's
/// `GameWindowStats`.
final class GameWindowStats: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: () -> Int64
    private var lastChanceId: String
    private var playCount = 0
    private var lastRefused = ""
    private var started = false
    private var foreground = true
    private var visibleSinceMs: Int64 = 0
    private var dwellTotalMs: Int64 = 0

    init(openChanceId: String, clock: @escaping () -> Int64 = {
        Int64(ProcessInfo.processInfo.systemUptime * 1000)
    }) {
        self.lastChanceId = openChanceId
        self.clock = clock
    }

    var chanceId: String { lock.withLock { lastChanceId } }
    var plays: Int { lock.withLock { playCount } }
    var playRefused: String { lock.withLock { lastRefused } }

    /// One answered bridge `http` call. `response` is the http body
    /// (`{isSuccess, data:{response}}`); only `play` and `peek` count.
    func recordHttp(path: String, request: [String: Any]?, response: Any?) {
        guard path == "play" || path == "peek" else { return }
        lock.withLock {
            if let id = request?["chanceId"] as? String, !id.isEmpty { lastChanceId = id }
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
