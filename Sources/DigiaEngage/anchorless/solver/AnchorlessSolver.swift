// MARK: - Prepared target

/// The opaque product of `prepare`.
///
/// The rules are `fileprivate` so the whole of the arithmetic is confined to this
/// file; callers outside it can read only the identity fields `anchorless/runtime`
/// needs for the eligibility gate and the presentation host needs for `image` mode.
internal struct PreparedAnchorlessTarget: Sendable {
    internal let variantId: String
    internal let pageKey: String
    internal let devicePlatform: AnchorlessDevicePlatform
    internal let mode: AnchorlessMode
    internal let crop: AnchorlessCropRef?
    internal let horizontalFrame: AnchorlessTargetFrame
    internal let verticalFrame: AnchorlessTargetFrame

    fileprivate let horizontalRule: AnchorlessHorizontalRule
    fileprivate let verticalRule: AnchorlessVerticalRule
    fileprivate let container: PreparedReferenceContainer?
}

/// The Reference Container, kept as rules rather than as a rectangle: it is
/// re-resolved live on every `resolve` and is never a frozen rectangle (§4.4).
fileprivate struct PreparedReferenceContainer: Sendable {
    let horizontalFrame: AnchorlessRootFrame
    let horizontalRule: AnchorlessHorizontalRule
    let verticalFrame: AnchorlessRootFrame
    let verticalRule: AnchorlessVerticalRule
}

// MARK: - Results

internal enum AnchorlessPrepareResult: Sendable {
    case prepared(PreparedAnchorlessTarget, AnchorlessTrace)
    case rejected(AnchorlessFailure, AnchorlessTrace)

    internal var failure: AnchorlessFailure? {
        if case let .rejected(failure, _) = self { return failure }
        return nil
    }

    internal var trace: AnchorlessTrace {
        switch self {
        case let .prepared(_, trace): return trace
        case let .rejected(_, trace): return trace
        }
    }
}

internal enum AnchorlessResolveResult: Sendable {
    case resolved(ResolvedTargetRect, AnchorlessTrace)
    case failed(AnchorlessFailure, AnchorlessTrace)

    internal var rect: ResolvedTargetRect? {
        if case let .resolved(rect, _) = self { return rect }
        return nil
    }

    internal var failure: AnchorlessFailure? {
        if case let .failed(failure, _) = self { return failure }
        return nil
    }

    internal var trace: AnchorlessTrace {
        switch self {
        case let .resolved(_, trace): return trace
        case let .failed(_, trace): return trace
        }
    }
}

// MARK: - Solver

internal enum AnchorlessSolver {

    // MARK: prepare

    /// Everything decidable from the payload alone, decided at delivery time with
    /// no device state.
    ///
    /// - Parameter steps: the campaign's `steps` array, as delivered. A campaign is
    ///   entirely Anchored or entirely Anchorless, so exactly one element is valid
    ///   (§3); anything else is `stepCountInvalid`.
    internal static func prepare(
        steps: [AnchorlessJSONValue],
        platform: AnchorlessDevicePlatform
    ) -> AnchorlessPrepareResult {
        guard steps.count == 1 else {
            return .rejected(.stepCountInvalid, AnchorlessTrace(phase: .prepare, failure: .stepCountInvalid))
        }
        return prepare(target: steps[0], platform: platform)
    }

