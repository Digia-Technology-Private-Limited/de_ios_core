import SwiftUI

struct NudgeParser {
    func parse(_ templateConfig: [String: Any]) -> NudgeColumn? {
        guard let layout = templateConfig["layout"] as? [String: Any] else { return nil }
        return parseColumn(layout)
    }

    private func parseColumn(_ json: [String: Any]) -> NudgeColumn {
        let props = json["props"] as? [String: Any] ?? [:]
        return NudgeColumn(
            crossAxisAlignment: crossAxis(props["crossAxisAlignment"] as? String ?? "start"),
            mainAxisAlignment: mainAxis(props["mainAxisAlignment"] as? String ?? "start"),
            spacing: CGFloat(parseDouble(props["spacing"]) ?? 0),
            children: extractChildren(json).compactMap { parseNode($0) }
        )
    }

    // ── child extraction ────────────────────────────────────────────────────────

    private func extractChildren(_ json: [String: Any]) -> [[String: Any]] {
        if let arr = json["children"] as? [[String: Any]] { return arr }
        if let obj = json["children"] as? [String: Any] {
            return (obj["children"] as? [[String: Any]]) ?? []
        }
        if let groups = json["childGroups"] as? [[String: Any]] {
            return groups.flatMap { ($0["children"] as? [[String: Any]]) ?? [] }
        }
        return []
    }

    // ── node dispatcher ─────────────────────────────────────────────────────────

    private func parseNode(_ json: [String: Any]) -> NudgeNode? {
        guard let type = json["type"] as? String, !type.isEmpty else { return nil }
        let props = json["props"] as? [String: Any] ?? [:]
        let box = parseBox(json["containerProps"] as? [String: Any])
        switch type {
        case "digia/text": return .text(parseText(props, box: box))
        case "digia/image": return .image(parseImage(props, box: box))
        case "digia/button": return .button(parseButton(props, box: box))
        case "fw/sized_box":
            let h = CGFloat(parseDouble(props["height"]) ?? 8)
            return .gap(NudgeGap(box: box, height: h))
        case "digia/styledHorizontalDivider": return .divider(parseDivider(props, box: box))
        case "digia/lottie": return .lottie(parseLottie(props, box: box))
        case "digia/carousel": return .carousel(parseCarousel(props, box: box))
        case "digia/videoPlayer": return .video(parseVideo(props, box: box))
        default: return nil
        }
    }

    // ── leaf node parsers ────────────────────────────────────────────────────────

    private func parseText(_ props: [String: Any], box: NudgeBox) -> NudgeText {
        let style = (props["textStyle"] as? [String: Any]) ?? [:]
        let font = ((style["fontToken"] as? [String: Any])?["font"] as? [String: Any]) ?? [:]
        return NudgeText(
            box: box,
            text: props["text"] as? String ?? "",
            fontSize: CGFloat(parseDouble(font["size"]) ?? 16),
            fontWeight: parseFontWeight(font["weight"] as? String ?? "400"),
            color: parseColor(style["textColor"] as? String) ?? Color(hex: "#111111") ?? .primary,
            textAlignment: parseTextAlignment(props["alignment"] as? String ?? "left"),
            lineHeight: (props["lineHeight"] as? Double).map { CGFloat($0) },
            spans: parseSpans(props["spans"])
        )
    }

