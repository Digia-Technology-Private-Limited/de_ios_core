import Foundation

struct TrustedTimeAnchor: Equatable {
    let serverEpochMs: Int64
    let continuousNanoseconds: UInt64

    static func capture(_ serverEpochMs: Int64?) -> TrustedTimeAnchor? {
        // Match the four-digit years supported by timer instants.
        guard let serverEpochMs, (1...253_402_300_799_999).contains(serverEpochMs) else { return nil }
        return TrustedTimeAnchor(
            serverEpochMs: serverEpochMs,
            // Includes device sleep without following wall-clock changes.
            continuousNanoseconds: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        )
    }

    func nowMs() -> Int64 {
        let now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        let elapsed = (max(now, continuousNanoseconds) - continuousNanoseconds) / 1_000_000
        return serverEpochMs + Int64(elapsed)
    }
}

enum TimerCampaignState: String, Equatable { case teaser, running, urgent, ended }

enum TimerInstantSource: Equatable {
    case fixed(Int64)
    case fromVariable(String)

    var sourceName: String {
        switch self { case .fixed: "fixed"; case .fromVariable: "fromVariable" }
    }

    func resolve(_ variables: [String: String]?) -> Int64? {
        switch self {
        case .fixed(let value): value
        case .fromVariable(let token): variables?[token].flatMap(parseOffsetInstantMs)
        }
    }
}

struct StatefulTimerRule: Equatable {
    let id: String
    let state: TimerCampaignState?
    let canvas: CampaignCanvas?
}

struct ResolvedTimerCanvas: Equatable {
    let stateID: String
    let state: TimerCampaignState
    let canvas: CampaignCanvas?
    let remainingSeconds: Int64
    let deadlineSource: String

    var analyticsContext: TimerEventContext {
        TimerEventContext(
            state: stateID,
            secondsRemaining: remainingSeconds,
            deadlineSource: deadlineSource
        )
    }
}

struct StatefulTimerConfig: Equatable {
    let timeAnchor: TrustedTimeAnchor
    let startsAt: TimerInstantSource?
    let deadline: TimerInstantSource
    let urgentBelowSeconds: Int64?
    let rules: [StatefulTimerRule]

    func resolve(_ variables: [String: String]?) -> ResolvedTimerCanvas? {
        guard let deadlineMs = deadline.resolve(variables) else { return nil }
        let startsAtMs = startsAt?.resolve(variables)
        if startsAt != nil && (startsAtMs == nil || startsAtMs! >= deadlineMs) { return nil }
        let now = timeAnchor.nowMs()
        let remainingMs = deadlineMs - now
        let remainingSeconds = (max(0, remainingMs) + 999) / 1_000
        let state: TimerCampaignState
        if let startsAtMs, now < startsAtMs { state = .teaser }
        else if now >= deadlineMs { state = .ended }
        else if let urgentBelowSeconds, remainingSeconds <= urgentBelowSeconds { state = .urgent }
        else { state = .running }
        guard let rule = rules.first(where: { $0.state == nil || $0.state == state })
        else { return nil }
        return ResolvedTimerCanvas(
            stateID: rule.id,
            state: state,
            canvas: rule.canvas,
            remainingSeconds: remainingSeconds,
            deadlineSource: deadline.sourceName
        )
    }

    static func fromJson(
        _ json: [String: Any],
        designTokens: DesignTokenCatalog,
        timeAnchor: TrustedTimeAnchor?
    ) -> StatefulTimerConfig? {
        guard let timeAnchor,
              let stateful = json.object("stateful"),
              stateful.int("version", default: -1) == 1,
              let sources = stateful["sources"] as? [[String: Any]], sources.count == 1,
              let source = sources.first,
              source["kind"] as? String == "timer",
              source["mode"] as? String == "countdown",
              let deadline = parseSource(source.object("deadline"))
        else { return nil }

        let startsAt: TimerInstantSource?
        if source["startsAt"] == nil || source["startsAt"] is NSNull { startsAt = nil }
        else {
            guard let parsed = parseSource(source.object("startsAt")) else { return nil }
            startsAt = parsed
        }
        let urgent: Int64?
        if source["urgentBelowSeconds"] == nil || source["urgentBelowSeconds"] is NSNull {
            urgent = nil
        } else {
            guard let number = source["urgentBelowSeconds"] as? NSNumber else { return nil }
            let value = number.int64Value
            guard number.doubleValue == Double(value), value >= 0 else { return nil }
            urgent = value > 0 ? value : nil
        }

        guard let rawRules = stateful["rules"] as? [[String: Any]], !rawRules.isEmpty else { return nil }
        var rules: [StatefulTimerRule] = []
        for raw in rawRules {
            let whenJSON = raw.object("when")
            let state: TimerCampaignState?
            if let whenJSON {
                guard let rawState = whenJSON["is"] as? String,
                      let parsed = TimerCampaignState(rawValue: rawState)
                else { continue }
                state = parsed
            } else { state = nil }
            let canvas: CampaignCanvas?
            if raw["canvas"] == nil || raw["canvas"] is NSNull { canvas = nil }
            else {
                guard let rawCanvas = raw.object("canvas"),
                      let parsed = try? CampaignCanvasParser(designTokens: designTokens).parse(rawCanvas)
                else { return nil }
                canvas = parsed
            }
            guard let id = raw.nonBlankString("id") else { return nil }
            rules.append(StatefulTimerRule(id: id, state: state, canvas: canvas))
        }
        guard rules.contains(where: { $0.state == nil }) else { return nil }
        return StatefulTimerConfig(
            timeAnchor: timeAnchor,
            startsAt: startsAt,
            deadline: deadline,
            urgentBelowSeconds: urgent,
            rules: rules
        )
    }

