import SwiftUI
import SDWebImageSwiftUI

@MainActor
final class VWImage: VirtualLeafStatelessWidget<ImageProps> {
    static func shouldStretchToFillFrame(
        fit: String?,
        hasExplicitWidth: Bool,
        hasExplicitHeight: Bool
    ) -> Bool {
        fit?.lowercased() == "fill" && hasExplicitWidth && hasExplicitHeight
    }

    override func toWidget(_ payload: RenderPayload) -> AnyView {
        toWidget(payload, skipContainerSizing: true)
    }

    override func render(_ payload: RenderPayload) -> AnyView {
        let constraints = resolvedConstraints(payload)
        let widthConstraint = constraints.width
        let heightConstraint = constraints.height

        // wrapInContainer applies padding *around* the rendered image and then
        // frames the total to width×height. To match Flutter's Container layout
        // (where the child receives the inner size after padding is subtracted),
        // pass padding-adjusted dimensions to InternalImageView so the image
        // sizes itself to the inner area rather than the outer container size.
        let paddingInsets = commonProps?.style?.padding?.edgeInsets
        let hPad = (paddingInsets?.leading ?? 0) + (paddingInsets?.trailing ?? 0)
        let vPad = (paddingInsets?.top ?? 0) + (paddingInsets?.bottom ?? 0)

        let adjustedWidth: ResolvedDimension = widthConstraint.value.map { w in
            ResolvedDimension(value: Double(max(0, w - hPad)))
        } ?? widthConstraint

        let adjustedHeight: ResolvedDimension = heightConstraint.value.map { h in
            ResolvedDimension(value: Double(max(0, h - vPad)))
        } ?? heightConstraint

        return AnyView(
            InternalImageView(
                props: props,
                payload: payload,
                widthConstraint: adjustedWidth,
                heightConstraint: adjustedHeight
            )
            // Remote image views can swallow touches from clickable parent containers.
            // Match Flutter by letting parent onClick handlers receive taps.
            .allowsHitTesting(false)
        )
    }

    private func resolvedConstraints(_ payload: RenderPayload) -> (
        width: ResolvedDimension,
        height: ResolvedDimension
    ) {
        let ownWidthConstraint = WidgetUtil.dimension(
            for: commonProps?.style?.width,
            raw: commonProps?.style?.widthRaw,
            payload: payload
        )
        let ownHeightConstraint = WidgetUtil.dimension(
            for: commonProps?.style?.height,
            raw: commonProps?.style?.heightRaw,
            payload: payload
        )

        guard let parentContainer = parent as? VWContainer else {
            return (ownWidthConstraint, ownHeightConstraint)
        }

        let parentWidthConstraint = payload.eval(parentContainer.props.width)
            .map { ResolvedDimension(value: $0) }
        let parentHeightConstraint = payload.eval(parentContainer.props.height)
            .map { ResolvedDimension(value: $0) }

        return (
            parentWidthConstraint ?? ownWidthConstraint,
            parentHeightConstraint ?? ownHeightConstraint
        )
    }
}

private struct InternalImageView: View {
    let props: ImageProps
    let payload: RenderPayload
    let widthConstraint: ResolvedDimension
    let heightConstraint: ResolvedDimension

    @State private var loadFailed = false
    @State private var intrinsicAspectRatio: CGFloat?

    // When images are revisited (e.g. story loops), SwiftUI may recreate the view,
    // which resets `@State`. Cache intrinsic aspect ratios by source to avoid
    // transient/persistent 1:1 fallback that appears as "stretched" content.
    @MainActor private static var aspectRatioCache: [String: CGFloat] = [:]

    var body: some View {
        let source = resolvedSource()
        let alignment = To.alignment(props.alignment) ?? .center

        // SwiftUI's GeometryReader-based approach was causing the image to
        // collapse to ~0 height under shrink-wrapped stacks. Instead, size the
        // image via aspect ratio (from props or intrinsic size when loaded),
        // similar to Flutter's default behavior.
        configured(source: source, alignment: alignment)
            .opacity(payload.eval(props.opacity) ?? 1)
            .onAppear {
                loadFailed = false
            }
            .onChange(of: source, initial: false) { _, _ in
                loadFailed = false
                intrinsicAspectRatio = nil
            }
            // .task runs outside the view body evaluation cycle — mutations here
            // are never "during view update" and never trigger the SwiftUI warning.
            // It cancels and restarts automatically when `source` changes.
            .task(id: source) {
                await resolveImageMetrics(for: source)
            }
    }

