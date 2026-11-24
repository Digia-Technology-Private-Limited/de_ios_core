import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension HostedUITests {
/// Page & component capture, offered to a plain native app and to the React Native binding
/// (`SDKInstance.isCaptureSupported`). The switch, screen and lists moved to the shared YAML
/// suite (`tests/debug/`, category issue #239); what stays here is wire detail no YAML
/// assertion reads: the envelope binding/platform and the screenshot file part.
@Suite("Capture settings", .serialized, .tags(.integration, .debug, .capture))
@MainActor
struct CaptureSettingsScreenTests {

    private var sdkInstance: SDKInstance { SDKInstance.shared }

    // Fails if: a plain native app's capture is uploaded under any binding but `native`, or
    // stops uploading at all.
    @Test("a plain native app's bubble capture uploads the page as binding native, platform ios")
    func nativeCaptureUpload() async throws {
        let sdk = try await SdkHarness.widgetsBoot()
        defer { sdk.widgetsFinish() }
        let page = "widgets_native_capture_home"
        sdk.network.enqueueResponse(
            url: DigiaEndpoints.recordPageCapture, statusCode: 200,
            body: #"{"data":{"response":{"assetId":"asset-native"}}}"#)
        sdkInstance.setCaptureModeEnabled(true)
        sdk.setCurrentScreen(page)

        try await sdk.widgetsTap(exactly: "Capture current page") { self.sdkInstance.captureStatusMessage != nil }
        try await sdk.waitUntil("the capture to upload", timeout: 8) {
            self.sdkInstance.capturedPages.contains { $0.pageKey == page }
        }

        let upload = try #require(sdk.network.lastMultipartRequest)
        let field = try #require(upload.formFields["capture"], "the envelope is a capture form field")
        let capture = try #require(try JSONSerialization.jsonObject(with: Data(field.utf8)) as? [String: Any])
        #expect(capture["binding"] as? String == "native")
        #expect(capture["platform"] as? String == "ios")
        #expect(capture["pageKey"] as? String == page)
        #expect(upload.files.contains { $0.fileName == "capture.png" }, "the screenshot is uploaded too")
        sdkInstance.clearCaptureStatus()
    }
}
}
