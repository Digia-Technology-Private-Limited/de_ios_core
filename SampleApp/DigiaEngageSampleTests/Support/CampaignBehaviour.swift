import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

/// The campaign behaviour suite's helpers: the analytics chain a real surface sends, read off the wire (`/track`, recorded by `StubBackend`) after the
/// flush rather than off the emitter, beside what the CEP holding the same presentation sees. Helpers over
/// `SdkHarness`, as Android's `support/AnalyticsChain.kt` is over its harness.
///
/// platform note: the Dart twin is `test/campaign_behaviour/support/campaign_behaviour.dart`.
enum Chain {
    static let triggered = "Digia Experience Triggered"
    static let viewed = "Digia Experience Viewed"
    static let clicked = "Digia Experience Clicked"
    static let dismissed = "Digia Experience Dismissed"
    static let completed = "Digia Experience Completed"
    static let dropped = "Digia Experience Dropped"
    static let stepViewed = "Digia Step Viewed"
    static let stepClicked = "Digia Step Clicked"
    static let stepDismissed = "Digia Step Dismissed"
    static let questionViewed = "Digia Question Viewed"
    static let questionAnswered = "Digia Question Answered"
    static let questionSkipped = "Digia Question Skipped"

    /// How many recorded requests came before this test's own: the analytics queue is a database file that
    /// outlives a test, so `initialize` may send an earlier test's leftovers.
    fileprivate static var requestsBefore = 0
}

/// When a presentation hands the CEP's hold back (`PresentationKind`).
enum Hold {
    /// Nudge, survey, guide: held for as long as it shows, released with the outcome.
    case modal
    /// PiP, story floater: released at the impression; it keeps running.
    case floating
    /// An inline slot: released at acceptance, before any impression.
    case inline
}

/// One wire event as `/track` received it.
typealias WireEvent = [String: Any]

/// What the owning CEP saw for one delivered campaign: its signals as they arrive, when its hold came back,
/// and the outcome.
///
/// platform note: the package tests' `PresentationRecorder` does the same; this target cannot see it.
@MainActor
final class Delivery {
    let presentation: CampaignPresentation

    /// Every signal delivered, in order.
    private(set) var signals: [PresentationSignal] = []

    /// `displayed`, `clicked`, `hold` / `hold early` and `outcome`, in the order they arrived.
    private(set) var timeline: [String] = []

    private var unsubscribe: (@MainActor () -> Void)?

    init(_ presentation: CampaignPresentation) {
        self.presentation = presentation
        unsubscribe = presentation.onSignal { [weak self] signal in
            self?.signals.append(signal)
            self?.timeline.append(signal == .displayed ? "displayed" : "clicked")
        }
        // Created in this order, so a hold and an outcome that settle together land in the order they settled.
        Task { [weak self] in
            await presentation.holdReleased.value
            // `hold early` while it is still on screen or pending, `hold` when it came back with the outcome.
            self?.timeline.append(presentation.state == .settled ? "hold" : "hold early")
        }
        Task { [weak self] in
            _ = await presentation.outcome.value
            self?.timeline.append("outcome")
        }
    }

    deinit { MainActor.assumeIsolated { unsubscribe?() } }

    var outcome: PresentationOutcome? { presentation.outcome.settledValue }
    var isHoldReleased: Bool { presentation.holdReleased.isSettled }
    var displayed: Bool { signals.contains(.displayed) }

    var dropReason: DropReason? {
        if case .dropped(let reason, _) = outcome { return reason }
        return nil
    }

    var dismissReason: DismissReason? {
        if case .dismissed(let reason, _) = outcome { return reason }
        return nil
    }
}

extension SdkHarness {
    /// ``start(_:actionHandlers:backend:content:)`` for a chain test: only this test's events reach the wire it reads.
    static func startChain<Content: View>(
        _ campaigns: [WorkspaceFixtures.Campaign], @ViewBuilder content: () -> Content
    ) async throws -> SdkHarness {
        let sdk = try await start(campaigns, content: content)
        // A CTA authored to open a URL must not leave the app: the next test would run in the background.
        ActionPlatform.current = sdk.platform.actionPlatform
        ComponentTestHost.enableAccessibilityAutomation()
        if let analytics = SDKInstance.shared.services?.analyticsService { await analytics.queue.clear() }
        Chain.requestsBefore = StubBackend.requests.count
        return sdk
    }