    private func resolveImageMetrics(for source: String?) async {
        guard let source, !source.isEmpty, source.hasPrefix("http"),
              let url = URL(string: source) else { return }

        // Serve from cache immediately without hitting the network.
        if let cached = Self.aspectRatioCache[source] {
            intrinsicAspectRatio = cached
            return
        }

        // SDWebImageManager reuses the same memory/disk cache as WebImage,
        // so this never causes a second download.
        let image: UIImage? = await withCheckedContinuation { continuation in
            SDWebImageManager.shared.loadImage(
                with: url,
                options: [.retryFailed, .scaleDownLargeImages],
                progress: nil
            ) { img, _, _, _, finished, _ in
                guard finished else { return }
                continuation.resume(returning: img)
            }
        }

        guard !Task.isCancelled else { return }

        guard let image else {
            loadFailed = true
            return
        }

        loadFailed = false
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : nil
        guard let aspect, aspect.isFinite, aspect > 0 else { return }
        intrinsicAspectRatio = aspect
        Self.aspectRatioCache[source] = aspect
    }

    private func resolvedSource() -> String? {
        payload.eval(props.imageSrc) ?? payload.eval(props.src?.imageSrc)
    }

    private func configured(
        source: String?,
        alignment: Alignment
    ) -> AnyView {
        let fit = props.fit?.lowercased() ?? "none"
        let hasBoundedWidth = widthConstraint.value != nil || widthConstraint.isFill || widthConstraint.percent != nil
        let hasBoundedHeight = heightConstraint.value != nil || heightConstraint.isFill || heightConstraint.percent != nil
        let shouldUseBoundedFrame = hasBoundedWidth && hasBoundedHeight
        let shouldStretchToFillFrame = VWImage.shouldStretchToFillFrame(
            fit: fit,
            hasExplicitWidth: hasBoundedWidth,
            hasExplicitHeight: hasBoundedHeight
        )
        let explicitAspect = payload.eval(props.aspectRatio).map { CGFloat($0) }
        let cachedAspect = source.flatMap { Self.aspectRatioCache[$0] }
        let aspect = explicitAspect ?? intrinsicAspectRatio ?? cachedAspect
        let contentMode: ContentMode = (fit == "cover") ? .fill : .fit
        let shouldClip = (fit == "cover" || fit == "fitwidth" || fit == "fitheight" || fit == "none" || fit == "fill")

        var current: AnyView = baseImage(source: source)

        if shouldUseBoundedFrame {
            // Only apply aspect-ratio scaling when we have a known ratio.
            // Without one (image not yet loaded), skip the modifier so the
            // resizable image fills the bounded frame rather than collapsing
            // to 0 while waiting for the intrinsic size to be resolved.
            if aspect != nil || shouldStretchToFillFrame {
                current = contentSizedView(
                    from: current,
                    aspect: aspect,
                    contentMode: contentMode,
                    shouldStretchToFillFrame: shouldStretchToFillFrame
                )
            }
            current = AnyView(
                current.frame(
                    maxWidth: hasBoundedWidth ? .infinity : nil,
                    maxHeight: hasBoundedHeight ? .infinity : nil,
                    alignment: alignment
                )
            )
        } else if let frame = resolvedFixedFrame(aspect: aspect) {
            current = contentSizedView(
                from: current,
                aspect: aspect,
                contentMode: contentMode,
                shouldStretchToFillFrame: false
            )
            current = AnyView(
                current.frame(
                    width: frame.width,
                    height: frame.height,
                    alignment: alignment
                )
            )
        } else {
            current = contentSizedView(
                from: current,
                aspect: aspect,
                contentMode: contentMode,
                shouldStretchToFillFrame: false
            )
            current = AnyView(
                current.frame(
                    maxWidth: hasBoundedWidth ? .infinity : nil,
                    maxHeight: hasBoundedHeight ? .infinity : nil,
                    alignment: alignment
                )
            )
        }

        // Apply explicit dimensions before clipping so `fit: cover` (and similar
        // modes) clip against the final frame, matching Flutter's behavior.
        if widthConstraint.value != nil || heightConstraint.value != nil {
            current = AnyView(
                current.frame(
                    width: widthConstraint.value,
                    height: heightConstraint.value,
                    alignment: alignment
                )
            )
        }

        if shouldClip {
            current = AnyView(current.clipped())
        }

        return current
    }

