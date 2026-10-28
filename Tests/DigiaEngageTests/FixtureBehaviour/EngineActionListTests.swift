import SwiftUI
import Testing
@testable import DigiaEngage

extension RenderedUITests {
/// An authored action list is read at tap time, so one step the SDK does not understand must cost
/// only that step. Fixture: `engine_action_list_degrades` — a `teleport` step, a string, `null`,
/// `{}`, an `openUrl` with an empty url, an external `openUrl` to `http://[bad`, a legacy `copy`
/// and a legacy `dismiss`.
/// Port of `flutter/core/test/fixture_behaviour/engine_action_list_test.dart`.
@Suite("Engine: action list degrades", .serialized, .tags(.integration, .behaviour, .actions))
@MainActor
struct EngineActionListTests {

    // Fails if the parser stops skipping steps it cannot read: the string/null steps then end the
    // list before the later steps run.
    //
    // Known gap: `EngageActionParser.parse` reads `steps` as `[[String: Any]]`, so one step that is
    // not an object (`"not a step"`, `null`) fails the cast and the whole list parses as empty —
    // the button does nothing. Flutter skips just those steps (`whereType<Map>()`).
    // `withKnownIssue` fails the day iOS skips them, as the cue to drop the wrapper.
    @Test("the steps it understands still run around the ones it does not")
    func understoodStepsStillRun() async throws {
        await withKnownIssue("iOS drops the whole action list when one step is not an object") {
            try await runSteps()
        }
    }

    private func runSteps() async throws {
        let campaign = try fixture("engine/engine_action_list_degrades")
        let opened = Received<String>()
        let sdk = try await SdkHarness.start(
            campaign, actionHandlers: DigiaActionHandlers(openURL: { opened.append($0) }))
        defer { sdk.tearDown() }
        try sdk.mount { Text("host app") }
        try sdk.deliver(keyOf(campaign))
        try await sdk.waitUntil("the sheet is up") { sdk.isShowing("Run Steps") }

        try await sdk.activate(id: "button")
        try await sdk.waitUntil("the legacy dismiss closed the sheet") { sdk.sdk.controller.activeNudge == nil }

        // The empty-url `openUrl` is dropped; the unparsable one is handed to the host as
        // authored, once.
        #expect(opened.values == ["http://[bad"])
        #expect(sdk.platform.copied == ["SAVE20"])
    }
}
}
