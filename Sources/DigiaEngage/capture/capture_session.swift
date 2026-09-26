import Foundation

internal enum CaptureUploadRejection: Equatable, Sendable {
    case invalidEnvelope
    case server(status: Int)
    case invalidResponse
    case transportFailed
}

internal enum CaptureUploadResult: Equatable, Sendable {
    case accepted(assetId: String)
    case rejected(CaptureUploadRejection)
}

@MainActor
internal final class URLSessionCaptureUploader {
    private let networkClient: any NetworkClient

    internal init(networkClient: any NetworkClient) {
        self.networkClient = networkClient
    }

    internal func upload(
        envelope: PageCaptureEnvelopeV1,
        png: Data
    ) async -> CaptureUploadResult {
        guard let captureJSON = CaptureEnvelopeSerializer.jsonBytes(envelope) else {
            return .rejected(.invalidEnvelope)
        }
        guard let url = URL(string: DigiaEndpoints.recordPageCapture) else {
            return .rejected(.transportFailed)
        }

        let request = MultipartUploadRequest(
            url: url,
            formFields: [:],
            files: [
                MultipartFilePart(
                    fieldName: "capture",
                    fileName: "capture.json",
                    mimeType: "application/json",
                    data: captureJSON
                ),
                MultipartFilePart(
                    fieldName: "file",
                    fileName: "capture.png",
                    mimeType: "image/png",
                    data: png
                )
            ],
            timeout: 30
        )

        do {
            let response = try await networkClient.executeMultipart(request: request)
            guard (200..<300).contains(response.statusCode) else {
                return .rejected(.server(status: response.statusCode))
            }
            guard let body = response.body, let id = assetId(from: body) else {
                return .rejected(.invalidResponse)
            }
            return .accepted(assetId: id)
        } catch {
            return .rejected(.transportFailed)
        }
    }

    private func assetId(from data: Data) -> String? {
        guard let response = try? JSONDecoder().decode(CaptureUploadResponse.self, from: data) else {
            return nil
        }
        let id = response.data?.response?.assetId ?? response.assetId
        return id?.isEmpty == false ? id : nil
    }
}

private struct CaptureUploadResponse: Decodable {
    let assetId: String?
    let data: CaptureUploadData?
}

private struct CaptureUploadData: Decodable {
    let response: CaptureUploadPayload?
}

private struct CaptureUploadPayload: Decodable {
    let assetId: String?
}