    /// The single-step form. Identical to `prepare(steps:platform:)` with one
    /// element, and the form the Conformance Vector file exercises — an
    /// `AnchorlessSolverVectorV1` carries one `target` and has no step list.
    internal static func prepare(
        target: AnchorlessJSONValue,
        platform: AnchorlessDevicePlatform
    ) -> AnchorlessPrepareResult {
        // --- target identity -------------------------------------------------
        guard target.objectValue != nil else { return reject(.invalidModel) }

        guard let type = target["type"]?.stringValue, type == "anchorless" else {
            return reject(.unknownTargetType)
        }
        guard let version = target["version"]?.numberValue, version == 1 else {
            return reject(.unknownTargetVersion)
        }

        // --- platform variant selection --------------------------------------
        guard let variants = target["variants"], variants.objectValue != nil else {
            return reject(.invalidModel)
        }
        guard let variant = variants[platform.rawValue], variant.objectValue != nil else {
            return reject(.missingPlatformVariant)
        }
        // `devicePlatform` MUST equal its key in `variants`.
        guard let declaredPlatform = variant["devicePlatform"]?.stringValue,
              declaredPlatform == platform.rawValue
        else {
            return reject(.invalidModel)
        }

        guard let variantId = nonEmptyString(variant["variantId"]),
              let pageKey = nonEmptyString(variant["pageKey"])
        else {
            return reject(.invalidModel)
        }

        // --- unit agreement ---------------------------------------------------
        // Checked before rule numerics: a variant delivered in the wrong unit is
        // `unitMismatch` whatever its rules say.
        guard let unitRaw = variant["logicalUnit"]?.stringValue,
              let unit = AnchorlessLogicalUnit(rawValue: unitRaw)
        else {
            return reject(.invalidModel, variantId: variantId, pageKey: pageKey)
        }
        guard unit == platform.requiredLogicalUnit else {
            return reject(.unitMismatch, variantId: variantId, pageKey: pageKey)
        }

        // --- orientation ------------------------------------------------------
        // The Beta is portrait only; the wire shape admits no other value.
        guard variant["orientation"]?.stringValue == "portrait" else {
            return reject(.invalidModel, variantId: variantId, pageKey: pageKey)
        }

        // --- mode and crop ----------------------------------------------------
        // `mode` absent is rejected, never defaulted.
        guard let modeRaw = target["mode"]?.stringValue,
              let mode = AnchorlessMode(rawValue: modeRaw)
        else {
            return reject(.invalidModel, variantId: variantId, pageKey: pageKey)
        }
        // `null` is still a physically present field. Element mode forbids the
        // field itself, not merely a usable crop value.
        let cropPresent = variant.hasMember("crop")
        switch mode {
        case .image:
            guard cropPresent else { return reject(.invalidModel, variantId: variantId, pageKey: pageKey) }
        case .element:
            guard !cropPresent else { return reject(.invalidModel, variantId: variantId, pageKey: pageKey) }
        }
        var crop: AnchorlessCropRef?
        if cropPresent {
            guard let parsed = parseCrop(variant["crop"]) else {
                return reject(.invalidModel, variantId: variantId, pageKey: pageKey)
            }
            crop = parsed
        }

        // --- axis frames and container wiring ---------------------------------
        // Structural container checks run before rule numerics so that a dangling
        // container is reported as such rather than as whatever its rules contain.
        guard let horizontalAxis = variant["horizontal"], horizontalAxis.objectValue != nil,
              let verticalAxis = variant["vertical"], verticalAxis.objectValue != nil
        else {
            return reject(.invalidModel, variantId: variantId, pageKey: pageKey)
        }
        guard let horizontalFrameRaw = horizontalAxis["frame"]?.stringValue,
              let horizontalFrame = AnchorlessTargetFrame(rawValue: horizontalFrameRaw),
              let verticalFrameRaw = verticalAxis["frame"]?.stringValue,
              let verticalFrame = AnchorlessTargetFrame(rawValue: verticalFrameRaw)
        else {
            return reject(.invalidModel, variantId: variantId, pageKey: pageKey)
        }

        let containerJSON = variant["referenceContainer"]
        let referencesContainer = horizontalFrame == .referenceContainer
            || verticalFrame == .referenceContainer

        // A target axis naming `referenceContainer` requires the container present.
        // A delivered container no axis references is invalid, not ignored.
        guard (containerJSON != nil) == referencesContainer else {
            return reject(.danglingReferenceContainer, variantId: variantId, pageKey: pageKey)
        }

        var container: PreparedReferenceContainer?
        if let containerJSON {
            guard containerJSON.objectValue != nil,
                  let containerHorizontal = containerJSON["horizontal"], containerHorizontal.objectValue != nil,
                  let containerVertical = containerJSON["vertical"], containerVertical.objectValue != nil,
                  let containerHorizontalFrameRaw = containerHorizontal["frame"]?.stringValue,
                  let containerVerticalFrameRaw = containerVertical["frame"]?.stringValue
            else {
                return reject(.invalidModel, variantId: variantId, pageKey: pageKey)
            }
            // The container's own axes name only `window` or `appContent`, never itself.
            guard let containerHorizontalFrame = AnchorlessRootFrame(rawValue: containerHorizontalFrameRaw),
                  let containerVerticalFrame = AnchorlessRootFrame(rawValue: containerVerticalFrameRaw)
            else {
                let selfReferential = containerHorizontalFrameRaw == AnchorlessTargetFrame.referenceContainer.rawValue
                    || containerVerticalFrameRaw == AnchorlessTargetFrame.referenceContainer.rawValue
                return reject(
                    selfReferential ? .danglingReferenceContainer : .invalidModel,
                    variantId: variantId,
                    pageKey: pageKey
                )
            }

            switch parseHorizontalRule(containerHorizontal["rule"]) {
            case let .failure(code):
                return reject(code, variantId: variantId, pageKey: pageKey)
            case let .success(containerHorizontalRule):
                switch parseVerticalRule(containerVertical["rule"]) {
                case let .failure(code):
                    return reject(code, variantId: variantId, pageKey: pageKey)
                case let .success(containerVerticalRule):
                    container = PreparedReferenceContainer(
                        horizontalFrame: containerHorizontalFrame,
                        horizontalRule: containerHorizontalRule,
                        verticalFrame: containerVerticalFrame,
                        verticalRule: containerVerticalRule
                    )
                }
            }
        }

        // --- rule kinds and numerics ------------------------------------------
        let horizontalRule: AnchorlessHorizontalRule
        switch parseHorizontalRule(horizontalAxis["rule"]) {
        case let .failure(code): return reject(code, variantId: variantId, pageKey: pageKey)
        case let .success(rule): horizontalRule = rule
        }

        let verticalRule: AnchorlessVerticalRule
        switch parseVerticalRule(verticalAxis["rule"]) {
        case let .failure(code): return reject(code, variantId: variantId, pageKey: pageKey)
        case let .success(rule): verticalRule = rule
        }

        let prepared = PreparedAnchorlessTarget(
            variantId: variantId,
            pageKey: pageKey,
            devicePlatform: platform,
            mode: mode,
            crop: crop,
            horizontalFrame: horizontalFrame,
            verticalFrame: verticalFrame,
            horizontalRule: horizontalRule,
            verticalRule: verticalRule,
            container: container
        )
        return .prepared(prepared, AnchorlessTrace(
            phase: .prepare,
            variantId: variantId,
            pageKey: pageKey,
            horizontalFrame: horizontalFrame,
            verticalFrame: verticalFrame
        ))
    }

