import Foundation
import Testing
import UIKit
@testable import DigiaEngage

/// `LiveTestService` decides when this device is listening. A wrong decision is silent in both
/// directions: a stream left open on a backgrounded phone holds a presence lease the dashboard
/// keeps offering tests to, and a stream that never reopens makes "Test on device" do nothing.
///
/// The SSE client's own reconnect logic is covered in `NetworkLiveTestSSEClientTests`; this
/// suite covers the service's orchestration of it: toggle, persistence, app lifecycle, device
/// name. Real `UserDefaultsLocalStorage` on a throwaway suite; the transport is the only fake.
///
/// Port of `flutter/core/test/live_test_service_test.dart`. Not ported: "switching off
/// mid-rename leaves no stream behind" — iOS `setDeviceName` stops and restarts synchronously
/// on the main actor, so there is no gap for a toggle to land in.
@Suite("Live test: service", .serialized, .tags(.unit, .debug, .network))
@MainActor
struct NetworkLiveTestServiceTests {

    private let storage = UserDefaultsLocalStorage(
        defaults: UserDefaults(suiteName: "digia.test.livetest.\(UUID().uuidString)")!)
    private let net = NetworkLiveTestTransport()
    private let invocations = Invocations()

    private final class Invocations { var all: [LiveTestInvocation] = [] }

    /// A service as the SDK builds one on `initialize`: fresh object, same storage.
    private func makeService() -> LiveTestService {
        LiveTestService(storage: storage, ackReporter: LiveTestAckReporter(sender: net), networkClient: net)
    }

    private func configure(_ service: LiveTestService, isDebugBuild: Bool = true) {
        service.configure(
            config: DigiaConfig(apiKey: "test-key"),
            deviceId: "device-1",
            isDebugBuild: isDebugBuild,
            onCampaignTest: { [invocations] in invocations.all.append($0) }
        )
    }

    private func configured() -> LiveTestService {
        let service = makeService()
        configure(service)
        return service
    }

    // MARK: - The enabled toggle

    @Test("opens the stream when switched on and closes it when switched off")
    func toggleOpensAndCloses() {
        let service = configured()
        defer { service.stop() }
        #expect(net.openStreams == 0, "disabled by default")

        service.setEnabled(true)
        #expect(net.openStreams == 1)
        #expect(service.connectionState == .connecting)

        service.setEnabled(false)
        // Fails if: setEnabled(false) stops calling client.stop() — the lease stays held.
        #expect(net.openStreams == 0)
        #expect(service.connectionState == .disconnected)
    }

    @Test("a device that was enabled last session connects at configure")
    func enabledLastSessionConnects() {
        // Seeded under the key the service itself reads, so renaming the stored key would strand
        // every enabled device as disabled after an upgrade.
        storage.set(true, forKey: "enabled")

        let service = configured()
        defer { service.stop() }

        #expect(service.isEnabled)
        #expect(net.openStreams == 1)
    }

    @Test("switching on and off each survive a restart")
    func toggleSurvivesRestart() {
        let first = configured()
        first.setEnabled(true)
        first.stop()

        let second = configured()
        // Fails if: setEnabled stops persisting under `enabled`.
        #expect(second.isEnabled)
        #expect(net.openStreams == 1)

        // The mirror: an off that was never written leaves the device listening after a relaunch.
        second.setEnabled(false)
        second.stop()
        let third = configured()
        defer { third.stop() }
        #expect(!third.isEnabled)
        #expect(net.openStreams == 0)
    }

    @Test("a toggle flipped before configure still persists and takes effect at configure")
    func toggleBeforeConfigure() {
        let service = makeService()
        service.setEnabled(true)
        #expect(net.connects == 0, "no client yet")

        configure(service)
        defer { service.stop() }

        // Fails if: setEnabled regains a "configured / debug" guard before persisting — the RN
        // race named in its doc comment then silently loses the toggle.
        #expect(net.openStreams == 1)
    }

    @Test("configuring again replaces the stream instead of doubling it")
    func reconfigureReplacesStream() {
        // The services are rebuilt on every `initialize`; two live streams for one device would
        // deliver every test twice.
        let service = configured()
        defer { service.stop() }
        service.setEnabled(true)

        configure(service)

        // Fails if: configure stops calling stop() first.
        #expect(net.connects == 2)
        #expect(net.openStreams == 1)
    }

    @Test("a release build never connects, even when switched on")
    func releaseBuildNeverConnects() {
        storage.set(true, forKey: "enabled")
        let service = makeService()
        configure(service, isDebugBuild: false)
        defer { service.stop() }

        service.setEnabled(true)

        // Fails if: configure's `guard isDebugBuild` is removed — a production app would hold a
        // live-test lease for every user.
        #expect(net.connects == 0)
    }

