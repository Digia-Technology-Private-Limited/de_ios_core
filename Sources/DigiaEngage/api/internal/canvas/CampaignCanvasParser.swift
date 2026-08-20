import Foundation

struct CampaignCanvasParser {
    let designTokens: DesignTokenCatalog
    init(designTokens: DesignTokenCatalog = .empty) { self.designTokens = designTokens }

    private var widgetParsers: [String: (CampaignCanvasBox, [String: Any]) throws -> CampaignCanvasWidget] {
        [
            "digia/text": parseText,
            "digia/image": parseImage,
            "digia/button": parseButton,
            "digia/linearProgressBar": parseProgress,
            "digia/lottie": parseLottie,
            "digia/videoPlayer": parseVideo,
            "digia/canvasContainer": parseContainer,
            "digia/styledHorizontalDivider": parseDivider,
        ]
    }

    func parse(_ json: [String: Any]) throws -> CampaignCanvas {
        let version = (json["version"] as? NSNumber)?.intValue ?? -1
        guard version == 2 else { throw DesignTokenError.invalid("Unsupported canvas version \(version)") }
        let width = positive(propertyNumber(json["canvasWidth"]) ?? 360, fallback: 360)
        let height = positive(propertyNumber(json["canvasHeight"]) ?? 420, fallback: 420)
        var children: [CampaignCanvasChild] = []
        for child in json["children"] as? [[String: Any]] ?? [] {
            guard let rectJSON = propertyObject(child["rect"]) else { continue }
            let rect = CampaignCanvasRect(
                x: CGFloat(propertyNumber(rectJSON["x"]) ?? 0) * width,
                y: CGFloat(propertyNumber(rectJSON["y"]) ?? 0) * height,
                width: max(0, CGFloat(propertyNumber(rectJSON["width"]) ?? 0) * width),
                height: max(0, CGFloat(propertyNumber(rectJSON["height"]) ?? 0) * height)
            )
            let id = child["id"] as? String ?? ""
            switch child["kind"] as? String {
            case "tapRegion":
                let actions = EngageActionParser().parse(child["onClick"] as? [String: Any])
                if !actions.isEmpty { children.append(.tapRegion(id: id, rect: rect, actions: actions)) }
            case "widget":
                if let widget = try parseWidget(child["widget"] as? [String: Any]) {
                    children.append(.widget(id: id, rect: rect, widget: widget))
                }
            default: continue
            }
        }
        return CampaignCanvas(
            version: version, width: width, height: height,
            background: try parseBackground(json["background"] as? [String: Any]),
            children: children
        )
    }

    private func parseWidget(_ json: [String: Any]?) throws -> CampaignCanvasWidget? {
        guard let json, let type = json["type"] as? String, let parser = widgetParsers[type] else { return nil }
        let props = propertyObject(json["props"]) ?? [:]
        var box = type == "digia/canvasContainer" ? .none : try parseBox(propertyObject(json["containerProps"]))
        if type == "digia/button" { box.shadow = nil }
        return try parser(box, props)
    }

    private func parseBackground(_ json: [String: Any]?) throws -> CampaignCanvasPaint {
        let paint = try parsePaint(json, allowImage: true)
        return paint == .none ? .solid(.literal("#FFFFFFFF")) : paint
    }

    private func parseText(_ box: CampaignCanvasBox, _ props: [String: Any]) throws -> CampaignCanvasWidget {
        .text(
            box: box,
            block: try parseTextBlock(props, buttonDefaults: false),
            shadow: try parseShadow(propertyObject(props["shadow"]))
        )
    }

    private func parseTextBlock(_ json: [String: Any], buttonDefaults: Bool) throws -> CampaignCanvasTextBlock {
        let defaultHorizontal = buttonDefaults ? "center" : "left"
        let horizontal = horizontalAlign(json["horizontalAlign"] as? String ?? defaultHorizontal)
        return CampaignCanvasTextBlock(
            horizontalAlign: horizontal,
            textAlign: horizontalAlign(json["textAlign"] as? String ?? (json["horizontalAlign"] as? String ?? defaultHorizontal)),
            verticalAlign: verticalAlign(json["verticalAlign"] as? String ?? (buttonDefaults ? "center" : "top")),
            maxLines: max(0, (json["maxLines"] as? NSNumber)?.intValue ?? (buttonDefaults ? 1 : 0)),
            overflow: json["overflow"] as? String ?? (buttonDefaults ? "ellipsis" : "visible"),
            sizingMode: ["wrap", "hug", "fixed"].contains(json["sizingMode"] as? String ?? "wrap") ? (json["sizingMode"] as? String ?? "wrap") : "wrap",
            spans: try parseSpans(json["spans"] as? [[String: Any]])
        )
    }

