// tags: widget nudge campaign_behaviour
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

extension RenderedUITests {
/// Every way a nudge ends — closed, or dropped before it showed — and the exact chain each one sends, beside
/// what the CEP holding it sees. The cases that need a real touch run hosted, in
/// `SampleApp/DigiaEngageSampleTests/CampaignBehaviour/NudgeCampaignBehaviourTests.swift`.
///
/// Scrim and drag closes report `user_close` as coded: the nudge only tells apart the closes it marks
/// beforehand (CTA, auto-dismiss, screen exit).
///
/// platform note: the Dart twin is `test/campaign_behaviour/nudge_campaign_behaviour_test.dart`. Its system-back case has no
/// iOS counterpart: an iOS nudge has no back gesture.
@MainActor
@Suite("Nudge campaign behaviour", .serialized, .tags(.integration, .nudge, .analytics))
struct NudgeCampaignBehaviourTests {
    private let shownThenClosed = [Chain.triggered, Chain.viewed, Chain.dismissed]

    private func fixture(_ name: String) -> WorkspaceFixtures.Campaign {
        WorkspaceFixtures.campaign("campaigns/\(name.split(separator: "_").prefix(2).joined(separator: "_"))/\(name).json")
    }

    private func start(_ campaigns: [WorkspaceFixtures.Campaign]) async throws -> SdkHarness {
        try await SdkHarness.startChain(campaigns) { Text("App home") }
    }

    private func show(_ sdk: SdkHarness, _ text: String) async throws {
        try await sdk.waitUntil("\"\(text)\" on screen") { sdk.isShowing(text) }
    }

    // MARK: - Closed

    @Test("auto-dismiss: dismissed as auto_timeout", .tags(.slow))
    func autoDismiss() async throws {
        let sdk = try await start([fixture("nudge_dialog_auto_dismiss")])
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain("test_nudge_dialog_auto_dismiss")
        try await show(sdk, "Auto Dismiss Dialog")

        // The fixture's autoDismissAfterMs is 5000.
        try await sdk.waitUntil("the dialog has timed out", timeout: 7) { !sdk.isShowing("Auto Dismiss Dialog") }

        expectChain(await sdk.sent("test_nudge_dialog_auto_dismiss"), d, names: shownThenClosed, reason: .autoTimeout)
    }

    @Test("nudge: leaving its screen: dismissed as screen_exit")
    func leavingItsScreen() async throws {
        let key = "test_nudge_dialog_screen_change_home_only"
        let sdk = try await start([fixture("nudge_dialog_screen_change_home_only")])
        defer { sdk.tearDown() }
        Digia.setCurrentScreen(name: "home")
        let d = try sdk.deliverChain(key)
        try await show(sdk, "Dialog Screen Change Home Only")

        Digia.setCurrentScreen(name: "search")
        try await sdk.waitUntil("the dialog is gone") { !sdk.isShowing("Dialog Screen Change Home Only") }

        expectChain(await sdk.sent(key), d, names: shownThenClosed, reason: .screenExit)
    }

    @Test("CEP cancel while showing: dismissed as cancelled")
    func cepCancelWhileShowing() async throws {
        let sdk = try await start([fixture("nudge_dialog")])
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain("test_nudge_dialog")
        try await show(sdk, "Dialog Test Nudge")

        d.presentation.cancel()
        try await sdk.waitUntil("the dialog is gone") { !sdk.isShowing("Dialog Test Nudge") }

        expectChain(await sdk.sent("test_nudge_dialog"), d, names: shownThenClosed, reason: .cancelled)
    }

