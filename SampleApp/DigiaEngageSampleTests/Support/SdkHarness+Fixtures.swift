import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

/// The SDK is a process singleton and the tests share one app, one window scene and one pasteboard, but Swift
/// Testing runs separate suites in parallel. This lets one test at a time hold them, whatever suite it is in.
actor SdkGate {
    static let shared = SdkGate()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if !held { held = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func leave() {
        if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
    }
}

/// Boots the shared `SdkHarness` (`Tests/DigiaEngageTests/Support/SdkHarness.swift`) on the workspace
/// fixtures, served through `StubBackend` so the SDK's real network client and image pipeline run.
extension SdkHarness {

    /// Boots the SDK serving `campaigns` (the shared workspace fixtures) through `StubBackend`, with a
    /// CEP plugin attached and `content` under the `DigiaHost`. Use `cep.deliver` to fire a campaign.
    static func start<Content: View>(
        _ campaigns: [WorkspaceFixtures.Campaign],
        actionHandlers: DigiaActionHandlers = DigiaActionHandlers(),
        backend: StubBackend.Options = StubBackend.Options(),
        @ViewBuilder content: () -> Content
    ) async throws -> SdkHarness {
        await SdkGate.shared.enter()
        let harness = SdkHarness(campaigns: [])
        harness.servesWorkspaceFixtures = true
        harness.tearDownHooks.append {
            StubBackend.uninstall()
            Task { await SdkGate.shared.leave() }
        }
        // First, so the SDK's network client is built on a configuration that carries the stub.
        StubBackend.install(campaigns: campaigns.map(\.json), options: backend)
        UserDefaults(suiteName: storageSuite)?.removePersistentDomain(forName: storageSuite)
        SDKInstance.shared.resetForTesting()
        do {
            try await Digia.initialize(DigiaConfig(apiKey: "test-api-key", actionHandlers: actionHandlers))
            SDKInstance.shared.register(harness.cep)
        } catch {
            harness.tearDown()
            throw error
        }
        harness.mountFullScreen(content())
        return harness
    }

    /// Mounts [content] as the golden's screen (`ViewImageConfig.engageGolden`: 390x844, safe area 47/34)
    /// whatever simulator runs the test, so the goldens match Flutter's and Android's. The window takes the
    /// size; the hosting controller's insets are corrected to the golden's; and the SDK's lookups of the
    /// screen and key window (`GoldenScreen`, and the floater's `activeFloaterWindowGeometryOverride`) see
    /// the same pair.
    private func mountFullScreen<Content: View>(_ content: Content) {
        let device = ViewImageConfig.engageGolden
        let bounds = CGRect(origin: .zero, size: device.size!)
        let insets = device.safeArea
        activeFloaterWindowGeometryOverride = (
            bounds,
            EdgeInsets(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right)
        )
        tearDownHooks.append { activeFloaterWindowGeometryOverride = nil }

        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.frame = bounds
        let host = UIHostingController(rootView: DigiaHost { content })
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        GoldenScreen.pinSafeArea(of: host)
        #expect(host.view.safeAreaInsets == insets, "the host's safe area is not the golden's 47/34")
        self.window = window
    }

    /// Serves every PiP video from the Test Kit's file through a player that never plays; see `PausedPlayer`.
    func useStillVideo() {
        SDKInstance.shared.floaterOrchestrator.playerFactory = { PausedPlayer(forRemote: $0) }
        tearDownHooks.append { SDKInstance.shared.floaterOrchestrator.playerFactory = nil }
    }
}
