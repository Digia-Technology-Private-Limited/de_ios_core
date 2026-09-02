import Foundation

private extension CampaignTimerUnit {
    var defaultLabel: String {
        switch self {
        case .days: "Days"
        case .hours: "Hrs"
        case .minutes: "Min"
        case .seconds: "Sec"
        }
    }
}

struct CampaignCanvasParser {
    let designTokens: DesignTokenCatalog
    let strictWidgets: Bool
    let allowTimer: Bool
    init(
        designTokens: DesignTokenCatalog = .empty,
        strictWidgets: Bool = false,
        allowTimer: Bool = false
    ) {
        self.designTokens = designTokens
        self.strictWidgets = strictWidgets
        self.allowTimer = allowTimer
    }

    /// Optional: a carousel with no readable slides, or a story with no readable
    /// pages or chrome, has nothing to draw. Dropping the widget is the right
    /// failure — the campaign renders without it rather than as a broken strip.
    private var widgetParsers: [String: (CampaignCanvasBox, [String: Any]) throws -> CampaignCanvasWidget?] {
        [
            "digia/text": parseText,
            "digia/image": parseImage,
            "digia/button": parseButton,
            "digia/linearProgressBar": parseProgress,
            "digia/lottie": parseLottie,
            "digia/videoPlayer": parseVideo,
            "digia/canvasContainer": parseContainer,
            "digia/styledHorizontalDivider": parseDivider,
            "digia/canvasCarousel": parseCarousel,
            "digia/canvasStory": parseStory,
            "digia/storyProgress": parseStoryProgress,
            "digia/storyClose": parseStoryClose,
            "digia/storyMute": parseStoryMute,
            "digia/timer": parseTimer,
        ]
    }

    /// Parses a carousel and its nested slides.
    ///
    /// All-or-nothing: rendering the slides that happened to parse would give the
    /// marketer a carousel quietly missing one, with no signal that anything went
    /// wrong. Slides recurse through `parse`, so a nested carousel is possible in
    /// principle and simply never authored.
    private func parseCarousel(_ box: CampaignCanvasBox, _ props: [String: Any]) throws -> CampaignCanvasWidget? {
        guard let raw = props["slides"] as? [[String: Any]], !raw.isEmpty else { return nil }
        var slides: [CampaignCanvas] = []
        for slide in raw {
            guard let parsed = parseNested(slide) else { return nil }
            slides.append(parsed)
        }
        let fraction = CGFloat(propertyNumber(props["viewportFraction"]) ?? 0.88)
        let itemSpacing = CGFloat(propertyNumber(props["itemSpacing"]) ?? 12)
        let autoPlayIntervalMs = propertyNumber(props["autoPlayInterval"]) ?? 3000
        let animationDurationMs = propertyNumber(props["animationDuration"]) ?? 700
        let cornerRadius = CGFloat(propertyNumber(props["cornerRadius"]) ?? 12)
        let dotWidth = CGFloat(propertyNumber(props["dotWidth"]) ?? 8)
        let dotHeight = CGFloat(propertyNumber(props["dotHeight"]) ?? 8)
        let dotSpacing = CGFloat(propertyNumber(props["dotSpacing"]) ?? 12)
        return .carousel(
            box: box,
            slides: slides,
            // A non-positive or over-unity fraction would make every slide vanish
            // or overflow the viewport; fall back rather than trust the payload.
            viewportFraction: fraction >= 0.1 && fraction <= 1 ? fraction : 0.88,
            itemSpacing: itemSpacing >= 0 ? itemSpacing : 12,
            autoPlay: props["autoPlay"] as? Bool ?? true,
            autoPlayInterval: (autoPlayIntervalMs > 0 ? autoPlayIntervalMs : 3000) / 1000,
            animationDuration: (animationDurationMs > 0 ? animationDurationMs : 700) / 1000,
            infiniteScroll: props["infiniteScroll"] as? Bool ?? true,
            cornerRadius: cornerRadius >= 0 ? cornerRadius : 12,
            showIndicator: props["showIndicator"] as? Bool ?? true,
            dotWidth: dotWidth > 0 ? dotWidth : 8,
            dotHeight: dotHeight > 0 ? dotHeight : 8,
            dotSpacing: dotSpacing >= 0 ? dotSpacing : 12,
            dotColor: try designTokens.resolveColor(props["dotColor"]),
            activeDotColor: try designTokens.resolveColor(props["activeDotColor"]),
            indicatorEffect: props["indicatorEffect"] as? String ?? "slide"
        )
    }

    /// Parses a standalone story block — pages and chrome, with no rail.
    ///
    /// The story-floater template carries its story beside the window canvas rather
    /// than inside it (`FloaterStoryConfig`), but the block itself is the
    /// `digia/canvasStory` widget's props minus the rail fields. Reading it through
    /// the same parser keeps one definition of "a story" in the SDK: the rail-only
    /// values fall back to their defaults and are never read, because nothing draws
    /// a rail from this.
    ///
    /// Returns `nil` on the same terms `parseStory` does — no readable page, or no
    /// chrome to close the viewer with.
    func parseStandaloneStory(_ props: [String: Any]?) -> CampaignCanvasWidget? {
        guard let props, let widget = try? parseStory(.none, props), case .story = widget else {
            return nil
        }
        return widget
    }

