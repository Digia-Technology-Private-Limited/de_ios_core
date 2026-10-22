import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

/// Serves the https crop URLs an anchorless guide fetches, so a golden never waits on the network
/// and draws the same picture on every machine. Registered for `URLSession.shared`, which is what
/// the guide overlay loads its crop through.
final class StubCropProtocol: URLProtocol {
    /// The bytes for a URL, or nil to leave the request to the real network.
    nonisolated(unsafe) static var data: ((URL) -> Data?)?

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url, url.scheme == "https" else { return false }
        return data?(url) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let body = Self.data?(url),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Shows an anchorless guide over a plain host screen in the sample app's own window scene, as
/// `DigiaHost` stacks the guide layer. The package test bundle has no scene, so the guide layer
/// there fails every anchorless step with `invalidGeometry`; this host is why these suites live here.
@MainActor
enum AnchorlessGuideHost {

    struct Showing {
        let window: UIWindow
        /// The host screen before the guide started.
        let hostOnly: UIImage
        let end: @MainActor () -> Void
    }

    /// The window's safe area is the iPhone 17 Pro Max's whatever simulator runs the test: an
    /// anchorless step is placed inside it, so the real insets would move the cutout between devices.
    private final class PinnedInsetsWindow: UIWindow {
        override var safeAreaInsets: UIEdgeInsets { ViewImageConfig.iPhone17ProMax.safeArea }
    }

    /// Serves [crop] for every https URL the guide asks for until `end` runs.
    static func show(_ campaign: CampaignModel, crop: @escaping (URL) -> Data?) throws -> Showing {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "No window scene: run in the sample app host")
        let device = ViewImageConfig.iPhone17ProMax
        let size = device.size!

        StubCropProtocol.data = crop
        URLProtocol.registerClass(StubCropProtocol.self)

        let window = PinnedInsetsWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let rootVC = ComponentTestHost.makeDeviceHost(
            device: device,
            style: .solid(UIColor(white: 0.96, alpha: 1)),
            scrimColor: nil,
            showHomeIndicator: false
        )
        let overlayVC = UIHostingController(rootView: GuideOverlayView())
        overlayVC.view.frame = CGRect(origin: .zero, size: size)
        overlayVC.view.backgroundColor = .clear
        rootVC.addChild(overlayVC)
        rootVC.view.addSubview(overlayVC.view)
        overlayVC.didMove(toParent: rootVC)
        window.rootViewController = rootVC
        window.makeKeyAndVisible()
        ComponentTestHost.drainRunLoop(for: 0.2)
        let hostOnly = ComponentTestHost.renderImage(of: window)

        // Anchorless geometry resolves only on the page it was captured on.
        let sdk = SDKInstance.shared
        sdk.setCurrentScreen("home")
        let orchestrator = sdk.guideOrchestrator
        let end: @MainActor () -> Void = {
            // SDKInstance is process-wide; end the showing so the next guide can start.
            orchestrator.dismiss()
            ComponentTestHost.cleanupOverlayWindow(window)
            sdk.setCurrentScreen("")
            URLProtocol.unregisterClass(StubCropProtocol.self)
            StubCropProtocol.data = nil
        }
        // Each campaign its own id, so no dwell carries over from the previous one.
        let started = orchestrator.start(
            campaign,
            payload: CEPTriggerPayload(
                cepCampaignId: "test_anchorless_\(campaign.campaignKey)",
                campaignKey: campaign.campaignKey,
                cepMetadata: [:])
        )
        guard started else {
            end()
            throw GuideNotStarted()
        }
        return Showing(window: window, hostOnly: hostOnly, end: end)
    }

    struct GuideNotStarted: Error {}

    /// Waits (at most 3s) for the window to differ from [image]: a step stays transparent until its
    /// crop has loaded and its callout is measured. Returns whether it did.
    static func waitUntilDrawn(_ window: UIWindow, differingFrom image: UIImage) async throws -> Bool {
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if ComponentTestHost.renderImage(of: window).pngData() != image.pngData() { return true }
        }
        return false
    }
}