    // MARK: resolve

    /// Rule arithmetic against one atomically-read snapshot (§4).
    internal static func resolve(
        prepared: PreparedAnchorlessTarget,
        snapshot: RuntimeGeometrySnapshot
    ) -> AnchorlessResolveResult {
        func fail(_ code: AnchorlessFailure, pre: FrameRect? = nil, post: ResolvedTargetRect? = nil) -> AnchorlessResolveResult {
            .failed(code, AnchorlessTrace(
                phase: .resolve,
                failure: code,
                variantId: prepared.variantId,
                pageKey: prepared.pageKey,
                horizontalFrame: prepared.horizontalFrame,
                verticalFrame: prepared.verticalFrame,
                preRoundingRect: pre,
                postRoundingRect: post
            ))
        }

        // The Reference Container is re-resolved live, against its own root frames.
        // Its edges are NOT rounded — only the final target edges are (§4.4/§4.5).
        var containerHorizontal: (near: Double, far: Double)?
        var containerVertical: (near: Double, far: Double)?
        if let container = prepared.container {
            let horizontalFrame = rootFrame(container.horizontalFrame, in: snapshot)
            let horizontalSpan = mapHorizontal(
                span: horizontalSpan(container.horizontalRule, extent: horizontalFrame.width),
                frame: horizontalFrame
            )
            let verticalFrame = rootFrame(container.verticalFrame, in: snapshot)
            let verticalOffsets = verticalSpan(
                container.verticalRule,
                extent: verticalFrame.height,
                frameWidth: verticalFrame.width
            )
            containerHorizontal = horizontalSpan
            containerVertical = (
                near: verticalFrame.top + verticalOffsets.near,
                far: verticalFrame.top + verticalOffsets.far
            )
        }

        // Horizontal and vertical frames are chosen independently (§4.4).
        let horizontalBounds: (near: Double, far: Double)
        switch prepared.horizontalFrame {
        case .window: horizontalBounds = (snapshot.window.left, snapshot.window.right)
        case .appContent: horizontalBounds = (snapshot.appContent.left, snapshot.appContent.right)
        case .referenceContainer:
            guard let containerHorizontal else { return fail(.rectOutsideFrame) }
            horizontalBounds = containerHorizontal
        }
        let verticalBounds: (near: Double, far: Double)
        let verticalFrameWidth: Double
        switch prepared.verticalFrame {
        case .window:
            verticalBounds = (snapshot.window.top, snapshot.window.bottom)
            verticalFrameWidth = snapshot.window.width
        case .appContent:
            verticalBounds = (snapshot.appContent.top, snapshot.appContent.bottom)
            verticalFrameWidth = snapshot.appContent.width
        case .referenceContainer:
            guard let containerVertical, let containerHorizontal else {
                return fail(.rectOutsideFrame)
            }
            verticalBounds = containerVertical
            verticalFrameWidth = containerHorizontal.far - containerHorizontal.near
        }

        let horizontalFrameRect = FrameRect(
            left: horizontalBounds.near, top: 0, right: horizontalBounds.far, bottom: 0
        )
        let mapped = mapHorizontal(
            span: horizontalSpan(prepared.horizontalRule, extent: horizontalBounds.far - horizontalBounds.near),
            frame: horizontalFrameRect
        )
        let verticalOffsets = verticalSpan(
            prepared.verticalRule,
            extent: verticalBounds.far - verticalBounds.near,
            frameWidth: verticalFrameWidth
        )

        let pre = FrameRect(
            left: mapped.near,
            top: verticalBounds.near + verticalOffsets.near,
            right: mapped.far,
            bottom: verticalBounds.near + verticalOffsets.far
        )

        // Each final edge is rounded exactly once. Width and height are derived
        // from the rounded edges, never rounded independently (§4.5).
        guard let left = roundEdge(pre.left),
              let top = roundEdge(pre.top),
              let right = roundEdge(pre.right),
              let bottom = roundEdge(pre.bottom)
        else {
            return fail(.rectOutsideFrame, pre: pre)
        }
        let rect = ResolvedTargetRect(left: left, top: top, right: right, bottom: bottom)

        // Post-resolution validation, in this order (§4.6).
        guard rect.right > rect.left, rect.bottom > rect.top else {
            return fail(.nonPositiveRect, pre: pre, post: rect)
        }
        let rawContainedInOwnFrame = pre.left >= horizontalBounds.near
            && pre.right <= horizontalBounds.far
            && pre.top >= verticalBounds.near
            && pre.bottom <= verticalBounds.far
        let rawContainedInWindow = pre.left >= snapshot.window.left
            && pre.right <= snapshot.window.right
            && pre.top >= snapshot.window.top
            && pre.bottom <= snapshot.window.bottom
        guard let roundedHorizontalNear = roundEdge(horizontalBounds.near),
              let roundedHorizontalFar = roundEdge(horizontalBounds.far),
              let roundedVerticalNear = roundEdge(verticalBounds.near),
              let roundedVerticalFar = roundEdge(verticalBounds.far),
              let roundedWindowLeft = roundEdge(snapshot.window.left),
              let roundedWindowTop = roundEdge(snapshot.window.top),
              let roundedWindowRight = roundEdge(snapshot.window.right),
              let roundedWindowBottom = roundEdge(snapshot.window.bottom)
        else {
            return fail(.rectOutsideFrame, pre: pre, post: rect)
        }
        let containedInOwnFrame = rect.left >= roundedHorizontalNear
            && rect.right <= roundedHorizontalFar
            && rect.top >= roundedVerticalNear
            && rect.bottom <= roundedVerticalFar
        let containedInWindow = rect.left >= roundedWindowLeft
            && rect.right <= roundedWindowRight
            && rect.top >= roundedWindowTop
            && rect.bottom <= roundedWindowBottom
        guard rawContainedInOwnFrame, rawContainedInWindow,
              containedInOwnFrame, containedInWindow else {
            return fail(.rectOutsideFrame, pre: pre, post: rect)
        }

        return .resolved(rect, AnchorlessTrace(
            phase: .resolve,
            variantId: prepared.variantId,
            pageKey: prepared.pageKey,
            horizontalFrame: prepared.horizontalFrame,
            verticalFrame: prepared.verticalFrame,
            preRoundingRect: pre,
            postRoundingRect: rect
        ))
    }
}