    /// Parses a story rail, its nested pages and the chrome layer over them.
    ///
    /// A story with no readable chrome would open with no way out, so it is
    /// rejected the way an unreadable page is.
    private func parseStory(_ box: CampaignCanvasBox, _ props: [String: Any]) throws -> CampaignCanvasWidget? {
        guard let rawPages = props["pages"] as? [[String: Any]], !rawPages.isEmpty else { return nil }
        // Resolved once: a page that sets no duration of its own inherits this,
        // exactly as a media story item does.
        let fallbackSeconds = max(0.1, propertyNumber(props["defaultDurationSeconds"]) ?? 5)

        var pages: [CampaignCanvasStoryPage] = []
        for page in rawPages {
            guard let canvasJSON = propertyObject(page["canvas"]),
                  let canvas = parseNested(canvasJSON) else { return nil }
            let playback = propertyObject(page["thumbnailPlayback"]) ?? [:]
            let seconds = propertyNumber(page["durationSeconds"]) ?? 0
            pages.append(
                CampaignCanvasStoryPage(
                    thumbnailIsVideo: page["thumbnailType"] as? String == "video",
                    thumbnailUrl: page["thumbnailUrl"] as? String ?? "",
                    thumbnailFit: page["thumbnailFit"] as? String ?? "cover",
                    pageFit: page["pageFit"] as? String ?? "cover",
                    thumbnailPlayback: CampaignCanvasStoryThumbnailPlayback(
                        startTime: max(0, (propertyNumber(playback["startTimeMs"]) ?? 0) / 1000),
                        fixedDuration: playback["durationMode"] as? String == "fixed",
                        duration: max(0.001, (propertyNumber(playback["durationMs"]) ?? 5000) / 1000)
                    ),
                    duration: seconds > 0 ? seconds : fallbackSeconds,
                    canvas: canvas
                )
            )
        }

        guard let chromeJSON = propertyObject(props["chromeCanvas"]),
              let chrome = parseNested(chromeJSON) else { return nil }
        let cardRatio = CGFloat(propertyNumber(props["cardAspectRatio"]) ?? 0.72)
        return .story(
            box: box,
            pages: pages,
            cardAspectRatio: cardRatio > 0 ? cardRatio : 0.72,
            cardCornerRadius: CGFloat(propertyNumber(props["cardCornerRadius"]) ?? 12),
            cardSpacing: CGFloat(propertyNumber(props["cardSpacing"]) ?? 12),
            showRail: props["showRail"] as? Bool ?? true,
            thumbnailVideoPlayback: props["thumbnailVideoPlayback"] as? String == "sequential"
                ? .sequential
                : .simultaneous,
            restartOnCompleted: props["restartOnCompleted"] as? Bool ?? false,
            startMuted: props["startMuted"] as? Bool ?? true,
            chrome: chrome
        )
    }

    private func parseStoryProgress(_ box: CampaignCanvasBox, _ props: [String: Any]) throws -> CampaignCanvasWidget? {
        .storyProgress(
            box: box,
            activeColor: try designTokens.resolveColor(props["activeColor"]),
            trackColor: try designTokens.resolveColor(props["trackColor"]),
            barHeight: CGFloat(propertyNumber(props["barHeight"]) ?? 3),
            cornerRadius: CGFloat(propertyNumber(props["cornerRadius"]) ?? 2),
            gap: CGFloat(propertyNumber(props["gap"]) ?? 4)
        )
    }

    private func parseStoryClose(_ box: CampaignCanvasBox, _ props: [String: Any]) throws -> CampaignCanvasWidget? {
        .storyClose(
            box: box,
            visible: props["visible"] as? Bool ?? true,
            iconColor: try designTokens.resolveColor(props["iconColor"]),
            backgroundColor: try designTokens.resolveColor(props["backgroundColor"])
        )
    }

