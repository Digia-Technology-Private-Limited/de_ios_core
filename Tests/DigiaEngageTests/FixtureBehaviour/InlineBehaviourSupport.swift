import Darwin
import SwiftUI
import Testing
@testable import DigiaEngage

// Shared by the inline behaviour suites: the app page that holds a slot, where on it the slot was
// drawn, what the backend received about it, and a server clock frozen at an instant. The touches
// and the story players are the sample app's (`InlineBehaviourTouch.swift`).
//
// Compiled into both test targets, as `SdkHarness.swift` is.

/// Where the slot was laid out, in window points. The story rail and the carousel have no
/// accessibility element per card or dot, so a test taps them by position inside this frame.
@MainActor
final class InlineSlotFrame {
    var frame: CGRect = .null
}

/// The app's page: the slot at the top of the screen, as a customer places a banner row.
struct InlineSlotPage: View {
    let slot: String
    let probe: InlineSlotFrame

    var body: some View {
        VStack(spacing: 0) {
            DigiaSlot(slot) { EmptyView() }
                .background {
                    GeometryReader { proxy in
                        let frame = proxy.frame(in: .global)
                        Color.clear
                            .onAppear { probe.frame = frame }
                            .onChange(of: frame) { probe.frame = $0 }
                    }
                }
            Spacer(minLength: 0)
        }
    }
}

/// One frame of a story as the backend received it: `item_index` of `item_total`.
struct InlineStoryFrame: Equatable, CustomStringConvertible {
    let index: Int
    let total: Int?

    init(_ index: Int, _ total: Int?) {
        self.index = index
        self.total = total
    }

    var description: String { "(\(index), \(total.map(String.init) ?? "nil"))" }
}

extension SdkHarness {

    /// Opens the app with [slot] at the top of its page and returns where it is drawn.
    func mountInlineSlot(_ slot: String) throws -> InlineSlotFrame {
        let probe = InlineSlotFrame()
        try mount { InlineSlotPage(slot: slot, probe: probe) }
        return probe
    }

    /// The tracked event properties of [campaignKey] named [name], in order.
    func inlineEvents(_ name: String, of campaignKey: String) async throws -> [[String: Any]] {
        try await events()
            .filter { $0["campaign_key"] as? String == campaignKey && $0["event_name"] as? String == name }
            .map { $0["properties"] as? [String: Any] ?? [:] }
    }

    /// Polls the backend until [count] events named [name] of [campaignKey] arrived, and returns
    /// them. Records an issue and throws when they do not arrive in time.
    func waitForEvents(_ name: String, of campaignKey: String, count: Int, timeout: TimeInterval = 4) async throws -> [[String: Any]] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let found = try await inlineEvents(name, of: campaignKey)
            if found.count >= count { return found }
            if Date() > deadline {
                Issue.record("Timed out waiting for \(count) \(name) of \(campaignKey); got \(found.count)")
                throw TimedOut()
            }
        }
    }

    /// Every story frame shown so far, as the backend received the `Digia Step Viewed` events.
    func storyFramesShown(_ campaignKey: String) async throws -> [InlineStoryFrame] {
        try await inlineEvents("Digia Step Viewed", of: campaignKey).map {
            InlineStoryFrame($0["item_index"] as? Int ?? -1, $0["item_total"] as? Int)
        }
    }
}

/// A server clock that stands still: `TrustedTimeAnchor.nowMs()` counts time from its monotonic
/// instant, clamped at zero, so an anchor whose instant lies an hour ahead reads [epochMs] for
/// that hour. The Flutter timer tests read the countdown off a fake clock the same way.
func inlineFrozenClock(at date: Date) -> TrustedTimeAnchor {
    TrustedTimeAnchor(
        serverEpochMs: Int64((date.timeIntervalSince1970 * 1000).rounded()),
        continuousNanoseconds: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) + 3_600 * 1_000_000_000
    )
}

func inlineUTC(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
}