    private func parseSpans(_ raw: [[String: Any]]?) throws -> [CampaignCanvasTextSpan] {
        try (raw ?? []).compactMap { span in
            guard let text = span["text"] as? String, !text.isEmpty else { return nil }
            return CampaignCanvasTextSpan(
                text: text,
                typography: try designTokens.resolveTypography(span["typography"]),
                color: try designTokens.resolveColor(span["color"]),
                highlightColor: try designTokens.resolveColor(span["highlightColor"]),
                italic: span["italic"] as? Bool ?? false,
                decoration: {
                    switch span["decoration"] as? String { case "underline": .underline; case "lineThrough": .lineThrough; default: .none }
                }(),
                decorationColor: try designTokens.resolveColor(span["decorationColor"]),
                decorationThickness: propertyNumber(span["decorationThickness"]).map { CGFloat($0) },
                actions: EngageActionParser().parse(span["onClick"] as? [String: Any])
            )
        }
    }

    private func parseImage(_ box: CampaignCanvasBox, _ props: [String: Any]) throws -> CampaignCanvasWidget {
        .image(
            box: box, source: parseMediaSource(props["source"]), fit: parseFit(props["fit"] as? String),
            positionX: clamp(propertyNumber(props["positionX"]) ?? 0.5, 0, 1),
            positionY: clamp(propertyNumber(props["positionY"]) ?? 0.5, 0, 1),
            scale: clamp(propertyNumber(props["scale"]) ?? 1, 0.1, 4),
            tintColor: try designTokens.resolveColor(props["tintColor"])
        )
    }

    private func parseButton(_ box: CampaignCanvasBox, _ props: [String: Any]) throws -> CampaignCanvasWidget {
        let label = try parseTextBlock(propertyObject(props["label"]) ?? [:], buttonDefaults: true)
        let styleJSON = propertyObject(props["style"]) ?? [:]
        let style: CampaignCanvasButtonStyle
        switch styleJSON["variant"] as? String ?? "fill" {
        case "outline":
            style = .outline(
                fill: try parsePaint(propertyObject(styleJSON["fill"]), allowImage: false),
                outline: try parseBorder(propertyObject(styleJSON["outline"])) ?? CampaignCanvasBorder(color: .literal("#FF4945FF"), width: 1.5)
            )
        case "text": style = .text
        default:
            style = .fill(
                fill: try parsePaint(propertyObject(styleJSON["fill"]), allowImage: false)
            )
        }
        let confirm = propertyObject(props["confirm"]) ?? [:]
        return .button(
            box: box, label: label, cornerRadius: parseCornerRadius(props["cornerRadius"], fallback: 8), style: style,
            shadow: try parseShadow(propertyObject(props["shadow"])),
            isPrimary: props["isPrimary"] as? Bool ?? false,
            isDestructive: props["isDestructive"] as? Bool ?? false,
            applyDestructiveStyling: props["applyDestructiveStyling"] as? Bool ?? true,
            actions: EngageActionParser().parse(props["onClick"] as? [String: Any]),
            confirm: CampaignCanvasConfirmDialog(
                title: confirm.keys.contains("title") ? confirm["title"] as? String : nil,
                message: confirm.keys.contains("message") ? confirm["message"] as? String : nil,
                confirmLabel: confirm["confirmLabel"] as? String ?? "Yes",
                cancelLabel: confirm["cancelLabel"] as? String ?? "Cancel",
                titleFontWeight: DigiaFontWeight.value(confirm["titleFontWeight"], default: 700),
                messageFontWeight: DigiaFontWeight.value(confirm["messageFontWeight"], default: 400),
                buttonFontWeight: DigiaFontWeight.value(confirm["buttonFontWeight"], default: 600)
            )
        )
    }

    private func parseProgress(_ box: CampaignCanvasBox, _ props: [String: Any]) throws -> CampaignCanvasWidget {
        let animation = propertyObject(props["animateOnAppear"]) ?? [:]
        return .progress(
            box: box, valueMode: (props["valueMode"] as? String) == "range" ? .range : .percent,
            percent: rawString(props["percent"], fallback: "0"),
            rangeStart: rawString(props["rangeStart"], fallback: "0"),
            rangeCurrent: rawString(props["rangeCurrent"], fallback: "0"),
            rangeEnd: rawString(props["rangeEnd"], fallback: "100"),
            indicator: try parsePaint(propertyObject(props["indicator"]), allowImage: false),
            track: try parsePaint(propertyObject(props["track"]), allowImage: false),
            cornerRadius: parseCornerRadius(props["cornerRadius"], fallback: 0),
            animateOnAppear: CampaignCanvasAppearAnimation(
                enabled: animation["enabled"] as? Bool ?? false,
                durationMs: min(max((animation["durationMs"] as? NSNumber)?.intValue ?? 600, 0), 5000)
            )
        )
    }

