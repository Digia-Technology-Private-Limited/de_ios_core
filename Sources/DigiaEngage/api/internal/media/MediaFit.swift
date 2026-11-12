import Foundation
import SwiftUI

/// How a media item fills its box. Callers map campaign JSON to this; the wrappers (`MediaImage`,
/// `MediaLottie`, `MediaStill`) take it as a flat `fit` parameter and never parse campaigns.
enum MediaFit: String, Sendable, Equatable, Hashable {
    case cover
    case contain
    case fill

    /// The SwiftUI aspect for the fit. `nil` means stretch: the image is resizable with no
    /// aspect constraint (callers that size the wrapper themselves pass `.fill`).
    var contentMode: ContentMode? {
        switch self {
        case .cover: .fill
        case .contain: .fit
        case .fill: nil
        }
    }

    /// The `UIView` content mode for layers that need it (Lottie's animation view).
    var viewContentMode: UIView.ContentMode {
        switch self {
        case .cover: .scaleAspectFill
        case .contain: .scaleAspectFit
        case .fill: .scaleToFill
        }
    }
}