    @Test("after a CEP cancel, the next nudge shows alone")
    func nextNudgeAfterCepCancel() async throws {
        let sdk = try await start([fixture("nudge_dialog"), fixture("nudge_dialog_backdrop_on")])
        defer { sdk.tearDown() }
        let cancelled = try sdk.deliverChain("test_nudge_dialog")
        try await show(sdk, "Dialog Test Nudge")
        cancelled.presentation.cancel()
        try await sdk.waitUntil("the dialog is gone") { !sdk.isShowing("Dialog Test Nudge") }

        let next = try sdk.deliverChain("test_nudge_dialog_backdrop_on")
        try await show(sdk, "Backdrop Tap Dialog")
        #expect(!sdk.isShowing("Dialog Test Nudge"))
        #expect(next.timeline == ["displayed"])
    }

    // MARK: - Dropped

    @Test("off its target screen: screen_not_targeted")
    func offTargetScreen() async throws {
        let key = "test_nudge_dialog_screen_change_home_only"
        let sdk = try await start([fixture("nudge_dialog_screen_change_home_only")])
        defer { sdk.tearDown() }
        Digia.setCurrentScreen(name: "search")
        let d = try sdk.deliverChain(key)
        try await sdk.settle()
        #expect(!sdk.isShowing("Dialog Screen Change Home Only"))

        expectDropped(await sdk.sent(key), d, .screenNotTargeted)
    }

    @Test("a nudge already up: surface_busy, the incumbent untouched")
    func surfaceBusy() async throws {
        let sdk = try await start([fixture("nudge_dialog"), fixture("nudge_dialog_backdrop_on")])
        defer { sdk.tearDown() }
        let incumbent = try sdk.deliverChain("test_nudge_dialog")
        try await show(sdk, "Dialog Test Nudge")

        let blocked = try sdk.deliverChain("test_nudge_dialog_backdrop_on")
        try await sdk.settle()
        #expect(sdk.isShowing("Dialog Test Nudge"))

        let events = await sdk.sent("test_nudge_dialog_backdrop_on")
        expectDropped(events, blocked, .surfaceBusy)
        #expect(propsOf(events, Chain.dropped)["blocking_campaign_key"] as? String == "test_nudge_dialog")
        #expect(names(await sdk.sent("test_nudge_dialog")) == [Chain.triggered, Chain.viewed])
        #expect(incumbent.outcome == nil)
        #expect(!incumbent.isHoldReleased, "a modal holds while it shows")
    }

    @Test("CEP cancel before it shows: cancelled")
    func cepCancelBeforeShowing() async throws {
        let sdk = try await start([fixture("nudge_dialog")])
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain("test_nudge_dialog")
        d.presentation.cancel()
        try await sdk.settle()
        #expect(!sdk.isShowing("Dialog Test Nudge"))

        expectDropped(await sdk.sent("test_nudge_dialog"), d, .cancelled)
    }

    @Test("a malformed campaign never enters the store: unknown_campaign_key, nothing sent")
    func malformedCampaign() async throws {
        let base = fixture("nudge_dialog")
        var json = base.json
        json["templateConfig"] = ["templateType": "mystery"] as [String: any Sendable]
        let sdk = try await start([WorkspaceFixtures.Campaign(name: base.name, json: json)])
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain("test_nudge_dialog")
        try await sdk.settle()

        expectDropped(await sdk.sent("test_nudge_dialog"), d, .unknownCampaignKey, sendsEvents: false)
    }

    @Test("an unknown key: unknown_campaign_key, nothing sent")
    func unknownKey() async throws {
        let sdk = try await start([fixture("nudge_dialog")])
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain("test_no_such_campaign")
        try await sdk.settle()

        expectDropped(await sdk.sent("test_no_such_campaign"), d, .unknownCampaignKey, sendsEvents: false)
    }

    // MARK: - Dropped before the SDK is ready

    // The SDK knows no campaign yet, so a delivery in these states sends nothing to Digia: only the CEP hears.

    @Test("not_initialized: a nudge delivered before Digia.initialize is dropped and nothing reaches Digia")
    func beforeInitialize() async throws {
        let sdk = try await SdkHarness.startUninitialized()
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain("test_nudge_dialog")
        try await sdk.settle()

        #expect(!sdk.isShowing("Dialog Test Nudge"))
        expectDropped(try await sdk.sentToScriptedNetwork("test_nudge_dialog"), d, .notInitialized, sendsEvents: false)
        #expect(d.dropDetail == "Digia.initialize() has not been called")
    }