    /// Decodes the optional rich overlay (`props.spans`). Each entry is
    /// `{ text, style: { fontWeight, fontSize, textColor, highlightColor,
    /// lineHeight } }`; every style key is optional and inherits the base when
    /// absent. Empty/invalid entries are skipped.
    private func parseSpans(_ raw: Any?) -> [NudgeTextSpan] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap { item in
            guard let text = item["text"] as? String, !text.isEmpty else { return nil }
            let style = (item["style"] as? [String: Any]) ?? [:]
            // Decoration (underline / lineThrough / colour / thickness) temporarily
            // disabled pending cross-platform parity — see ai_docs/text_decoration_parity.md.
            // let decoration = style["decoration"] as? String
            return NudgeTextSpan(
                text: text,
                style: NudgeSpanStyle(
                    fontWeight: (style["fontWeight"] as? Double).flatMap {
                        parseFontWeightNumber(Int($0))
                    },
                    fontSize: (style["fontSize"] as? Double).map { CGFloat($0) },
                    color: parseColor(style["textColor"] as? String),
                    highlightColor: parseColor(style["highlightColor"] as? String),
                    italic: (style["fontStyle"] as? String) == "italic",
                    // underline: decoration == "underline",
                    // strikethrough: decoration == "lineThrough",
                    // decorationColor: parseColor(style["decorationColor"] as? String),
                    // decorationThickness: (style["decorationThickness"] as? Double).map { CGFloat($0) }
                    underline: false,
                    strikethrough: false,
                    decorationColor: nil,
                    decorationThickness: nil
                )
            )
        }
    }

    /// A span's numeric CSS weight (100…900) → `Font.Weight`; nil for unknown.
    private func parseFontWeightNumber(_ n: Int) -> Font.Weight? {
        switch n {
        case 100: return .thin
        case 200: return .ultraLight
        case 300: return .light
        case 400: return .regular
        case 500: return .medium
        case 600: return .semibold
        case 700: return .bold
        case 800: return .heavy
        case 900: return .black
        default: return nil
        }
    }

    private func parseImage(_ props: [String: Any], box: NudgeBox) -> NudgeImage {
        let aspectRatio = CGFloat(parseDouble(props["aspectRatio"]) ?? 0)
        let url = (props["src"] as? [String: Any])?["imageSrc"] as? String ?? ""
        return NudgeImage(
            box: aspectRatio > 0 ? box.withoutFixedHeight() : box,
            url: url,
            aspectRatio: aspectRatio,
            fit: parseFit(props["fit"] as? String ?? "cover")
        )
    }

    private func parseButton(_ props: [String: Any], box: NudgeBox) -> NudgeButton {
        let text = (props["text"] as? [String: Any]) ?? [:]
        let textStyle = (text["textStyle"] as? [String: Any]) ?? [:]
        let font = ((textStyle["fontToken"] as? [String: Any])?["font"] as? [String: Any]) ?? [:]
        let defaultStyle = (props["defaultStyle"] as? [String: Any]) ?? [:]
        let shape = (props["shape"] as? [String: Any]) ?? [:]
        return NudgeButton(
            box: box,
            label: text["text"] as? String ?? "Button",
            variant: parseButtonVariant(props["variant"] as? String ?? "fill"),
            fontSize: CGFloat(parseDouble(font["size"]) ?? 16),
            fontWeight: parseFontWeight(font["weight"] as? String ?? "600"),
            background: parseColor(defaultStyle["backgroundColor"] as? String) ?? Color(
                hex: "#4945FF") ?? .blue,
            textColor: parseColor(textStyle["textColor"] as? String) ?? .white,
            radius: CGFloat(parseDouble(shape["borderRadius"]) ?? 8),
            actions: NudgeActionParser().parse(props["onClick"] as? [String: Any]),
            isPrimary: (props["isPrimary"] as? Bool) ?? false
        )
    }

    private func parseDivider(_ props: [String: Any], box: NudgeBox) -> NudgeDivider {
        let colorType = (props["colorType"] as? [String: Any]) ?? [:]
        return NudgeDivider(
            box: box,
            thickness: CGFloat(parseDouble(props["thickness"]) ?? 1),
            indent: CGFloat(parseDouble(props["indent"]) ?? 0),
            endIndent: CGFloat(parseDouble(props["endIndent"]) ?? 0),
            color: parseColor(colorType["color"] as? String) ?? Color(hex: "#E0E0E0") ?? .gray
        )
    }

    private func parseLottie(_ props: [String: Any], box: NudgeBox) -> NudgeLottie {
        let src = (props["src"] as? [String: Any]) ?? [:]
        let aspectRatio = CGFloat(parseDouble(props["aspectRatio"]) ?? 0)
        return NudgeLottie(
            box: aspectRatio > 0 ? box.withoutFixedHeight() : box,
            url: src["lottiePath"] as? String ?? "",
            height: CGFloat(parseDouble(props["height"]) ?? 160),
            loop: (props["animationType"] as? String ?? "loop") != "once",
            autoplay: (props["animate"] as? Bool) ?? true,
            fit: parseFit(props["fit"] as? String ?? "cover"),
            aspectRatio: aspectRatio
        )
    }

    private func parseCarousel(_ props: [String: Any], box: NudgeBox) -> NudgeCarousel {
        let images = (props["images"] as? [String] ?? []).filter { !$0.isEmpty }
        return NudgeCarousel(
            box: box,
            images: images,
            height: CGFloat(parseDouble(props["height"]) ?? 180),
            autoPlay: (props["autoPlay"] as? Bool) ?? true,
            autoPlayIntervalMs: Int(parseDouble(props["autoPlayInterval"]) ?? 3000),
            loop: (props["infiniteScroll"] as? Bool) ?? true,
            showIndicator: (props["showIndicator"] as? Bool) ?? true
        )
    }

    private func parseVideo(_ props: [String: Any], box: NudgeBox) -> NudgeVideo {
        NudgeVideo(
            box: box,
            url: props["url"] as? String ?? "",
            height: CGFloat(parseDouble(props["height"]) ?? 200),
            autoplay: (props["autoPlay"] as? Bool) ?? false,
            loop: (props["looping"] as? Bool) ?? false,
            showControls: (props["showControls"] as? Bool) ?? true,
            muted: (props["muted"] as? Bool) ?? false
        )
    }

    // ── box ──────────────────────────────────────────────────────────────────────

    private func parseBox(_ containerProps: [String: Any]?) -> NudgeBox {
        guard let cp = containerProps else { return .none }
        let style = (cp["style"] as? [String: Any]) ?? [:]
        let border = style["border"] as? [String: Any]
        let isFullWidth = (style["width"] as? String) == "100%"
        return NudgeBox(
            fillWidth: isFullWidth,
            fixedWidth: isFullWidth ? nil : parseDouble(style["width"]).map { CGFloat($0) },
            fixedHeight: parseDouble(style["height"]).map { CGFloat($0) },
            background: parseColor((style["bgColor"] ?? style["backgroundColor"]) as? String),
            paddingLeft: parseSide(style["padding"], key: "left"),
            paddingTop: parseSide(style["padding"], key: "top"),
            paddingRight: parseSide(style["padding"], key: "right"),
            paddingBottom: parseSide(style["padding"], key: "bottom"),
            marginLeft: parseSide(style["margin"], key: "left"),
            marginTop: parseSide(style["margin"], key: "top"),
            marginRight: parseSide(style["margin"], key: "right"),
            marginBottom: parseSide(style["margin"], key: "bottom"),
            borderRadius: CGFloat(parseDouble(style["borderRadius"]) ?? 0),
            borderColor: border.flatMap { parseColor($0["borderColor"] as? String) },
            borderWidth: CGFloat(parseDouble(border?["borderWidth"]) ?? 0),
            selfAlign: parseSelfAlign(cp["align"] as? String ?? "")
        )
    }

    // ── helpers ──────────────────────────────────────────────────────────────────

    /// Coerces a JSON value to Double whether the backend sent it as a number or
    /// a numeric string. Mirrors Android's `org.json.optDouble` / Flutter's
    /// `optDouble`, which both parse string-encoded numbers — a raw `as? Double`
    /// cast silently drops those (e.g. a `"1"` borderWidth → 0 → no border).
    private func parseDouble(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: return n.doubleValue
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let s as String: return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    private func parseSide(_ value: Any?, key: String) -> CGFloat {
        if let d = value as? [String: Any] {
            return parseDouble(d[key]).map { CGFloat($0) } ?? 0
        }
        return parseDouble(value).map { CGFloat($0) } ?? 0
    }

    private func parseColor(_ hex: String?) -> Color? {
        guard let hex, !hex.isEmpty else { return nil }
        return Color(hex: hex.trimmingCharacters(in: .whitespaces))
    }

    private func crossAxis(_ v: String) -> NudgeCrossAxisAlignment {
        switch v {
        case "center": return .center
        case "end": return .end
        default: return .start
        }
    }

    private func mainAxis(_ v: String) -> NudgeMainAxisAlignment {
        switch v {
        case "center": return .center
        case "end": return .end
        case "spaceBetween": return .spaceBetween
        case "spaceAround": return .spaceAround
        case "spaceEvenly": return .spaceEvenly
        default: return .start
        }
    }

    private func parseTextAlignment(_ v: String) -> TextAlignment {
        switch v {
        case "center": return .center
        case "right", "end": return .trailing
        default: return .leading
        }
    }

    private func parseFit(_ v: String) -> NudgeContentFit {
        switch v {
        case "contain": return .contain
        case "fill": return .fill
        default: return .cover
        }
    }

    private func parseFontWeight(_ v: String) -> Font.Weight {
        switch v {
        case "500": return .medium
        case "600": return .semibold
        case "700": return .bold
        default: return .regular
        }
    }

    private func parseButtonVariant(_ v: String) -> NudgeButtonVariant {
        switch v {
        case "outline": return .outline
        case "text": return .text
        case "elevated": return .elevated
        default: return .fill
        }
    }

    private func parseSelfAlign(_ v: String) -> NudgeSelfAlign? {
        switch v {
        case "start": return .start
        case "center": return .center
        case "end": return .end
        default: return nil
        }
    }
}
