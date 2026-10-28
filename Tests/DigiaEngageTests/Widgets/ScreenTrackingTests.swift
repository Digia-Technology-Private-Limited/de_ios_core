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
/// iOS's counterpart of Flutter's `DigiaNavigatorObserver`. Also ports the screen stamp from
/// `flutter/core/test/screen_sink_test.dart` ("stamps the screen the app was on, for staged
/// records only"; "treats an empty campaign key as absent"); the ring and the two gates are
/// already covered by `DigiaLoggerTests`.
@Suite("Screen tracking", .serialized, .tags(.integration, .surface, .debug))
@MainActor
struct ScreenTrackingTests {

    private var currentScreen: String? { SDKInstance.shared.currentScreenForAnchorless }

    /// Boots the home-only nudge over an app whose content is a navigation controller tracked by
    /// the observer, its root screen restored as `home`.
    private func boot() async throws -> (SdkHarness, ScreenTrackingNavigation) {
        let sdk = try await SdkHarness.start(try fixture("nudge_dialog/nudge_dialog_screen_change_home_only"))
        let navigation = ScreenTrackingNavigation()
        try sdk.mount { ScreenTrackingNavigationView(navigation: navigation) }
        try await sdk.waitUntil("the root screen is reported") { self.currentScreen == "home" }
        return (sdk, navigation)
    }

    private static let key = "test_nudge_dialog_screen_change_home_only"

    // Fails if: DigiaScreenTracking.swift `screenName(for:)` stops preferring
    // `restorationIdentifier`, then `title`, then the type name — or the observer's
    // `navigationController(_:didShow:animated:)` stops calling `Digia.setCurrentScreen`.
    @Test("the observer reports each shown screen by restoration id, else title, else type name")
    func observerNamesScreens() async throws {
        let (sdk, navigation) = try await boot()
        defer { sdk.tearDown() }

        let titled = UIViewController()
        titled.title = "Checkout"
        navigation.controller.pushViewController(titled, animated: false)
        try await sdk.waitUntil("Checkout") { self.currentScreen == "Checkout" }

        let both = UIViewController()
        both.title = "Ignored"
        both.restorationIdentifier = "payment"
        navigation.controller.pushViewController(both, animated: false)
        try await sdk.waitUntil("payment") { self.currentScreen == "payment" }

        navigation.controller.pushViewController(ScreenTrackingPlainViewController(), animated: false)
        try await sdk.waitUntil("the type name") { self.currentScreen == "ScreenTrackingPlainViewController" }

        navigation.controller.popToRootViewController(animated: false)
        try await sdk.waitUntil("back home") { self.currentScreen == "home" }
    }

    // Fails if: DigiaScreenTracking.swift `digiaScreen(_:)` stops forwarding to
    // `Digia.setCurrentScreen(name:)`.
    @Test("a view controller reporting itself with digiaScreen sets the current screen")
    func digiaScreenReports() async throws {
        let (sdk, navigation) = try await boot()
        defer { sdk.tearDown() }

        navigation.controller.delegate = nil
        navigation.controller.pushViewController(ScreenTrackingSelfReportingViewController(), animated: false)

        try await sdk.waitUntil("Cart") { self.currentScreen == "Cart" }
    }

    // Fails if: SDKInstance.swift `setCurrentScreen` stops calling
    // `dismissActiveCampaignsNotTargetingCurrentScreen()` on a change, or the screen gate stops
    // dropping a delivery for an untargeted screen.
    @Test("a campaign limited to home follows the tracked screen: shown on home, closed on leaving, refused elsewhere")
    func screenScopedCampaignFollowsNavigation() async throws {
        let (sdk, navigation) = try await boot()
        defer { sdk.tearDown() }

        let first = try sdk.deliver(Self.key)
        try await sdk.waitUntil("the nudge on home") { sdk.sdk.controller.activeNudge != nil }

        let checkout = UIViewController()
        checkout.title = "Checkout"
        navigation.controller.pushViewController(checkout, animated: false)
        try await sdk.waitUntil("the nudge closes on leaving home") { first.dismissReason != nil }
        #expect(first.dismissReason == .screenExit)

        let elsewhere = try sdk.deliver(Self.key)
        try await sdk.waitUntil("the delivery settles") { elsewhere.dropReason != nil }
        #expect(elsewhere.dropReason == .screenNotTargeted)

        navigation.controller.popViewController(animated: false)
        try await sdk.waitUntil("back home") { self.currentScreen == "home" }
        let again = try sdk.deliver(Self.key)
        try await sdk.waitUntil("the nudge on home again") { sdk.sdk.controller.activeNudge != nil }
        #expect(again.dropReason == nil)
    }

    // Fails if: DigiaLogger.swift stops stamping `screenName: stage == nil ? nil :
    // Self.currentScreenName`, or SDKInstance.swift `setCurrentScreen` stops pushing
    // `DigiaLogger.currentScreenName`.
    @Test("a timeline record is stamped with the screen the app was on")
    func timelineRecordCarriesScreen() async throws {
        let (sdk, navigation) = try await boot()
        defer { sdk.tearDown() }
        let checkout = UIViewController()
        checkout.title = "Checkout"
        navigation.controller.pushViewController(checkout, animated: false)
        try await sdk.waitUntil("Checkout") { self.currentScreen == "Checkout" }

        let delivery = try sdk.deliver(Self.key)
        try await sdk.waitUntil("the delivery settles") { delivery.dropReason != nil }

        try await sdk.settle(0.3)
        let record = try #require(sdk.records.last { $0.reason?.wire == DropReason.screenNotTargeted.wire })
        #expect(record.stage != nil)
        #expect(record.screenName == "Checkout")
    }

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

/// Holds the navigation controller the app's content shows, tracked by the observer.
@MainActor
final class ScreenTrackingNavigation {
    let observer = DigiaNavigationScreenObserver()
    let controller: UINavigationController

    init() {
        let root = UIViewController()
        root.title = "Root title"
        root.restorationIdentifier = "home"
        controller = UINavigationController(rootViewController: root)
        controller.delegate = observer
    }
}

private struct ScreenTrackingNavigationView: UIViewControllerRepresentable {
    let navigation: ScreenTrackingNavigation
    func makeUIViewController(context _: Context) -> UINavigationController { navigation.controller }
    func updateUIViewController(_: UINavigationController, context _: Context) {}
}

final class ScreenTrackingPlainViewController: UIViewController {}

final class ScreenTrackingSelfReportingViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        digiaScreen("Cart")
    }
}

final class ScreenTrackingCollectingSink: DiagnosticSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _records: [TimelineRecord] = []
    var records: [TimelineRecord] { lock.withLock { _records } }
    func accepts(_ record: TimelineRecord) -> Bool { true }
    func emit(_ record: TimelineRecord) { lock.withLock { _records.append(record) } }
}