// MARK: - Arithmetic (§4.2, §4.3, §4.5)

extension AnchorlessSolver {

    /// Horizontal rules, in start-origin `u` space (§4.2).
    fileprivate static func horizontalSpan(
        _ rule: AnchorlessHorizontalRule,
        extent: Double
    ) -> (near: Double, far: Double) {
        switch rule {
        case let .startFixed(startOffset, width):
            return (startOffset, startOffset + width)
        case let .endFixed(endOffset, width):
            return (extent - endOffset - width, extent - endOffset)
        case let .centered(width):
            return ((extent - width) / 2, (extent + width) / 2)
        case let .stretch(startInset, endInset):
            return (startInset, extent - endInset)
        case let .proportional(startFraction, endFraction):
            return (startFraction * extent, endFraction * extent)
        }
    }

    /// Vertical rules, in top-origin space (§4.3). Vertical axes always run from
    /// physical top to physical bottom; there is no mirroring.
    fileprivate static func verticalSpan(
        _ rule: AnchorlessVerticalRule,
        extent: Double,
        frameWidth: Double
    ) -> (near: Double, far: Double) {
        switch rule {
        case let .topFixed(topOffset, height):
            return (topOffset, topOffset + height)
        case let .bottomFixed(bottomOffset, height):
            return (extent - bottomOffset - height, extent - bottomOffset)
        case let .centered(height):
            return ((extent - height) / 2, (extent + height) / 2)
        case let .stretch(topInset, bottomInset):
            return (topInset, extent - bottomInset)
        case let .proportional(topFraction, bottomFraction):
            return (topFraction * extent, bottomFraction * extent)
        case let .widthScaled(topRatio, height):
            let top = topRatio * frameWidth
            return (top, top + height)
        }
    }

