import Foundation
import Testing
@testable import DigiaEngage

/// The console line format is a **cross-stack contract**: the same bytes come
/// out of the Dart, Kotlin and Swift cores, and every support instruction ever
/// written says "filter your console for DIGIA and paste". So every expectation
/// below is spelled out longhand — building the expected string from the same
/// pieces the sink uses would pin nothing.
@Suite("DigiaLogger")
struct DigiaLoggerTests {

    private func record(
        _ severity: DigiaLogSeverity,
        _ message: String,
        tag: String = "DIGIA",
        campaignKey: String? = nil,
        stage: TimelineStage? = nil,
        reason: DiagnosticReason? = nil,
        extras: [String: String] = [:],
        cause: String? = nil
    ) -> TimelineRecord {
        TimelineRecord(
            timestamp: Date(timeIntervalSince1970: 0),
            severity: severity,
            tag: tag,
            message: message,
            stage: stage,
            reason: reason,
            campaignKey: campaignKey,
            extras: extras,
            cause: cause
        )
    }

    // MARK: - The frozen console line

    @Test("renders the settled line, badge and level included")
    func consoleLineFormat() {
        #expect(
            ConsoleSink.lines(for: record(.error, "Payload parse failed")) == [
                "🔴 [DIGIA] [ERROR]: Payload parse failed"
            ])
        #expect(
            ConsoleSink.lines(for: record(.warn, "Buffered trigger displaced (by=summer_sale)")) == [
                "🟡 [DIGIA] [WARN]: Buffered trigger displaced (by=summer_sale)"
            ])
        #expect(
            ConsoleSink.lines(for: record(.info, "Campaigns fetched (count=7)")) == [
                "🔵 [DIGIA] [INFO]: Campaigns fetched (count=7)"
            ])
        #expect(
            ConsoleSink.lines(for: record(.debug, "Nudge scheduled")) == [
                "⚪ [DIGIA] [DEBUG]: Nudge scheduled"
            ])
    }

    @Test("renders the campaign slot only when there is a campaign")
    func campaignSlot() {
        #expect(
            ConsoleSink.lines(
                for: record(
                    .debug, "Dropped — frequency capped (policy=1/day)",
                    campaignKey: "summer_sale")) == [
                "⚪ [DIGIA] [DEBUG]: [summer_sale] Dropped — frequency capped (policy=1/day)"
            ])
        // Never an empty `[]` — the slot is omitted entirely.
        #expect(
            ConsoleSink.lines(for: record(.info, "Digia SDK initialized")) == [
                "🔵 [DIGIA] [INFO]: Digia SDK initialized"
            ])
    }

    @Test("renders the tag as DIGIA or DIGIA-<TAG>")
    func tagRendering() {
        #expect(
            ConsoleSink.lines(
                for: record(.info, "Received (cepId=6aabbf01)", tag: "DIGIA-ME", campaignKey: "canvas_new_nudge"))
                == ["🔵 [DIGIA-ME] [INFO]: [canvas_new_nudge] Received (cepId=6aabbf01)"])
        #expect(
            ConsoleSink.lines(
                for: record(.info, "Event fired: \"Digia Experience Viewed\"", tag: "DIGIA-ANALYTICS"))
                == ["🔵 [DIGIA-ANALYTICS] [INFO]: Event fired: \"Digia Experience Viewed\""])
    }

    @Test("a logger's tag becomes its prefix, uppercased")
    func loggerPrefix() {
        // Through the real emit path: a lowerCamelCase tag still renders in the
        // fixed-width shape the column alignment depends on.
        let captured = capture(DigiaLogger("liveTest")) { $0.i("Stream connected (deviceId=abc123)") }
        #expect(captured == ["🔵 [DIGIA-LIVETEST] [INFO]: Stream connected (deviceId=abc123)"])
        #expect(capture(DigiaLogger()) { $0.e("Survey submission post failed") }
            == ["🔴 [DIGIA] [ERROR]: Survey submission post failed"])
    }

    @Test("re-prefixes every line of a multi-line message, slot included")
    func multiLineReprefix() {
        // Without this a console filtered on DIGIA keeps only the first line,
        // and a filter on one campaign loses the rest of that campaign's thread.
        let lines = ConsoleSink.lines(
            for: record(
                .info, "Sync dispatched (DigiaTemplate, DigiaPrimaryAction).\n  Requires a Test Profile.",
                tag: "DIGIA-CT", campaignKey: "summer_sale"))
        #expect(
            lines == [
                "🔵 [DIGIA-CT] [INFO]: [summer_sale] Sync dispatched (DigiaTemplate, DigiaPrimaryAction).",
                "🔵 [DIGIA-CT] [INFO]: [summer_sale]   Requires a Test Profile.",
            ])
    }

    @Test("appends the absorbed failure as cause=")
    func causeSuffix() {
        #expect(
            ConsoleSink.lines(for: record(.error, "Survey submission post failed", cause: "Bad state: offline"))
                == ["🔴 [DIGIA] [ERROR]: Survey submission post failed cause=Bad state: offline"])
    }

    /// Captures what one logger's call renders, without going near `os_log`.
    private func capture(_ logger: DigiaLogger, _ body: (DigiaLogger) -> Void) -> [String] {
        let sink = RecordingSink()
        DigiaLogger.registerSink(sink)
        defer { DigiaLogger.unregisterSink(sink) }
        body(logger)
        return sink.records.flatMap(ConsoleSink.lines(for:))
    }

    // MARK: - The level ladder

    /// The gate compares through an explicit severity mapping, never a raw enum
    /// ordinal — `DigiaLogLevel` grows additively, so a new value lands
    /// wherever back-compat allows and an ordinal would silence the wrong half
    /// of the ladder.
    @Test("maps every configured level onto the severity ladder")
    func levelRanks() {
        #expect(DigiaLogger.rank(of: .none) == -1)
        #expect(DigiaLogger.rank(of: .error) == 0)
        #expect(DigiaLogger.rank(of: .warn) == 1)
        #expect(DigiaLogger.rank(of: .info) == 2)
        #expect(DigiaLogger.rank(of: .debug) == 3)
        // The original name for "everything", kept forever.
        #expect(DigiaLogger.rank(of: .verbose) == DigiaLogger.rank(of: .debug))
    }

    @Test("a level shows itself and everything more severe")
    func levelGatingMatrix() {
        let ladder: [DigiaLogSeverity] = [.error, .warn, .info, .debug]
        let expected: [(DigiaLogLevel, [Bool])] = [
            (.none, [false, false, false, false]),
            (.error, [true, false, false, false]),
            (.warn, [true, true, false, false]),
            (.info, [true, true, true, false]),
            (.debug, [true, true, true, true]),
            (.verbose, [true, true, true, true]),
        ]
        for (level, admits) in expected {
            for (severity, isAdmitted) in zip(ladder, admits) {
                #expect(
                    (severity.rank <= DigiaLogger.rank(of: level)) == isAdmitted,
                    "\(level) should \(isAdmitted ? "" : "not ")admit \(severity)")
            }
        }
    }

    @Test("an unset log level resolves loud outside release")
    func autoLevel() {
        // The simulator is never a production install, so `auto` is `debug`
        // here — which is also the whole point of the default: the developer
        // integrating Engage for the first time sees something.
        #expect(DigiaLogLevel.resolvedAuto == .debug)
        #expect(DigiaConfig(apiKey: "prod_123").isLogLevelExplicit == false)
        #expect(DigiaConfig(apiKey: "prod_123", logLevel: .none).isLogLevelExplicit)
        #expect(DigiaConfig(apiKey: "prod_123", logLevel: .none).logLevel == .none)
    }

    // MARK: - Extras bounds

    /// One unbounded value repeated across a full ring is a leak with a log
    /// statement in front of it, so the bound is per value, not just per record.
    @Test("bounds extras per value and per key count, truncating rather than dropping")
    func extrasBounds() {
        let long = String(repeating: "x", count: 500)
        let bounded = TimelineRecord.boundExtras(["body": long])
        #expect(bounded["body"]?.count == TimelineRecord.maxExtraLength + 1)
        #expect(bounded["body"]?.hasSuffix("…") == true)

        let many = Dictionary(uniqueKeysWithValues: (0..<20).map { ("k\($0)", "v") })
        #expect(TimelineRecord.boundExtras(many).count == TimelineRecord.maxExtras)
        #expect(TimelineRecord.boundExtras(nil).isEmpty)
    }

    // MARK: - The two gates

    /// Severity gates the console; `stage` gates the timeline. A `debug` gating
    /// drop a release console suppresses still reaches the campaign creator's
    /// screen — that independence is the whole design.
    @Test("the screen records on stage alone, at every console level")
    func screenSinkGatesOnStageOnly() {
        let sink = ScreenSink()
        #expect(sink.accepts(record(.debug, "Displayed", stage: .render, reason: TimelineReason.displayed)))
        #expect(sink.accepts(record(.error, "Dropped", stage: .gating, reason: DropReason.frequencyCapped)))
        // Unstaged developer chatter can never leak onto a non-developer screen.
        #expect(!sink.accepts(record(.error, "Action step failed")))
    }

    @Test("the console gates on severity alone")
    func consoleSinkGatesOnSeverityOnly() {
        let silent = ConsoleSink { _ in false }
        #expect(!silent.accepts(record(.error, "Dropped", stage: .gating, reason: DropReason.surfaceBusy)))
        let loud = ConsoleSink { _ in true }
        #expect(loud.accepts(record(.debug, "Nudge scheduled")))
    }

    @Test("the ring drops the oldest record at the boundary")
    func ringBufferWraps() {
        let sink = ScreenSink()
        for index in 0..<(ScreenSink.capacity + 5) {
            sink.emit(record(.debug, "row \(index)", stage: .session, reason: TimelineReason.sdkInitialized))
        }
        let snapshot = sink.snapshot()
        #expect(snapshot.count == ScreenSink.capacity)
        // Newest first: the screen is opened because of the thing that just
        // happened.
        #expect(snapshot.first?.message == "row \(ScreenSink.capacity + 4)")
        #expect(snapshot.last?.message == "row 5")
    }
}

/// Collects records instead of printing them.
private final class RecordingSink: DiagnosticSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TimelineRecord] = []

    var records: [TimelineRecord] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func accepts(_ record: TimelineRecord) -> Bool { true }

    func emit(_ record: TimelineRecord) {
        lock.lock()
        stored.append(record)
        lock.unlock()
    }
}
