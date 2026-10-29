import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

/// The SDK is a process singleton and the tests share one process, one window scene and one pasteboard, but Swift
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
        // First, so a session built from here on (the image pipeline's) carries the stub.
        StubBackend.install(campaigns: campaigns.map(\.json), options: backend)
        UserDefaults(suiteName: storageSuite)?.removePersistentDomain(forName: storageSuite)
        SDKInstance.shared.resetForTesting()
        // `SDKInstance.shared` keeps the client it was built with, and an earlier suite in the process may have
        // built it before `install`; route it through the stub explicitly. `resetForTesting` clears this.
        let stubbed = URLSessionConfiguration.ephemeral
        stubbed.protocolClasses = [StubBackend.self]
        let client = try #require(SDKInstance.shared.networkClient as? URLSessionNetworkClient)
        client.overrideForTesting = URLSessionNetworkClient(
            session: URLSession(configuration: stubbed), sessionIdProvider: { nil }, headerProvider: { [:] })
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

    private func mountFullScreen<Content: View>(_ content: Content) {
        // Full screen, like the app's own window: the floater and PiP take the screen box and safe area from
        // the app's window, so a smaller test window would be laid out for a screen it is not. The package
        // bundle has no host app and so no scene; there the window is the screen's size.
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
        } else {
            window = UIWindow(frame: UIScreen.main.bounds)
        }
        window.rootViewController = UIHostingController(rootView: DigiaHost { content })
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        self.window = window
    }
}