    private func parseLottie(_ box: CampaignCanvasBox, _ props: [String: Any]) throws -> CampaignCanvasWidget {
        .lottie(box: box, source: parseMediaSource(props["source"]), autoplay: props["autoplay"] as? Bool ?? true, loop: props["loop"] as? Bool ?? true, fit: parseFit(props["fit"] as? String))
    }

    private func parseVideo(_ box: CampaignCanvasBox, _ props: [String: Any]) throws -> CampaignCanvasWidget {
        .video(box: box, source: parseMediaSource(props["source"]), autoplay: props["autoplay"] as? Bool ?? false, loop: props["loop"] as? Bool ?? false, muted: props["muted"] as? Bool ?? false, showControls: props["showControls"] as? Bool ?? true, fit: (props["fit"] as? String) == "contain" ? "contain" : "cover")
    }

    private func parseContainer(_ box: CampaignCanvasBox, _ props: [String: Any]) throws -> CampaignCanvasWidget {
        .container(fill: try parsePaint(propertyObject(props["fill"]), allowImage: true), cornerRadius: parseCornerRadius(props["cornerRadius"], fallback: 0), border: try parseBorder(propertyObject(props["border"])), shadow: try parseShadow(propertyObject(props["shadow"])))
    }

    private func parseDivider(_ box: CampaignCanvasBox, _ props: [String: Any]) throws -> CampaignCanvasWidget {
        .divider(
            box: box, axis: (props["type"] as? String) == "vertical" ? .vertical : .horizontal,
            pattern: { switch props["style"] as? String { case "dashed": .dashed; case "dotted": .dotted; default: .solid } }(),
            strokeCap: { switch props["strokeCap"] as? String { case "round": .round; case "square": .square; default: .butt } }(),
            inset: max(0, CGFloat(propertyNumber(props["inset"]) ?? 0)),
            dashPattern: parseDashPattern(props["dashPattern"]),
            color: try designTokens.resolveColor(props["color"]) ?? .literal("#FFE0E0E0")
        )
    }

    private func parseBox(_ json: [String: Any]?) throws -> CampaignCanvasBox {
        guard let json else { return .none }
        let fillJSON = propertyObject(json["fill"])
        let fill = fillJSON?["type"] as? String == "solid" ? try parsePaint(fillJSON, allowImage: false) : .none
        return CampaignCanvasBox(fill: fill, padding: parseInsets(json["padding"]), cornerRadius: parseCornerRadius(json["cornerRadius"], fallback: 0), border: try parseBorder(propertyObject(json["border"])), shadow: try parseShadow(propertyObject(json["shadow"])))
    }

    private func parsePaint(_ json: [String: Any]?, allowImage: Bool) throws -> CampaignCanvasPaint {
        guard let json else { return .none }
        switch json["type"] as? String {
        case "solid": return try designTokens.resolveColor(json["color"]).map(CampaignCanvasPaint.solid) ?? .none
        case "gradient":
            return .gradient(
                type: { switch json["gradientType"] as? String { case "radial": .radial; case "sweep": .sweep; default: .linear } }(),
                angleDegrees: CGFloat(propertyNumber(json["angleDeg"]) ?? 180),
                centerX: clamp(propertyNumber(json["centerX"]) ?? 0.5, 0, 1),
                centerY: clamp(propertyNumber(json["centerY"]) ?? 0.5, 0, 1),
                radius: clamp(propertyNumber(json["radius"]) ?? 0.5, 0.1, 4),
                startAngleDegrees: CGFloat(propertyNumber(json["startAngleDeg"]) ?? 0),
                endAngleDegrees: CGFloat(propertyNumber(json["endAngleDeg"]) ?? 360),
                stops: try parseStops(propertyArray(json["stops"]))
            )
        case "image" where allowImage:
            return .image(source: parseMediaSource(json["source"]), positionX: clamp(propertyNumber(json["positionX"]) ?? 0.5, 0, 1), positionY: clamp(propertyNumber(json["positionY"]) ?? 0.5, 0, 1), scale: clamp(propertyNumber(json["scale"]) ?? 1, 0.1, 4))
        default: return .none
        }
    }

    private func parseStops(_ raw: [[String: Any]]?) throws -> [CampaignCanvasGradientStop] {
        try (raw ?? []).compactMap { stop in
            guard let color = try designTokens.resolveColor(stop["color"]) else { return nil }
            return CampaignCanvasGradientStop(color: color, offset: clamp(propertyNumber(stop["offset"]) ?? 0, 0, 1))
        }.sorted { $0.offset < $1.offset }
    }