    private func contentSizedView(
        from view: AnyView,
        aspect: CGFloat?,
        contentMode: ContentMode,
        shouldStretchToFillFrame: Bool
    ) -> AnyView {
        if shouldStretchToFillFrame {
            return view
        }

        if let aspect {
            return AnyView(view.aspectRatio(aspect, contentMode: contentMode))
        }

        return AnyView(view.aspectRatio(contentMode: contentMode))
    }

    private func resolvedFixedFrame(aspect: CGFloat?) -> (width: CGFloat?, height: CGFloat?)? {
        let fixedWidth = widthConstraint.value
        let fixedHeight = heightConstraint.value

        guard fixedWidth != nil || fixedHeight != nil else { return nil }

        guard let aspect, aspect.isFinite, aspect > 0 else {
            return (fixedWidth, fixedHeight)
        }

        if let fixedWidth, fixedHeight == nil,
           heightConstraint.percent == nil, !heightConstraint.isFill {
            return (fixedWidth, fixedWidth / aspect)
        }

        if let fixedHeight, fixedWidth == nil,
           widthConstraint.percent == nil, !widthConstraint.isFill {
            return (fixedHeight * aspect, fixedHeight)
        }

        return (fixedWidth, fixedHeight)
    }

    private func baseImage(source: String?) -> AnyView {
        guard let source, !source.isEmpty else {
            return placeholderView()
        }

        if loadFailed {
            return errorView()
        }

        guard source.hasPrefix("http"), let url = URL(string: source) else {
            print("[Digia] Invalid or non-network image URL: \(source)")
            return placeholderView()
        }
        let tintColor = resolvedTintColor(for: source)
        return AnyView(remoteImageView(url: url, source: source, tintColor: tintColor))
    }

    @ViewBuilder
    private func placeholderContent() -> some View {
        if let placeholderType = props.placeholder?.lowercased(), !placeholderType.isEmpty {
            switch placeholderType {
            case "network":
                if let src = props.placeholderSrc, src.hasPrefix("http"), let url = URL(string: src) {
                    DigiaCachedImageView(url: url)
                } else {
                    let src = props.placeholderSrc
                    Color.clear.onAppear {
                        if let src { print("[Digia] Invalid or non-network placeholderSrc: \(src)") }
                    }
                }
            case "blurhash":
                Rectangle().fill(Color.gray.opacity(0.2))
            case "lottie":
                Rectangle().fill(Color.clear)
            case "asset":
                Color.clear.onAppear { print("[Digia] Asset placeholder not supported") }
            default:
                Color.clear.onAppear { print("[Digia] Unsupported placeholder type: \(placeholderType)") }
            }
        } else {
            Rectangle().fill(Color.clear)
        }
    }

    private func placeholderView() -> AnyView {
        AnyView(placeholderContent())
    }

    private func errorView() -> AnyView {
        if let errorSrc = props.errorImage?.errorSrc, !errorSrc.isEmpty {
            let tintColor = resolvedTintColor(for: errorSrc)
            guard errorSrc.hasPrefix("http"), let url = URL(string: errorSrc) else {
                print("[Digia] Invalid or non-network errorSrc: \(errorSrc)")
                return AnyView(Color.clear)
            }
            return AnyView(DigiaCachedImageView(url: url, tintColor: tintColor))
        }
        if props.errorImage?.errorEnabled == false {
            return AnyView(EmptyView())
        }
        let fallbackColor = payload.evalColor(props.svgColor) ?? .secondary
        return AnyView(
            Image(systemName: "exclamationmark.triangle")
                .resizable()
                .scaledToFit()
                .foregroundStyle(fallbackColor)
        )
    }

    private func resolvedTintColor(for source: String) -> Color? {
        guard let tintColor = payload.evalColor(props.svgColor) else { return nil }
        return isSVGSource(source) ? tintColor : nil
    }

    private func isSVGSource(_ source: String) -> Bool {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if let url = URL(string: trimmed), let pathExtension = url.pathExtension.nonEmpty {
            return pathExtension.caseInsensitiveCompare("svg") == .orderedSame
        }

        let fileExtension = (trimmed as NSString).pathExtension
        return fileExtension.caseInsensitiveCompare("svg") == .orderedSame
    }

    private func remoteImageView(url: URL, source: String, tintColor: Color?) -> some View {
        // Callbacks removed — aspect ratio and failure are tracked via .task(id: source)
        // in body, which runs outside the view update cycle and avoids the
        // "Modifying state during view update" runtime warning.
        DigiaCachedImageView(url: url, tintColor: tintColor)
    }
}