    // MARK: - App lifecycle

    @Test("backgrounding drops the stream; returning to the foreground brings it back")
    func lifecycleDropsAndRestores() async {
        let service = configured()
        defer { service.stop() }
        service.setEnabled(true)

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        // Fails if: the background observer stops calling client.stop() — a backgrounded phone
        // keeps a lease the dashboard keeps offering tests to.
        #expect(await networkLiveTestWait { net.openStreams == 0 })

        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        #expect(await networkLiveTestWait { net.openStreams == 1 })
        #expect(net.connects == 2)
    }

    @Test("returning to the foreground while switched off does not connect")
    func foregroundWhileDisabled() async {
        let service = configured()
        defer { service.stop() }

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        await networkLiveTestDrain(0.1)

        // Fails if: the foreground observer drops its `self.isEnabled` check.
        #expect(net.connects == 0)
    }

    @Test("a stopped service no longer reacts to the app lifecycle")
    func stopRemovesObservers() async {
        let service = configured()
        service.setEnabled(true)
        service.stop()

        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        await networkLiveTestDrain(0.1)

        // Fails if: stop() stops removing the foreground observer — an SDK torn down by a
        // re-initialize would reconnect its old client on the next foreground.
        #expect(net.connects == 1)
        #expect(net.openStreams == 0)
    }

    // MARK: - The device name

    @Test("is trimmed, and a blank one clears it")
    func deviceNameNormalized() {
        let service = configured()
        defer { service.stop() }

        service.setDeviceName("  Asha's Pixel  ")
        #expect(service.deviceName == "Asha's Pixel")
        #expect(storage.string(forKey: "device_name") == "Asha's Pixel")

        service.setDeviceName("   ")
        // Fails if: normalizeDeviceName stops mapping blank to nil, or the nil branch stops
        // removing the stored name.
        #expect(service.deviceName == nil)
        #expect(storage.string(forKey: "device_name") == nil)
    }

    @Test("is restored at startup and sent on connect")
    func deviceNameRestored() {
        storage.set("Lab phone 3", forKey: "device_name")
        storage.set(true, forKey: "enabled")

        let service = configured()
        defer { service.stop() }

        #expect(service.deviceName == "Lab phone 3")
        #expect(net.lastConnectBody == ["deviceName": "Lab phone 3"])
    }

    @Test("renaming a connected device reconnects it under the new name")
    func renameReconnects() {
        // The name is captured when the stream opens, so without a reconnect the dashboard keeps
        // showing the old label until the next app launch.
        let service = configured()
        defer { service.stop() }
        service.setEnabled(true)
        #expect(net.connects == 1)

        service.setDeviceName("Renamed")

        #expect(net.connects == 2)
        #expect(net.lastConnectBody == ["deviceName": "Renamed"])
        #expect(net.openStreams == 1, "the old stream must be closed")
    }

    @Test("renaming a disabled device does not connect it")
    func renameWhileDisabled() {
        let service = configured()
        defer { service.stop() }

        service.setDeviceName("Renamed")

        // Fails if: setDeviceName drops its `client?.isRunning == true` guard.
        #expect(net.connects == 0)
    }

    @Test("saving the same name again does not bounce the stream")
    func sameNameNoBounce() {
        let service = configured()
        defer { service.stop() }
        service.setDeviceName("Same")
        service.setEnabled(true)
        #expect(net.connects == 1)

        service.setDeviceName(" Same ")

        // Fails if: setDeviceName compares the raw value instead of the normalized one.
        #expect(net.connects == 1)
    }

    // MARK: - Stream events

    @Test("a campaign_test event reaches the SDK callback; connected and error events do not")
    func campaignTestReachesCallback() async throws {
        let service = configured()
        defer { service.stop() }
        service.setEnabled(true)

        net.send("connected", #"{"sdkConnectionId":"s","deviceId":"d"}"#)
        net.send("campaign_test", #"""
            {"testInvocationId":"inv-1","campaignId":"c1","campaign":{"campaignKey":"k"},"variables":{"a":"b"}}
            """#)
        #expect(await networkLiveTestWait { !invocations.all.isEmpty })

        // The connection state follows the stream.
        #expect(service.connectionState == .connected)
        let received = try #require(invocations.all.first)
        #expect(invocations.all.count == 1)
        #expect(received.testInvocationId == "inv-1")
        #expect(received.campaign?["campaignKey"] as? String == "k")
        #expect(received.variables["a"] as? String == "b")

        net.send("error", #"{"message":"bad device id"}"#)
        #expect(await networkLiveTestWait { service.connectionState == .error })
        // Fails if: configure's onEvent forwards anything but `.campaignTest` to onCampaignTest.
        #expect(invocations.all.count == 1)
    }
}