    private func parseMediaSource(_ raw: Any?) -> CampaignCanvasMediaSource {
        let json = propertyObject(raw) ?? [:]
        return CampaignCanvasMediaSource(url: json["url"] as? String ?? "", darkUrl: (json["darkUrl"] as? String)?.nilIfEmpty, placeholder: ImagePlaceholder.from(propertyObject(json["placeholder"])))
    }

    private func parseInsets(_ raw: Any?) -> CampaignCanvasEdgeInsets {
        let value = unwrapLiteral(raw)
        if let scalar = designNumber(value).map({ CGFloat($0) }) { return CampaignCanvasEdgeInsets(top: scalar, right: scalar, bottom: scalar, left: scalar) }
        guard let json = value as? [String: Any] else { return CampaignCanvasEdgeInsets() }
        return CampaignCanvasEdgeInsets(top: CGFloat(propertyNumber(json["top"]) ?? 0), right: CGFloat(propertyNumber(json["right"]) ?? 0), bottom: CGFloat(propertyNumber(json["bottom"]) ?? 0), left: CGFloat(propertyNumber(json["left"]) ?? 0))
    }

    private func parseCornerRadius(_ raw: Any?, fallback: CGFloat) -> CampaignCanvasCornerRadius {
        let value = unwrapLiteral(raw)
        if let scalar = designNumber(value).map({ CGFloat($0) }) { return CampaignCanvasCornerRadius(topLeft: scalar, topRight: scalar, bottomRight: scalar, bottomLeft: scalar) }
        guard let json = value as? [String: Any] else { return CampaignCanvasCornerRadius(topLeft: fallback, topRight: fallback, bottomRight: fallback, bottomLeft: fallback) }
        return CampaignCanvasCornerRadius(topLeft: CGFloat(propertyNumber(json["topLeft"]) ?? 0), topRight: CGFloat(propertyNumber(json["topRight"]) ?? 0), bottomRight: CGFloat(propertyNumber(json["bottomRight"]) ?? 0), bottomLeft: CGFloat(propertyNumber(json["bottomLeft"]) ?? 0))
    }

    private func parseBorder(_ json: [String: Any]?) throws -> CampaignCanvasBorder? {
        guard let json, let color = try designTokens.resolveColor(json["color"]) else { return nil }
        return CampaignCanvasBorder(color: color, width: max(0, CGFloat(propertyNumber(json["width"]) ?? 1)))
    }

    private func parseShadow(_ json: [String: Any]?) throws -> CampaignCanvasShadow? {
        guard let json else { return nil }
        return CampaignCanvasShadow(
            color: try designTokens.resolveColor(json["color"]) ?? .literal("#FF000000"),
            blur: min(max(0, CGFloat(propertyNumber(json["blur"]) ?? 0)), 200),
            spread: min(max(0, CGFloat(propertyNumber(json["spread"]) ?? 0)), 200),
            offsetX: CGFloat(propertyNumber(json["offsetX"]) ?? 0),
            offsetY: CGFloat(propertyNumber(json["offsetY"]) ?? 0)
        )
    }

    private func parseDashPattern(_ raw: Any?) -> [CGFloat] {
        let values: [CGFloat]
        if let list = raw as? [Any] { values = list.compactMap { designNumber($0).map { CGFloat($0) } } }
        else if let string = raw as? String { values = string.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0).map { CGFloat($0) } } }
        else { values = [] }
        let positive = values.filter { $0 > 0 }
        return positive.isEmpty ? [8, 4] : positive
    }

    private func horizontalAlign(_ value: String) -> CampaignCanvasHorizontalAlign { switch value { case "center": .center; case "right": .right; default: .left } }
    private func verticalAlign(_ value: String) -> CampaignCanvasVerticalAlign { switch value { case "center": .center; case "bottom": .bottom; default: .top } }
    private func parseFit(_ value: String?) -> String { switch value { case "contain": "contain"; case "fill": "fill"; default: "cover" } }
    private func propertyNumber(_ raw: Any?) -> Double? {
        guard let value = designNumber(unwrapLiteral(raw)), value.isFinite else { return nil }
        return value
    }
    private func propertyObject(_ raw: Any?) -> [String: Any]? { unwrapLiteral(raw) as? [String: Any] }
    private func propertyArray(_ raw: Any?) -> [[String: Any]]? { unwrapLiteral(raw) as? [[String: Any]] }
    private func positive(_ value: Double, fallback: CGFloat) -> CGFloat { value.isFinite && value > 0 ? CGFloat(value) : fallback }
    private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> CGFloat { CGFloat(min(max(value, lower), upper)) }
    private func rawString(_ raw: Any?, fallback: String) -> String {
        switch unwrapLiteral(raw) {
        case let value as String: value
        case let value as NSNumber: value.stringValue
        default: fallback
        }
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
