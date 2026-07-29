import Foundation
import Testing
@testable import DigiaEngage

/// Covers `SSEFrameParser` directly — this is the exact logic that had a real
/// bug (see git history / the incident this test suite was added for):
/// `bytes.lines` (`AsyncLineSequence`) silently omits blank lines, so a
/// parser built on it never detects the SSE frame boundary and never
/// dispatches a single event, while the underlying connection still looks
/// healthy externally. These tests feed raw bytes directly, so they'd have
/// caught that regression without needing a live device.
@Suite("SSEFrameParser")
struct SSEFrameParserTests {
    /// Feeds a whole string byte-by-byte and collects every dispatched frame.
    private func parse(_ sse: String) -> [(event: String?, data: String)] {
        var parser = SSEFrameParser()
        var frames: [(event: String?, data: String)] = []
        for byte in Array(sse.utf8) {
            if let frame = parser.feed(byte) {
                frames.append(frame)
            }
        }
        return frames
    }

    @Test("parses a connected event")
    func parsesConnectedEvent() {
        let frames = parse("event: connected\ndata: {\"sdkConnectionId\":\"sdk_1\"}\n\n")

        #expect(frames.count == 1)
        #expect(frames[0].event == "connected")
        #expect(frames[0].data == "{\"sdkConnectionId\":\"sdk_1\"}")
    }

    @Test("parses multiple events in one stream, back to back")
    func parsesMultipleEvents() {
        let frames = parse(
            "event: connected\ndata: {\"a\":1}\n\n"
                + "event: campaign_test\ndata: {\"b\":2}\n\n"
                + "event: error\ndata: {\"message\":\"bad key\"}\n\n"
        )

        #expect(frames.count == 3)
        #expect(frames.map(\.event) == ["connected", "campaign_test", "error"])
        #expect(frames[1].data == "{\"b\":2}")
    }

    @Test("ignores heartbeat comment lines")
    func ignoresHeartbeatComments() {
        let frames = parse(
            "event: connected\ndata: {\"a\":1}\n\n"
                + ": ping\n\n"
                + "event: campaign_test\ndata: {\"b\":2}\n\n"
        )

        #expect(frames.count == 2)
        #expect(frames.map(\.event) == ["connected", "campaign_test"])
    }

    @Test("joins multi-line data fields with a newline")
    func joinsMultiLineData() {
        let frames = parse("event: campaign_test\ndata: line1\ndata: line2\n\n")

        #expect(frames.count == 1)
        #expect(frames[0].data == "line1\nline2")
    }

    @Test("a lone blank line with nothing buffered dispatches no frame")
    func loneBlankLineDispatchesNothing() {
        let frames = parse("\n\n\nevent: connected\ndata: {}\n\n")

        #expect(frames.count == 1)
        #expect(frames[0].event == "connected")
    }

    @Test("handles CRLF line endings")
    func handlesCRLF() {
        let frames = parse("event: connected\r\ndata: {\"a\":1}\r\n\r\n")

        #expect(frames.count == 1)
        #expect(frames[0].event == "connected")
        #expect(frames[0].data == "{\"a\":1}")
    }

    @Test("an event with no data field still dispatches once the event name is set")
    func eventWithNoDataStillDispatches() {
        let frames = parse("event: connected\n\n")

        #expect(frames.count == 1)
        #expect(frames[0].event == "connected")
        #expect(frames[0].data == "")
    }

    @Test("a frame split across many feed() calls one byte at a time still assembles correctly")
    func assemblesAcrossManySingleByteFeeds() {
        // `parse` already feeds one byte per call — this just makes the
        // intent explicit with a payload that spans a realistic number of
        // separate reads.
        let frames = parse("event: campaign_test\ndata: {\"testInvocationId\":\"t1\",\"campaignId\":\"c1\"}\n\n")

        #expect(frames.count == 1)
        #expect(frames[0].event == "campaign_test")
        #expect(frames[0].data.contains("\"testInvocationId\":\"t1\""))
    }
}

@Suite("reconnectDelayMs")
struct ReconnectDelayMsTests {
    @Test("backoff doubles each attempt starting at 1 second")
    func backoffDoubles() {
        #expect(reconnectDelayMs(attempt: 0, jitterMs: 0) == 1000)
        #expect(reconnectDelayMs(attempt: 1, jitterMs: 0) == 2000)
        #expect(reconnectDelayMs(attempt: 2, jitterMs: 0) == 4000)
        #expect(reconnectDelayMs(attempt: 3, jitterMs: 0) == 8000)
        #expect(reconnectDelayMs(attempt: 4, jitterMs: 0) == 16000)
    }

    @Test("backoff caps at 30 seconds and does not keep growing")
    func backoffCaps() {
        #expect(reconnectDelayMs(attempt: 5, jitterMs: 0) == 30000)
        #expect(reconnectDelayMs(attempt: 20, jitterMs: 0) == 30000)
    }

    @Test("jitter is added on top of the base delay")
    func jitterAdded() {
        #expect(reconnectDelayMs(attempt: 0, jitterMs: 500) == 1500)
        #expect(reconnectDelayMs(attempt: 10, jitterMs: 500) == 30500)
    }
}