    /// Delivers `campaignKey` as its CEP would and starts recording what the CEP sees.
    func deliverChain(_ campaignKey: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> Delivery {
        Delivery(try #require(cep.deliver(campaignKey), "no CEP host", sourceLocation: sourceLocation))
    }

    /// `campaignKey`'s experience events as sent, once the queue has flushed. `sdk_health` diagnostics share the
    /// wire but are not in the chain.
    func sent(_ campaignKey: String) async -> [WireEvent] {
        await settle(0.3)
        if let analytics = SDKInstance.shared.services?.analyticsService {
            for _ in 0..<50 {
                analytics.flush()
                await settle(0.1)
                if await analytics.queue.count() == 0 { break }
            }
        }
        return StubBackend.requests.dropFirst(Chain.requestsBefore)
            .filter { $0.url.path.hasSuffix("/track") }
            .flatMap { request -> [WireEvent] in
                guard let body = request.body,
                      let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
                else { return [] }
                return root["events"] as? [WireEvent] ?? []
            }
            .filter {
                $0["campaign_key"] as? String == campaignKey
                    && ($0["event_name"] as? String)?.hasPrefix("Digia ") == true
            }
    }

    /// A real touch at `point`, in window coordinates: a scrim, or a control with nothing to find it by.
    func touch(_ point: CGPoint) async throws {
        try TouchSynthesizer.tap(at: point, in: try #require(window))
        await settle(0.5)
    }

    /// A real one-finger swipe from `start` to `end`, in window coordinates, then time for what it starts to settle.
    func swipe(from start: CGPoint, to end: CGPoint) async throws {
        try TouchSynthesizer.drag(from: start, to: end, in: try #require(window))
        await settle(1)
    }
}

// MARK: - Assertions

/// The properties of the one `name` event in `events`.
func propsOf(_ events: [WireEvent], _ name: String, sourceLocation: SourceLocation = #_sourceLocation)
    -> [String: Any]
{
    let matching = events.filter { $0["event_name"] as? String == name }
    #expect(matching.count == 1, "one \(name)", sourceLocation: sourceLocation)
    return matching.first?["properties"] as? [String: Any] ?? [:]
}

func names(_ events: [WireEvent]) -> [String] { events.compactMap { $0["event_name"] as? String } }

func impressionIds(_ events: [WireEvent]) -> Set<String> {
    Set(events.map { $0["impression_id"] as? String ?? "<none>" })
}

/// Asserts the exact chain `expected`, its one impression id, and an ending `reason` carried by both the
/// Dismissed event and the CEP's outcome. The CEP sees one click per Clicked unless `cepClicks` says otherwise,
/// and gets its hold back when `hold` says.
@MainActor
func expectChain(
    _ events: [WireEvent],
    _ delivery: Delivery,
    names expected: [String],
    reason: DismissReason,
    cepClicks: Int? = nil,
    hold: Hold = .modal,
    // Digia's own `dismiss_reason` where the surface's analytics names are finer than the CEP's:
    // a floater's CTA ends as `cta_taken`, `cta_action` to the CEP.
    wireReason: String? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let cepClickCount = cepClicks ?? expected.filter { $0 == Chain.clicked }.count
    let clicks = Array(repeating: "clicked", count: cepClickCount)
    let timeline: [String]
    switch hold {
    case .modal: timeline = ["displayed"] + clicks + ["hold", "outcome"]
    // A click may land on either side of a floater's early release.
    case .floating: timeline = ["displayed", "hold early"] + clicks + ["outcome"]
    case .inline: timeline = ["hold early", "displayed"] + clicks + ["outcome"]
    }
    #expect(delivery.timeline == timeline, "CEP markings and hold, in order", sourceLocation: sourceLocation)

    #expect(names(events) == expected, sourceLocation: sourceLocation)
    #expect(impressionIds(events) == [delivery.presentation.id], sourceLocation: sourceLocation)

    let ending = propsOf(events, Chain.dismissed, sourceLocation: sourceLocation)
    #expect(ending["dismiss_reason"] as? String == (wireReason ?? reason.wire), sourceLocation: sourceLocation)
    #expect(ending["dwell_ms"] as? Int != nil, sourceLocation: sourceLocation)

    #expect(delivery.dismissReason == reason, sourceLocation: sourceLocation)
}

/// Asserts a delivery that never displayed: Triggered then Dropped carrying `reason`, or nothing at all when
/// `sendsEvents` is false, and the same drop in the CEP's outcome with no marking before it and its hold handed
/// back.
@MainActor
func expectDropped(
    _ events: [WireEvent],
    _ delivery: Delivery,
    _ reason: DropReason,
    sendsEvents: Bool = true,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    if sendsEvents {
        #expect(names(events) == [Chain.triggered, Chain.dropped], sourceLocation: sourceLocation)
        #expect(impressionIds(events) == [delivery.presentation.id], sourceLocation: sourceLocation)
        #expect(
            propsOf(events, Chain.dropped, sourceLocation: sourceLocation)["drop_reason"] as? String
                == reason.wire, sourceLocation: sourceLocation)
    } else {
        #expect(events.isEmpty, sourceLocation: sourceLocation)
    }
    #expect(delivery.timeline == ["hold", "outcome"], "CEP markings and hold, in order", sourceLocation: sourceLocation)
    #expect(delivery.dropReason == reason, sourceLocation: sourceLocation)
}

/// Asserts an inline delivery's exact chain `expected` and impression id, its `cepClicks`, and its hold handed
/// back at acceptance. Inline content sends no Digia Dismissed: when `endedAs` is given, the end reaches the
/// CEP alone; otherwise it is still live in its slot.
@MainActor
func expectInlineChain(
    _ events: [WireEvent],
    _ delivery: Delivery,
    names expected: [String],
    cepClicks: Int = 0,
    endedAs: DismissReason? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(names(events) == expected, sourceLocation: sourceLocation)
    #expect(impressionIds(events) == [delivery.presentation.id], sourceLocation: sourceLocation)
    let timeline = ["hold early", "displayed"] + Array(repeating: "clicked", count: cepClicks)
        + (endedAs == nil ? [] : ["outcome"])
    #expect(delivery.timeline == timeline, "CEP markings and hold, in order", sourceLocation: sourceLocation)
    if let endedAs {
        #expect(delivery.dismissReason == endedAs, sourceLocation: sourceLocation)
    } else {
        #expect(delivery.outcome == nil, sourceLocation: sourceLocation)
    }
}