    /// Maps an LTR horizontal span into frame coordinates. RTL is unsupported in v1.
    fileprivate static func mapHorizontal(
        span: (near: Double, far: Double),
        frame: FrameRect
    ) -> (near: Double, far: Double) {
        (frame.left + span.near, frame.left + span.far)
    }

    fileprivate static func rootFrame(
        _ frame: AnchorlessRootFrame,
        in snapshot: RuntimeGeometrySnapshot
    ) -> FrameRect {
        switch frame {
        case .window: return snapshot.window
        case .appContent: return snapshot.appContent
        }
    }

    /// `floor(edge + 0.5)`, applied exactly once per final edge.
    ///
    /// Returns `nil` for a non-finite or unrepresentable edge; the caller turns
    /// that into `rectOutsideFrame`, which is what such an edge is.
    fileprivate static func roundEdge(_ edge: Double) -> Int? {
        guard edge.isFinite else { return nil }
        let rounded = (edge + 0.5).rounded(.down)
        guard rounded >= -1_000_000_000, rounded <= 1_000_000_000 else { return nil }
        return Int(rounded)
    }
}

// MARK: - Strict parse helpers

extension AnchorlessSolver {

    fileprivate enum ParseOutcome<Value> {
        case success(Value)
        case failure(AnchorlessFailure)
    }

    fileprivate static func reject(
        _ code: AnchorlessFailure,
        variantId: String? = nil,
        pageKey: String? = nil
    ) -> AnchorlessPrepareResult {
        .rejected(code, AnchorlessTrace(
            phase: .prepare, failure: code, variantId: variantId, pageKey: pageKey
        ))
    }

    fileprivate static func nonEmptyString(_ value: AnchorlessJSONValue?) -> String? {
        guard let text = value?.stringValue, !text.isEmpty else { return nil }
        return text
    }

    /// Every value finite. Offsets, insets and sizes are checked per rule.
    fileprivate static func finite(_ value: AnchorlessJSONValue?) -> Double? {
        guard let number = value?.numberValue, number.isFinite else { return nil }
        return number
    }

    fileprivate static func nonNegative(_ value: AnchorlessJSONValue?) -> Double? {
        guard let number = finite(value), number >= 0 else { return nil }
        return number
    }

    fileprivate static func positive(_ value: AnchorlessJSONValue?) -> Double? {
        guard let number = finite(value), number > 0 else { return nil }
        return number
    }

