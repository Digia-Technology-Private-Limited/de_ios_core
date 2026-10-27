import Foundation
import Testing
@testable import DigiaEngage

/// Port of flutter/core `test/capture_session_upload_test.dart`.
///
/// Unlike Flutter, which sends the envelope as a `capture` form field, iOS sends it as a
/// `capture.json` file part beside the PNG; these tests pin the iOS request as it ships.
@MainActor
@Suite("Capture upload", .tags(.capture, .network, .unit))
struct CaptureUploadTests {
    private let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 1])

    @Test("uploads the envelope and one PNG, and returns the asset id")
    func uploadsEnvelopeAndPNG() async throws {
        let network = MockNetworkClient()
        network.enqueueResponse(body: #"{"isSuccess":true,"data":{"response":{"assetId":"asset-1"}}}"#)
        let envelope = CaptureFixtures.envelope()

        let result = await URLSessionCaptureUploader(networkClient: network).upload(envelope: envelope, png: png)

        #expect(result == .accepted(assetId: "asset-1"))
        #expect(network.multipartRequestCount == 1)
        let request = try #require(network.lastMultipartRequest)
        // The path, not the whole URL: suites running alongside this one may point the endpoint
        // root at a test server.
        #expect(request.url.path == URL(string: DigiaEndpoints.recordPageCapture)?.path)
        #expect(request.formFields.isEmpty)
        #expect(request.files.map(\.fieldName) == ["capture", "file"])

        let capture = request.files[0]
        #expect(capture.fileName == "capture.json")
        #expect(capture.mimeType == "application/json")
        #expect(capture.data == CaptureEnvelopeSerializer.jsonBytes(envelope))

        let file = request.files[1]
        #expect(file.fileName == "capture.png")
        #expect(file.mimeType == "image/png")
        #expect(file.data == png)
    }

    @Test("reads the asset id from data.response or from the top level", arguments: [
        #"{"data":{"response":{"assetId":"asset-1"}}}"#,
        #"{"assetId":"asset-1"}"#,
    ])
    func readsAssetId(body: String) async {
        let network = MockNetworkClient()
        network.enqueueResponse(body: body)

        let result = await URLSessionCaptureUploader(networkClient: network)
            .upload(envelope: CaptureFixtures.envelope(), png: png)

        #expect(result == .accepted(assetId: "asset-1"))
    }

    @Test("reports HTTP, transport and malformed-response failures without throwing")
    func reportsFailures() async {
        let network = MockNetworkClient()
        let uploader = URLSessionCaptureUploader(networkClient: network)
        let envelope = CaptureFixtures.envelope()

        network.enqueueResponse(statusCode: 503, body: "{}")
        #expect(await uploader.upload(envelope: envelope, png: png) == .rejected(.server(status: 503)))

        network.enqueueResponse(body: #"{"data":{}}"#)
        #expect(await uploader.upload(envelope: envelope, png: png) == .rejected(.invalidResponse))

        network.enqueueResponse(body: #"{"data":{"response":{"assetId":""}}}"#)
        #expect(await uploader.upload(envelope: envelope, png: png) == .rejected(.invalidResponse))

        network.simulateTransportError(URLError(.timedOut))
        #expect(await uploader.upload(envelope: envelope, png: png) == .rejected(.transportFailed))
    }

    @Test("a caller can retry after a failed upload and sends identical parts")
    func retrySendsIdenticalParts() async {
        let network = MockNetworkClient()
        network.enqueueResponse(statusCode: 503, body: "{}")
        network.enqueueResponse(body: #"{"isSuccess":true,"data":{"response":{"assetId":"asset-1"}}}"#)
        let uploader = URLSessionCaptureUploader(networkClient: network)
        let envelope = CaptureFixtures.envelope()

        #expect(await uploader.upload(envelope: envelope, png: png) == .rejected(.server(status: 503)))
        #expect(await uploader.upload(envelope: envelope, png: png) == .accepted(assetId: "asset-1"))
        #expect(network.recordedMultipartRequests.count == 2)
        #expect(network.recordedMultipartRequests[0].files.map(\.data)
            == network.recordedMultipartRequests[1].files.map(\.data))
    }
}