    @Test("not_ready: a nudge delivered while the campaign fetch is open is dropped, nothing reaches Digia, and it is not shown once the fetch lands")
    func whileFetchHeld() async throws {
        let sdk = try await SdkHarness.startFetchHeld(fixture("nudge_dialog"))
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain("test_nudge_dialog")
        try await sdk.settle()

        expectDropped(try await sdk.sentToScriptedNetwork("test_nudge_dialog"), d, .notReady, sendsEvents: false)
        #expect(d.dropDetail == "Campaigns are still loading; trigger dropped")

        // Core never holds a trigger: the campaign does not appear when the fetch finishes.
        try await sdk.releaseBundle()
        try await sdk.settle(0.5)
        #expect(!sdk.isShowing("Dialog Test Nudge"))
        #expect(try await sdk.sentToScriptedNetwork("test_nudge_dialog").isEmpty)
    }

    @Test("initialization_failed: a nudge delivered after the campaign fetch failed is dropped and nothing reaches Digia")
    func afterFetchFailed() async throws {
        let sdk = try await SdkHarness.startFetchFailed(fixture("nudge_dialog"))
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain("test_nudge_dialog")
        try await sdk.settle()

        #expect(!sdk.isShowing("Dialog Test Nudge"))
        expectDropped(try await sdk.sentToScriptedNetwork("test_nudge_dialog"), d, .initializationFailed, sendsEvents: false)
        #expect(d.dropDetail == "Campaign fetch failed; trigger dropped")
    }

    // MARK: - A trigger the plugin held

    /// A plugin as the shipped ones are: it buffers what its CEP fires before core is ready, flushes in
    /// `onHostReady`, and settles what the buffer drops. The buffer runs on `clock`, not on wall time.
    @MainActor
    private final class BufferingCep: DigiaCEPPlugin {
        let id = "buffering-cep"
        private(set) var host: DigiaCEPHost?
        private(set) var dropped: [(key: String, reason: DropReason, at: TimeInterval)] = []
        private(set) var flushed: [CampaignPresentation] = []
        private(set) var buffer: PendingPayloadBuffer!

        init(clock: ManualClock) {
            buffer = PendingPayloadBuffer(
                onDrop: { [unowned self] trigger, reason in
                    dropped.append((trigger.campaignKey, reason, clock.elapsed))
                },
                arrivalOrder: false, now: { clock.now }, createTimer: { clock.schedule(after: $0, $1) })
        }

        func attach(host: DigiaCEPHost) { self.host = host }
        func detach() { host = nil }

        func onHostReady() {
            for trigger in buffer.takeAll() { flushed.append(host!.deliver(trigger)) }
        }

        func fire(_ campaignKey: String) {
            buffer.add(CEPTriggerPayload(cepCampaignId: "cep-\(campaignKey)", campaignKey: campaignKey, cepMetadata: [:]))
        }
    }

    /// Time the test moves by hand; timers fire when it reaches them.
    @MainActor
    private final class ManualClock {
        private let start = Date()
        private(set) var elapsed: TimeInterval = 0
        private var timers: [(id: Int, due: TimeInterval, work: @MainActor () -> Void)] = []
        private var nextId = 0
        var now: Date { start.addingTimeInterval(elapsed) }

        func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
            let id = nextId
            nextId += 1
            timers.append((id, elapsed + delay, work))
            return { [weak self] in self?.timers.removeAll { $0.id == id } }
        }

        func advance(to seconds: TimeInterval) {
            elapsed = seconds
            for timer in timers.filter({ $0.due <= seconds }).sorted(by: { $0.due < $1.due }) {
                timers.removeAll { $0.id == timer.id }
                timer.work()
            }
        }
    }

