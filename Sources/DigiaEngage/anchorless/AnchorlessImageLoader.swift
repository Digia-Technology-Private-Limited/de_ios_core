import UIKit

@MainActor
enum AnchorlessImageLoader {
    private static let cache = NSCache<NSURL, UIImage>()
    private static let imageLoadTimeout: TimeInterval = 3

    static func image(for url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        var request = URLRequest(url: url)
        request.timeoutInterval = imageLoadTimeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              !Task.isCancelled,
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let image = UIImage(data: data)
        else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    static func prefetch(_ url: URL?) {
        guard let url else { return }
        Task { _ = await image(for: url) }
    }
}