    fileprivate static func parseHorizontalRule(
        _ json: AnchorlessJSONValue?
    ) -> ParseOutcome<AnchorlessHorizontalRule> {
        guard let json, json.objectValue != nil, let kind = json["kind"]?.stringValue else {
            return .failure(.invalidModel)
        }
        switch kind {
        case "startFixed":
            guard let startOffset = nonNegative(json["startOffset"]),
                  let width = positive(json["width"]) else { return .failure(.invalidModel) }
            return .success(.startFixed(startOffset: startOffset, width: width))
        case "endFixed":
            guard let endOffset = nonNegative(json["endOffset"]),
                  let width = positive(json["width"]) else { return .failure(.invalidModel) }
            return .success(.endFixed(endOffset: endOffset, width: width))
        case "centered":
            guard let width = positive(json["width"]) else { return .failure(.invalidModel) }
            return .success(.centered(width: width))
        case "stretch":
            guard let startInset = nonNegative(json["startInset"]),
                  let endInset = nonNegative(json["endInset"]) else { return .failure(.invalidModel) }
            return .success(.stretch(startInset: startInset, endInset: endInset))
        case "proportional":
            guard let startFraction = finite(json["startFraction"]),
                  let endFraction = finite(json["endFraction"]),
                  validFractions(near: startFraction, far: endFraction) else { return .failure(.invalidModel) }
            return .success(.proportional(startFraction: startFraction, endFraction: endFraction))
        default:
            return .failure(.unknownRuleKind)
        }
    }

    fileprivate static func parseVerticalRule(
        _ json: AnchorlessJSONValue?
    ) -> ParseOutcome<AnchorlessVerticalRule> {
        guard let json, json.objectValue != nil, let kind = json["kind"]?.stringValue else {
            return .failure(.invalidModel)
        }
        switch kind {
        case "topFixed":
            guard let topOffset = nonNegative(json["topOffset"]),
                  let height = positive(json["height"]) else { return .failure(.invalidModel) }
            return .success(.topFixed(topOffset: topOffset, height: height))
        case "bottomFixed":
            guard let bottomOffset = nonNegative(json["bottomOffset"]),
                  let height = positive(json["height"]) else { return .failure(.invalidModel) }
            return .success(.bottomFixed(bottomOffset: bottomOffset, height: height))
        case "centered":
            guard let height = positive(json["height"]) else { return .failure(.invalidModel) }
            return .success(.centered(height: height))
        case "stretch":
            guard let topInset = nonNegative(json["topInset"]),
                  let bottomInset = nonNegative(json["bottomInset"]) else { return .failure(.invalidModel) }
            return .success(.stretch(topInset: topInset, bottomInset: bottomInset))
        case "proportional":
            guard let topFraction = finite(json["topFraction"]),
                  let bottomFraction = finite(json["bottomFraction"]),
                  validFractions(near: topFraction, far: bottomFraction) else { return .failure(.invalidModel) }
            return .success(.proportional(topFraction: topFraction, bottomFraction: bottomFraction))
        case "widthScaled":
            guard let topRatio = nonNegative(json["topRatio"]),
                  let height = positive(json["height"]) else { return .failure(.invalidModel) }
            return .success(.widthScaled(topRatio: topRatio, height: height))
        default:
            return .failure(.unknownRuleKind)
        }
    }

    /// `0 <= near < far <= 1`.
    fileprivate static func validFractions(near: Double, far: Double) -> Bool {
        near >= 0 && near < far && far <= 1
    }

    fileprivate static func parseCrop(_ json: AnchorlessJSONValue?) -> AnchorlessCropRef? {
        guard let json, json.objectValue != nil,
              let cropId = nonEmptyString(json["cropId"]),
              let url = nonEmptyString(json["url"]),
              let widthPx = positive(json["widthPx"]),
              let heightPx = positive(json["heightPx"]),
              let sourceScale = positive(json["sourceScale"]),
              let focal = json["focal"], focal.objectValue != nil,
              let focalX = finite(focal["x"]),
              let focalY = finite(focal["y"])
        else { return nil }
        return AnchorlessCropRef(
            cropId: cropId,
            url: url,
            widthPx: widthPx,
            heightPx: heightPx,
            sourceScale: sourceScale,
            focalX: focalX,
            focalY: focalY
        )
    }
}
