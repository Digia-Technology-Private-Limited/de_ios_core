// Module: capture/transport
//
// One-step PNG multipart transport. It accepts the closed envelope produced by
// capture/evidence and hands the PNG directly to URLSession; no local file,
// retry queue, or encoded image field is introduced.

import Foundation

@MainActor
internal final class URLSessionCaptureUploader: CaptureUploader {
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
        guard png.count <= CaptureLimits.maxPngBytes,
              let captureJSON = CaptureEnvelopeSerializer.jsonBytes(envelope),
              captureJSON.count <= CaptureLimits.maxCaptureJsonBytes
        else {
            return .rejected(png.count > CaptureLimits.maxPngBytes ? .pngTooLarge : .invalidEnvelope)
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
            let id = captureId(from: responseBody)
            if (200..<300).contains(http.statusCode), let id {
                return .accepted(captureId: id)
            }
            if http.statusCode == 409, let id {
                return .duplicate(captureId: id)
            }
            return .rejected(.server(status: http.statusCode))
        } catch {
            // Only the normalized reason crosses the logging boundary. The
            // throwable may contain a host, URL, request body, or headers.
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

    private func captureId(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["captureId"] as? String,
              !id.isEmpty
        else { return nil }
        return id
    }
}
