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
    private let apiKey: String
    private let session: URLSession

    internal init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
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

        let boundary = "DigiaCapture-\(UUID().uuidString)"
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-digia-project-id")

        var body = Data()
        appendPart(name: "capture", contentType: "application/json", data: captureJSON, boundary: boundary, to: &body)
        appendPart(name: "file", fileName: "capture.png", contentType: "image/png", data: png, boundary: boundary, to: &body)
        body.append(Data("--\(boundary)--\r\n".utf8))

        do {
            let (responseBody, response) = try await session.upload(for: request, from: body)
            guard let http = response as? HTTPURLResponse else { return .rejected(.invalidResponse) }
            guard (200..<300).contains(http.statusCode) else {
                return .rejected(.server(status: http.statusCode))
            }
            guard let id = assetId(from: responseBody) else { return .rejected(.invalidResponse) }
            return .accepted(assetId: id)
        } catch {
            return .rejected(.transportFailed)
        }
    }

    private func appendPart(
        name: String,
        fileName: String? = nil,
        contentType: String,
        data: Data,
        boundary: String,
        to body: inout Data
    ) {
        body.append(Data("--\(boundary)\r\n".utf8))
        if let fileName {
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n".utf8))
        } else {
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n".utf8))
        }
        body.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
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
