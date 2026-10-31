import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

/// What the legacy nudge and survey suites do on top of the shared `SdkHarness`: boot the app, read
/// what is on screen, and read what reached the backend (`/track` events, `/recordSubmission`
/// bodies). The touches and typing are the sample app's (`LegacyBehaviourTouch.swift`).
///
/// Compiled into both test targets, as `SdkHarness.swift` is.
extension SdkHarness {

    /// Boots the SDK serving [campaigns] and mounts a plain app under `DigiaHost`.
    static func legacyStart(_ campaigns: [[String: Any]]) async throws -> SdkHarness {
        let sdk = try await start(campaigns: campaigns)
        try sdk.mount { Text("legacy host app") }
        // The analytics queue outlives a test: events an earlier test left queued go out with the
        // first flush here. Send them now and read only what this test's requests carry.
        _ = try await sdk.events()
        legacyRequestBaseline[ObjectIdentifier(sdk)] = sdk.network.recordedRequests.count
        return sdk
    }

    /// The `/track` events sent since ``legacyStart(_:)``, in order.
    func legacyEvents() async throws -> [[String: Any]] {
        sdk.services?.analyticsService?.flush()
        try await settle(0.3)
        let baseline = legacyRequestBaseline[ObjectIdentifier(self)] ?? 0
        return network.recordedRequests.dropFirst(baseline)
            .filter { $0.url.absoluteString == DigiaEndpoints.track }
            .flatMap { request -> [[String: Any]] in
                guard let body = request.body,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let events = json["events"] as? [[String: Any]]
                else { return [] }
                return events
            }
    }

    /// Every text on screen, in tree order: what a failed wait reports.
    func legacyShownTexts() -> [String] {
        guard let window else { return [] }
        var texts: [String] = []
        _ = Self.find(in: window) { object in
            if let text = Self.shownText(of: object), !text.isEmpty { texts.append(text) }
            return false
        }
        return texts
    }

    /// Whether an element whose shown text is exactly [text] is on screen.
    func legacyIsShowingExact(_ text: String) -> Bool {
        guard let window else { return false }
        return Self.find(in: window) { Self.shownText(of: $0) == text } != nil
    }

    // MARK: - Reading the backend

    /// Every `/track` event named [name] for [campaignKey], in order. The analytics queue takes a
    /// moment to accept an event just emitted, so this reads again (for up to 3 s) until one is there.
    func legacyTracked(_ name: String, of campaignKey: String) async throws -> [[String: Any]] {
        var matching: [[String: Any]] = []
        for _ in 0..<10 {
            matching = try await legacyEvents().filter {
                $0["campaign_key"] as? String == campaignKey && $0["event_name"] as? String == name
            }
            if !matching.isEmpty { break }
        }
        return matching
    }

    /// The names of [campaignKey]'s `/track` events once [expected] is among them (or 3 s passed).
    func legacyEventNames(of campaignKey: String, once expected: String) async throws -> [String] {
        _ = try await legacyTracked(expected, of: campaignKey)
        return try await legacyEvents()
            .filter { $0["campaign_key"] as? String == campaignKey }
            .compactMap { $0["event_name"] as? String }
    }

    /// The properties of the only `/track` event named [name]; records an issue unless there is
    /// exactly one.
    func legacyOnly(_ name: String, of campaignKey: String) async throws -> [String: Any] {
        let matching = try await legacyTracked(name, of: campaignKey)
        #expect(matching.count == 1, "exactly one \"\(name)\", got \(matching.count)")
        return matching.first?["properties"] as? [String: Any] ?? [:]
    }

    /// The bodies posted to `/recordSubmission`, in order.
    func legacySubmissions() async throws -> [[String: Any]] {
        try await settle(0.4)
        return network.recordedRequests
            .filter { $0.url.absoluteString == DigiaEndpoints.submission }
            .compactMap { request in
                request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            }
    }
}

/// Per harness, how many requests had gone out when ``SdkHarness/legacyStart(_:)`` returned.
@MainActor private var legacyRequestBaseline: [ObjectIdentifier: Int] = [:]

extension CampaignPresentation {
    /// Whether the showing reached its authored end before it closed; nil until it is dismissed.
    var legacyCompleted: Bool? {
        if case .dismissed(_, let completed) = outcome.settledValue { return completed }
        return nil
    }
}

/// The `payload.responses` entry of a `/recordSubmission` body for [blockId].
func legacyResponse(_ body: [String: Any]?, _ blockId: String) -> [String: Any]? {
    let responses = (body?["payload"] as? [String: Any])?["responses"] as? [[String: Any]]
    return responses?.first { $0["blockId"] as? String == blockId }
}

/// A shared fixture under `campaigns/`, with [edit] applied to its `templateConfig` (or
/// `surveyConfig`): how a test holds a variant of a fixture without adding a fixture file.
func legacyFixture(
    _ path: String, editing key: String = "templateConfig", _ edit: (inout [String: Any]) -> Void
) throws -> [String: Any] {
    var campaign = try fixture(path)
    var config = try #require(campaign[key] as? [String: Any], "\(path) has no \(key)")
    edit(&config)
    campaign[key] = config
    return campaign
}
