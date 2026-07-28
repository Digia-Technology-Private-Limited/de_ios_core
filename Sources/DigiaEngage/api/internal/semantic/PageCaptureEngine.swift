import UIKit

@MainActor
final class PageCaptureEngine {
    func capture(pageKey: String) async throws -> [String: Any] {
        let window = try await hostWindow()
        let tree = SemanticViewTree.capture(window)
        let image = render(window)
        let screenshot = try encode(image)
        return [
            "schemaVersion": 1,
            "pageKey": pageKey,
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "device": [
                "platform": "ios",
                "apiLevel": UIDevice.current.systemVersion,
                "widthPx": Int(window.bounds.width),
                "heightPx": Int(window.bounds.height),
                "density": window.screen.scale,
            ],
            "screenshot": screenshot,
            "nodes": tree.nodes.map(nodeJson),
        ]
    }

    private func hostWindow() async throws -> UIWindow {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows)
                .first(where: {
                    $0.isKeyWindow
                        && !$0.isHidden
                        && $0.alpha > 0
                        && !$0.bounds.isEmpty
                        && !isPresentingDebugSettings($0.rootViewController)
                }) {
                await nextFrame()
                return window
            }
            await nextFrame()
        }
        throw PageCaptureError.hostWindowUnavailable
    }

    private func isPresentingDebugSettings(_ controller: UIViewController?) -> Bool {
        guard let controller else { return false }
        if controller is DigiaDebugSettingsHostingController { return true }
        if isPresentingDebugSettings(controller.presentedViewController) { return true }
        if let navigation = controller as? UINavigationController {
            return isPresentingDebugSettings(navigation.visibleViewController)
        }
        if let tabs = controller as? UITabBarController {
            return isPresentingDebugSettings(tabs.selectedViewController)
        }
        return controller.children.contains(where: isPresentingDebugSettings)
    }

    private func nextFrame() async {
        try? await Task.sleep(nanoseconds: 16_000_000)
    }

    private func render(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func encode(_ source: UIImage) throws -> [String: Any] {
        let size = scaledSize(source.size)
        let image: UIImage
        if size == source.size {
            image = source
        } else {
            image = UIGraphicsImageRenderer(size: size).image { _ in
                source.draw(in: CGRect(origin: .zero, size: size))
            }
        }
        var encoded: Data?
        for quality in [0.72, 0.64, 0.56, 0.48, 0.40] {
            encoded = image.jpegData(compressionQuality: quality)
            if let encoded, encoded.count <= 900_000 { break }
        }
        guard let encoded, encoded.count <= 1_600_000 else {
            throw PageCaptureError.screenshotTooLarge
        }
        return [
            "mimeType": "image/jpeg",
            "widthPx": Int(size.width),
            "heightPx": Int(size.height),
            "sourceWidthPx": Int(source.size.width),
            "sourceHeightPx": Int(source.size.height),
            "base64": encoded.base64EncodedString(),
        ]
    }

    private func scaledSize(_ source: CGSize) -> CGSize {
        let longest = max(source.width, source.height)
        let scale = min(1, 1080 / longest)
        return CGSize(
            width: max(1, (source.width * scale).rounded()),
            height: max(1, (source.height * scale).rounded())
        )
    }

    private func nodeJson(_ node: SemanticNodeSnapshot) -> [String: Any] {
        var json: [String: Any] = [
            "nodeId": node.nodeId,
            "indexInParent": node.indexInParent,
            "className": node.className,
            "descendantText": node.descendantText,
            "actionable": node.actionable,
            "enabled": node.enabled,
            "visible": node.visible,
        ]
        json["parentId"] = node.parentId
        json["role"] = node.role
        json["resourceId"] = node.resourceId
        json["testId"] = node.testId
        json["text"] = node.text
        json["contentDescription"] = node.contentDescription
        if let bounds = node.bounds {
            json["bounds"] = [
                "left": Int(bounds.minX.rounded()),
                "top": Int(bounds.minY.rounded()),
                "right": Int(bounds.maxX.rounded()),
                "bottom": Int(bounds.maxY.rounded()),
            ]
        }
        return json
    }
}

enum PageCaptureError: LocalizedError {
    case hostWindowUnavailable
    case screenshotTooLarge

    var errorDescription: String? {
        switch self {
        case .hostWindowUnavailable:
            return "The host window did not regain focus after Debug Settings closed."
        case .screenshotTooLarge:
            return "The compressed page screenshot exceeded 1.6 MB."
        }
    }
}