    @Test("pending_expired: a trigger the plugin held for 5 minutes while core was not ready is dropped at exactly 5:00, and nothing reaches Digia")
    func pendingExpired() async throws {
        let key = "test_nudge_dialog"
        let sdk = try await SdkHarness.startFetchHeld(fixture("nudge_dialog"))
        defer { sdk.tearDown() }
        let clock = ManualClock()
        let plugin = BufferingCep(clock: clock)
        Digia.register(plugin)
        try await sdk.waitUntil("the plugin is attached") { plugin.host != nil }
        #expect(plugin.host?.isReady == false)

        plugin.fire(key)
        clock.advance(to: 299)
        #expect(plugin.buffer.length == 1, "still held at 4:59")
        #expect(plugin.dropped.isEmpty)

        clock.advance(to: 300)
        #expect(plugin.dropped.count == 1)
        #expect(plugin.dropped.first?.key == key)
        #expect(plugin.dropped.first?.reason == .pendingExpired)
        #expect(plugin.dropped.first?.at == 300, "dropped at exactly 5:00")
        #expect(plugin.buffer.length == 0)
        #expect(SDKInstance.shared.sdkState == .initializing, "core was still loading throughout")

        // Core comes up and the plugin flushes: nothing is left to deliver.
        try await sdk.releaseBundle()
        try await sdk.waitUntil("the SDK is READY") { SDKInstance.shared.sdkState == .ready }
        try await sdk.settle(0.5)
        #expect(plugin.flushed.isEmpty)
        #expect(SDKInstance.shared.coordinator.liveCount == 0)
        #expect(!sdk.isShowing("Dialog Test Nudge"))
        #expect(try await sdk.sentToScriptedNetwork(key).isEmpty, "nothing was sent to Digia")
    }

    // MARK: - Dropped or ended by the plugin and the watchdog

    // As coded: the SDK has no check for a missing `DigiaHost` (`host_not_mounted` is only the React Native
    // guide renderer's), so a nudge with no host to draw it waits out the 15 s acceptance watchdog and drops
    // `timeout`. This is also the one `timeout` reachable through the CEP flow in real time.
    @Test("timeout: with no DigiaHost mounted a nudge never shows and drops as timeout after 15 s, never host_not_mounted (as coded)", .tags(.slow))
    func noHostMountedTimesOut() async throws {
        let campaign = fixture("nudge_dialog")
        let sdk = try await SdkHarness.startWithoutHost(campaign)
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain("test_nudge_dialog")
        try await sdk.waitUntil("the acceptance watchdog", timeout: 20) { d.outcome != nil }

        #expect(!sdk.isShowing("Dialog Test Nudge"))
        expectDroppedWire(
            try await sdk.sentToScriptedNetwork("test_nudge_dialog"), d, .timeout, campaign, screen: nil,
            extras: ["surface_kind": "nudge", "timeout_ms": 15000, "app_backgrounded": false],
            detail: "never displayed within the acceptance window")
    }

    // As coded: the CEP's outcome is `dismissed(plugin_detached)`; Digia is told nothing and the nudge stays up
    // until the user closes it (the replaced plugin only loses its slot).
    @Test("plugin_detached: replacing the CEP plugin while a nudge shows tells the CEP dismissed plugin_detached and leaves the nudge up (as coded)")
    func pluginDetachedWhileShowing() async throws {
        let campaign = fixture("nudge_dialog")
        let sdk = try await start([campaign])
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain("test_nudge_dialog")
        try await show(sdk, "Dialog Test Nudge")

        Digia.register(FakeCep())
        try await sdk.settle()

        #expect(d.timeline == ["displayed", "hold", "outcome"])
        #expect(d.outcome == .dismissed(reason: .pluginDetached, completed: false))
        #expect(names(await sdk.sent("test_nudge_dialog")) == [Chain.triggered, Chain.viewed])
        #expect(sdk.isShowing("Dialog Test Nudge"), "the nudge stays on screen")
    }
}
}
