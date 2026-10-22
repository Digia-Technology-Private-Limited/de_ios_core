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

/// Drives the real SDK the way a customer's app wires it: the campaign comes from the (stubbed) backend,
/// a CEP plugin delivers it, and the real `DigiaHost` renders it in a real window. Only the boundaries
/// outside the SDK are faked: the network (`StubBackend`) and, in `PlatformFakes`, the OS.
///
/// The SDK is a process singleton, so each harness resets it on the way in and out.
@MainActor
final class SdkHarness {
    let cep = FakeCep()
    private(set) var window: UIWindow!
    private let installedStub: Bool

    /// Boots the SDK serving `campaigns`, with a CEP plugin attached and `content` under the `DigiaHost`.
    static func start<Content: View>(
        _ campaigns: [WorkspaceFixtures.Campaign],
        actionHandlers: DigiaActionHandlers = DigiaActionHandlers(),
        backend: StubBackend.Options = StubBackend.Options(),
        @ViewBuilder content: () -> Content
    ) async throws -> SdkHarness {
        await SdkGate.shared.enter()
        let harness = SdkHarness(campaigns: campaigns, backend: backend)
        do {
            try await harness.initialize(actionHandlers: actionHandlers)
        } catch {
            harness.tearDown()
            throw error
        }
        harness.mount(content())
        return harness
    }

    private init(campaigns: [WorkspaceFixtures.Campaign], backend: StubBackend.Options) {
        // First, so the SDK's network client is built on a configuration that carries the stub.
        StubBackend.install(campaigns: campaigns.map(\.json), options: backend)
        UserDefaults(suiteName: "tech.digia.engage")?.removePersistentDomain(forName: "tech.digia.engage")
        SDKInstance.shared.resetForTesting()
        installedStub = true
    }

    private func initialize(actionHandlers: DigiaActionHandlers) async throws {
        try await Digia.initialize(DigiaConfig(apiKey: "test-api-key", actionHandlers: actionHandlers))
        SDKInstance.shared.register(cep)
    }

    private func mount<Content: View>(_ content: Content) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        // Full screen, like the app's own window: the floater and PiP take the screen box and safe area from
        // the app's window, so a smaller test window would be laid out for a screen it is not. The device is
        // pinned in `run-tests.sh`, which pins the screen and its safe area with it.
        window.frame = scene.coordinateSpace.bounds
        let controller = UIHostingController(rootView: DigiaHost { content })
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        self.window = window
    }

    /// Lets the run loop turn for `seconds`, so layout, animations and image loads finish.
    func settle(_ seconds: TimeInterval = 1) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// A real tap on the first thing showing `text`, delivered as a touch the way a finger is.
    func tap(text: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let point = try #require(UIProbe.center(ofText: text, in: window), "nothing on screen shows \"\(text)\"", sourceLocation: sourceLocation)
        try TouchSynthesizer.tap(at: point, in: window)
        await settle(0.5)
    }

    /// Serves every PiP video from the Test Kit's file through a player that never plays; see `PausedPlayer`.
    func useStillVideo() {
        SDKInstance.shared.floaterOrchestrator.playerFactory = { PausedPlayer(forRemote: $0) }
    }

    func tearDown() {
        SDKInstance.shared.floaterOrchestrator.playerFactory = nil
        window?.isHidden = true
        window = nil
        SDKInstance.shared.resetForTesting()
        StubBackend.uninstall()
        Task { await SdkGate.shared.leave() }
    }
}
