import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension RenderedUITests {
/// UIKit screen tracking (`DigiaScreenTracking.swift`): a navigation controller whose delegate is
/// `DigiaNavigationScreenObserver`, and a view controller calling `digiaScreen(_:)`, report the
/// screen the app is on, and a campaign limited to a screen follows it. Fixture:
/// `nudge_dialog/nudge_dialog_screen_change_home_only` (targets `home`).
///
/// Migrated to shared YAML `testkit/sdk-tests/tests/screen/` (category #237):
/// observer naming → `navigation_names.yaml` + `navigation_typename_fallback.yaml` (iOS-only type),
/// digiaScreen → `navigation_names.yaml` (setCurrentScreen path), campaign follows +
/// timeline stamp → `screen_cep_follows_current_screen.yaml` + `screen_tracking_core.yaml`.
/// Kept: empty-campaign mapping (logger unit test, no public API to trigger it).
@Suite("Screen tracking", .serialized, .tags(.integration, .surface, .debug))
@MainActor
struct ScreenTrackingTests {

    // Fails if: DigiaLogger.swift stops mapping an empty campaign to nil
    // (`(campaign?.isEmpty ?? true) ? nil : campaign`) — the timeline would group every
    // campaign-less record under one blank card.
    @Test("an empty campaign key is recorded as no campaign, never as a group")
    func emptyCampaignKeyIsAbsent() {
        let sink = ScreenTrackingCollectingSink()
        DigiaLogger.registerSink(sink)
        defer { DigiaLogger.unregisterSink(sink) }

        DigiaLogger("probe").d("Delivered", campaign: "", stage: .trigger)

        #expect(sink.records.count == 1)
        #expect(sink.records.first?.campaignKey == nil)
    }
}
}

final class ScreenTrackingCollectingSink: DiagnosticSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _records: [TimelineRecord] = []
    var records: [TimelineRecord] { lock.withLock { _records } }
    func accepts(_ record: TimelineRecord) -> Bool { true }
    func emit(_ record: TimelineRecord) { lock.withLock { _records.append(record) } }
}