    private static func parseSource(_ json: [String: Any]?) -> TimerInstantSource? {
        guard let json, let source = json["source"] as? String else { return nil }
        switch source {
        case "fixed":
            guard let at = json["at"] as? String, let value = parseOffsetInstantMs(at) else { return nil }
            return .fixed(value)
        case "fromVariable":
            guard let token = json.nonBlankString("token") else { return nil }
            return .fromVariable(token)
        default: return nil
        }
    }
}

private func parseOffsetInstantMs(_ raw: String) -> Int64? {
    let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$"#
    guard raw.range(of: pattern, options: .regularExpression) != nil else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = formatter.date(from: raw) ?? {
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }()
    guard let date else { return nil }
    var offsetSeconds = 0
    if !raw.hasSuffix("Z") {
        let offset = raw.suffix(6)
        guard let hours = Int(offset.dropFirst().prefix(2)), hours <= 23,
              let minutes = Int(offset.suffix(2)), minutes <= 59 else { return nil }
        offsetSeconds = (hours * 3_600 + minutes * 60) * (offset.first == "-" ? -1 : 1)
    }
    guard let timeZone = TimeZone(secondsFromGMT: offsetSeconds) else { return nil }
    formatter.timeZone = timeZone
    formatter.formatOptions = [.withInternetDateTime]
    // ISO8601DateFormatter normalizes invalid dates such as February 31.
    guard formatter.string(from: date).prefix(19) == raw.prefix(19) else { return nil }
    return Int64(date.timeIntervalSince1970 * 1_000)
}

/// Space between an inline card and the edges of its slot, in logical pixels.
struct InlineCanvasMargin: Equatable {
    var top: Double = 0
    var right: Double = 0
    var bottom: Double = 0
    var left: Double = 0

    var horizontal: Double { left + right }
    var vertical: Double { top + bottom }
}

/// A free-form inline campaign: an authored Canvas rendered inside a slot.
///
/// The `canvas` block is byte-identical to the one a canvas nudge carries, so it
/// goes through the shared `CampaignCanvasParser` with no inline-specific branch.
/// What is inline-specific is everything around it: which slot it lands in, and
/// the card chrome the host draws.
struct InlineCanvasConfig: Equatable {
    let slotKey: String
    /// The logical width the canvas was authored against. Runtime scale is
    /// `slotWidth / designWidth`, so this is the only number relating authored
    /// coordinates to real ones.
    let designWidth: Double
    var cornerRadius: Double = 0
    var margin: InlineCanvasMargin = .init()
    let canvas: CampaignCanvas
    var statefulTimer: StatefulTimerConfig? = nil
    var variableSchemas: [VariableSchema] = []

    /// Returns nil when the payload is not a usable inline canvas, so the
    /// campaign parser can skip it rather than render a broken card.
    static func fromJson(
        _ json: [String: Any],
        designTokens: DesignTokenCatalog = .empty
    ) -> InlineCanvasConfig? {
        guard let slotKey = json.nonBlankString("slotKey"),
              let canvasJson = json.object("canvas")
        else { return nil }

        // A canvas version this build cannot read. Collapsing the slot is the
        // right failure: the app shows its own content instead of a
        // half-understood card.
        guard let canvas = try? CampaignCanvasParser(designTokens: designTokens).parse(canvasJson)
        else { return nil }

        let marginJson = json.object("layout")?.object("margin") ?? [:]
        let authoredDesignWidth = json.double("designWidth", default: 0).finiteOrZero

        return InlineCanvasConfig(
            slotKey: slotKey,
            // The authored canvas spans the design frame, so its own width is the
            // right fallback when an older payload omits `designWidth`.
            designWidth: authoredDesignWidth > 0 ? authoredDesignWidth : Double(canvas.width),
            cornerRadius: json.double("cornerRadius", default: 0).finiteOrZero,
            margin: InlineCanvasMargin(
                top: marginJson.double("top", default: 0).finiteOrZero,
                right: marginJson.double("right", default: 0).finiteOrZero,
                bottom: marginJson.double("bottom", default: 0).finiteOrZero,
                left: marginJson.double("left", default: 0).finiteOrZero
            ),
            canvas: canvas
        )
    }

    static func fromStatefulJson(
        _ json: [String: Any],
        stateful: StatefulTimerConfig
    ) -> InlineCanvasConfig? {
        guard let slotKey = json.nonBlankString("slotKey"),
              let representative = stateful.rules.compactMap(\.canvas).first
        else { return nil }
        let marginJSON = json.object("layout")?.object("margin") ?? [:]
        let authoredWidth = json.double("designWidth", default: 0).finiteOrZero
        return InlineCanvasConfig(
            slotKey: slotKey,
            designWidth: authoredWidth > 0 ? authoredWidth : Double(representative.width),
            cornerRadius: json.double("cornerRadius", default: 0).finiteOrZero,
            margin: InlineCanvasMargin(
                top: marginJSON.double("top", default: 0).finiteOrZero,
                right: marginJSON.double("right", default: 0).finiteOrZero,
                bottom: marginJSON.double("bottom", default: 0).finiteOrZero,
                left: marginJSON.double("left", default: 0).finiteOrZero
            ),
            canvas: representative,
            statefulTimer: stateful
        )
    }
}

private extension Double {
    var finiteOrZero: Double { isFinite ? self : 0 }
}