    private func parseStoryMute(_ box: CampaignCanvasBox, _ props: [String: Any]) throws -> CampaignCanvasWidget? {
        .storyMute(
            box: box,
            visible: props["visible"] as? Bool ?? true,
            iconColor: try designTokens.resolveColor(props["iconColor"]),
            backgroundColor: try designTokens.resolveColor(props["backgroundColor"])
        )
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
                } else if strictWidgets {
                    throw DesignTokenError.invalid("Unsupported Canvas widget")
                }
            default:
                if strictWidgets { throw DesignTokenError.invalid("Unsupported Canvas child kind") }
                continue
            }
        }
        return CampaignCanvas(
            version: version, width: width, height: height,
            background: try parseBackground(json["background"] as? [String: Any]),
            children: children
        )
    }

    private func parseWidget(_ json: [String: Any]?) throws -> CampaignCanvasWidget? {
        guard let json, let type = json["type"] as? String else { return nil }
        if type == "digia/timer" && !allowTimer {
            throw DesignTokenError.invalid("Timer widget is not allowed on this surface")
        }
        guard let parser = widgetParsers[type] else { return nil }
        let props = propertyObject(json["props"]) ?? [:]
        var box = type == "digia/canvasContainer" ? .none : try parseBox(propertyObject(json["containerProps"]))
        if type == "digia/button" { box.shadow = nil }
        return try parser(box, props)
    }

    private func parseNested(_ json: [String: Any]) -> CampaignCanvas? {
        try? CampaignCanvasParser(
            designTokens: designTokens,
            strictWidgets: strictWidgets,
            allowTimer: false
        ).parse(json)
    }

    private func parseTimer(
        _ box: CampaignCanvasBox,
        _ props: [String: Any]
    ) throws -> CampaignCanvasWidget? {
        guard !props.keys.contains("sourceId"), !props.keys.contains("urgentDigitColor") else { return nil }
        let preset = props["preset"] as? String ?? "unitBoxes"
        guard preset == "text" || preset == "unitBoxes" else { return nil }
        let unitJSON = propertyObject(props["units"]) ?? [:]
        let labelJSON = propertyObject(props["labels"]) ?? [:]
        var units: [CampaignTimerUnit: CampaignTimerUnitVisibility] = [:]
        var labels: [CampaignTimerUnit: String] = [:]
        for unit in CampaignTimerUnit.allCases {
            let raw = unitJSON[unit.rawValue] ?? (unit == .days ? "autoHide" : true)
            switch raw {
            case let value as String where value == "autoHide": units[unit] = .autoHide
            case let value as Bool: units[unit] = value ? .show : .hide
            default: return nil
            }
            labels[unit] = labelJSON[unit.rawValue] as? String ?? unit.defaultLabel
        }
        guard units.values.contains(where: { $0 != .hide }) else { return nil }
        let shared = try parseTimerStyle(props, fallback: nil)
        let rawOverrides = propertyObject(props["unitOverrides"]) ?? [:]
        var overrides: [CampaignTimerUnit: CampaignCanvasTimerUnitStyle] = [:]
        for (key, raw) in rawOverrides {
            guard let unit = CampaignTimerUnit(rawValue: key), let value = propertyObject(raw) else { return nil }
            overrides[unit] = try parseTimerStyle(value, fallback: shared)
        }
        return .timer(
            box: box,
            preset: preset,
            separator: props["separator"] as? String ?? ":",
            units: units,
            labels: labels,
            style: shared,
            unitOverrides: overrides
        )
    }

    private func parseTimerStyle(
        _ json: [String: Any],
        fallback: CampaignCanvasTimerUnitStyle?
    ) throws -> CampaignCanvasTimerUnitStyle {
        let digitTypography = fallback?.digitTypography ?? CampaignTypography(
            fontFamily: nil, fontSize: 20, fontWeight: 700, lineHeight: nil, letterSpacing: nil
        )
        let labelTypography = fallback?.labelTypography ?? CampaignTypography(
            fontFamily: nil, fontSize: 10, fontWeight: 400, lineHeight: nil, letterSpacing: nil
        )
        return CampaignCanvasTimerUnitStyle(
            digitTypography: json["digitTypography"] != nil
                ? try designTokens.resolveTypography(
                    json["digitTypography"], fallbackOnMissingToken: true
                ) ?? digitTypography
                : digitTypography,
            digitColor: json["digitColor"] != nil
                ? try designTokens.resolveColor(json["digitColor"]) ?? fallback?.digitColor ?? .literal("#FFFFFFFF")
                : fallback?.digitColor ?? .literal("#FFFFFFFF"),
            labelTypography: json["labelTypography"] != nil
                ? try designTokens.resolveTypography(
                    json["labelTypography"], fallbackOnMissingToken: true
                ) ?? labelTypography
                : labelTypography,
            labelColor: json["labelColor"] != nil
                ? try designTokens.resolveColor(json["labelColor"]) ?? fallback?.labelColor ?? .literal("#FFB9C6DA")
                : fallback?.labelColor ?? .literal("#FFB9C6DA"),
            boxFill: json["boxFill"] != nil
                ? try parsePaint(propertyObject(json["boxFill"]), allowImage: false)
                : fallback?.boxFill ?? .none,
            cornerRadius: json["cornerRadius"] != nil
                ? parseCornerRadius(json["cornerRadius"], fallback: 6)
                : fallback?.cornerRadius ?? parseCornerRadius(nil, fallback: 6)
        )
    }

    private func parseBackground(_ json: [String: Any]?) throws -> CampaignCanvasPaint {
        let paint = try parsePaint(json, allowImage: true, imageScaleLimit: 10)
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

    private func parsePaint(
        _ json: [String: Any]?,
        allowImage: Bool,
        imageScaleLimit: Double = 4
    ) throws -> CampaignCanvasPaint {
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
            return .image(source: parseMediaSource(json["source"]), positionX: clamp(propertyNumber(json["positionX"]) ?? 0.5, 0, 1), positionY: clamp(propertyNumber(json["positionY"]) ?? 0.5, 0, 1), scale: clamp(propertyNumber(json["scale"]) ?? 1, 0.1, imageScaleLimit))
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
