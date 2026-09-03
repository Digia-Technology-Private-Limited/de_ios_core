import Foundation

extension SurveyBlockType {
    static func canvasQuestionType(_ value: String?) -> SurveyBlockType? {
        switch value?.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "-", with: "_") {
        case "single_select": return .singleSelect
        case "multi_select": return .multiSelect
        case "upvote": return .upvote
        case "short_text": return .shortText
        case "long_text": return .longText
        case "number": return .number
        case "email": return .email
        case "date": return .date
        case "rating": return .rating
        case "reaction": return .reaction
        case "numeric_nps": return .nps
        case "nps_emoji": return .npsEmoji
        case "nps_smiley": return .npsSmiley
        case "this_or_that": return .thisOrThat
        case "tier_list": return .tierList
        default: return nil
        }
    }
}

enum CanvasSurveyConfigParser {
    private struct ParsedCanvasDocument {
        let canvas: CampaignCanvas
        let hosts: [CanvasSurveyHostElement]
        let managedHosts: [CanvasSurveyManagedHostElement]
    }

    private enum SceneKind {
        case question
        case content
        case result
    }

    static func from(
        _ json: [String: JSONValue],
        fallbackId: String,
        designTokens: DesignTokenCatalog = .empty
    ) -> SurveyConfigModel? {
        guard SurveyParse.string(json["templateType"]) == "survey",
              let scenesArr = SurveyParse.array(json["scenes"]),
              let flow = SurveyParse.object(json["flow"]),
              let flowNodesArr = SurveyParse.array(flow["nodes"]) else { return nil }
        let welcome = SurveyParse.object(json["welcome"]).flatMap(welcomeBlock)
        let sceneBlocks = scenesArr
            .compactMap { SurveyParse.object($0) }
            .compactMap { sceneBlock($0, designTokens: designTokens) }
        let blocks = [welcome].compactMap { $0 } + sceneBlocks
        let sceneIds = Set(sceneBlocks.map(\.id))
        let nodes = flowNodesArr.compactMap { value -> SurveyNode? in
            guard let node = SurveyParse.object(value),
                  let id = SurveyParse.nonBlank(node["id"]),
                  let sceneId = SurveyParse.nonBlank(node["sceneId"]),
                  sceneIds.contains(sceneId) else { return nil }
            return SurveyNode(id: id, blockId: sceneId, branching: nodeBranching(node))
        }
        guard !sceneBlocks.isEmpty, !nodes.isEmpty else { return nil }

        let rootNodeIdRaw = SurveyParse.nonBlank(flow["rootNodeId"])
        let rootNodeId = (rootNodeIdRaw.map { id in nodes.contains { $0.id == id } } == true)
            ? rootNodeIdRaw : nodes.first?.id
        let name = SurveyParse.firstNonEmptyOptional(
            SurveyParse.string(json["name"]),
            SurveyParse.string(json["surveyName"]),
            SurveyParse.string(json["title"])
        )
        return SurveyConfigModel(
            id: SurveyParse.firstNonEmpty(
                SurveyParse.string(json["id"]),
                SurveyParse.string(json["_id"]),
                SurveyParse.string(json["templateId"]),
                fallbackId
            ),
            name: name,
            blocks: blocks,
            nodes: nodes,
            rootNodeId: rootNodeId,
            settings: settings(json),
            theme: SurveyTheme.from(SurveyParse.object(json["theme"])),
            uiTemplateId: SurveyParse.nonBlank(json["uiTemplateId"]),
            timeDelayMs: max(0, min(10_000, SurveyParse.int(json["timeDelayMs"]) ?? 0)),
            canvasSurvey: CanvasSurveyConfig(
                designWidth: designWidth(json),
                welcomeDocument: welcomeDocument(json, designTokens: designTokens),
                scenesByBlockId: sceneDocuments(
                    scenesArr,
                    root: json,
                    designTokens: designTokens,
                    fallbackDesignWidth: designWidth(json)
                )
            )
        )
    }

    private static func welcomeBlock(_ json: [String: JSONValue]) -> SurveyBlock? {
        guard SurveyParse.bool(json["enabled"]) ?? false else { return nil }
        return SurveyBlock(
            id: SurveyParse.nonBlank(json["id"]) ?? "canvas_welcome",
            type: .welcome,
            title: RichText(text: canvasTitle(json, fallback: "Welcome")),
            body: nil,
            options: [],
            optionStyle: nil,
            npsStyle: nil,
            required: false,
            hidden: false,
            showMedia: false,
            media: .empty,
            showTag: false,
            showAnswerMedia: false,
            showAnswerDescriptions: false,
            shuffle: false,
            allowOther: false,
            answerLayout: .column,
            backgroundColor: "",
            numberMin: nil,
            numberMax: nil,
            showWhen: nil
        )
    }

    private static func sceneBlock(
        _ json: [String: JSONValue],
        designTokens: DesignTokenCatalog
    ) -> SurveyBlock? {
        guard let id = SurveyParse.nonBlank(json["id"]),
              SurveyParse.bool(json["enabled"]) ?? true else { return nil }
        let kind = sceneKind(SurveyParse.string(json["kind"]) ?? "question")
        let input = SurveyParse.object(json["input"])
        let inputType = input.flatMap { SurveyParse.string($0["type"]) }
        let type: SurveyBlockType?
        switch kind {
        case .question: type = SurveyBlockType.canvasQuestionType(inputType) ?? SurveyParse.blockType(inputType)
        case .result: type = .resultPage
        case .content: type = .textMedia
        }
        guard let type else { return nil }
        let answerPresentation = answerPresentation(json)
        let parsedOptions = (input.flatMap { SurveyParse.array($0["options"]) } ?? [])
            .compactMap { SurveyParse.object($0) }
            .compactMap(SurveyOption.from)
        return SurveyBlock(
            id: id,
            type: type,
            title: RichText(text: sceneTitle(json)),
            body: nil,
            options: parsedOptions.isEmpty ? SurveyParse.fallbackOptions(for: type) : parsedOptions,
            optionStyle: inputStyle(answerPresentation, designTokens: designTokens),
            npsStyle: npsStyle(input, presentation: answerPresentation, designTokens: designTokens),
            required: input.flatMap { SurveyParse.bool($0["required"]) } ?? (kind == .question),
            hidden: false,
            showMedia: false,
            media: .empty,
            showTag: false,
            showAnswerMedia: false,
            showAnswerDescriptions: false,
            shuffle: false,
            allowOther: false,
            answerLayout: answerLayout(answerPresentation),
            backgroundColor: "",
            numberMin: input.flatMap { SurveyParse.double($0["minimum"]) },
            numberMax: input.flatMap { SurveyParse.double($0["maximum"]) },
            showWhen: nil
        )
    }

    private static func inputStyle(
        _ input: [String: JSONValue]?,
        designTokens: DesignTokenCatalog
    ) -> ElementStyle? {
        guard let style = input.flatMap({ SurveyParse.object($0["style"]) }) else { return nil }
        return ElementStyle(
            size: max(0, SurveyParse.double(style["fontSize"]) ?? 0),
            weight: SurveyParse.fontWeight(SurveyParse.string(style["fontWeight"])),
            align: .left,
            colorHex: colorHex(style["textColor"], designTokens: designTokens, fallback: "#FF18181B")
        )
    }

    private static func npsStyle(
        _ input: [String: JSONValue]?,
        presentation: [String: JSONValue]?,
        designTokens: DesignTokenCatalog
    ) -> NpsStyle? {
        guard let input else { return nil }
        let type = normalise(SurveyParse.string(input["type"])) ?? ""
        guard type.contains("nps") else { return nil }
        let style = SurveyParse.object(presentation?["style"]) ?? [:]
        let cornerRadius = SurveyParse.double(style["cornerRadius"]) ?? 8
        let borderWidth = SurveyParse.double(style["borderWidth"]) ?? 1
        return NpsStyle(
            shape: "square",
            borderRadius: cornerRadius,
            borderWidth: borderWidth,
            borderColor: colorHex(style["borderColor"], designTokens: designTokens, fallback: "#FFE4E6EB"),
            backgroundColor: colorHex(style["unselectedFill"], designTokens: designTokens, fallback: "#FFF4F5F8"),
            selectedTile: NpsTileStyle(
                shape: "square",
                borderRadius: cornerRadius,
                borderWidth: borderWidth,
                borderColor: colorHex(
                    style["selectedBorderColor"],
                    designTokens: designTokens,
                    fallback: "#FF4945FF"
                ),
                backgroundColor: colorHex(style["selectedFill"], designTokens: designTokens, fallback: "#FFFFFFFF")
            ),
            textStyle: inputStyle(presentation, designTokens: designTokens) ?? ElementStyle(),
            scaleColors: NpsStyle.defaultScaleColors,
            tierEmojis: NpsStyle.defaultTierEmojis,
            selectedBgColor: colorHex(style["selectedFill"], designTokens: designTokens, fallback: "#FFFFFFFF"),
            faces: [],
            showFaceLabels: true
        )
    }

    private static func sceneTitle(_ scene: [String: JSONValue]) -> String {
        let promptId = SurveyParse.object(scene["roles"]).flatMap { SurveyParse.nonBlank($0["prompt"]) }
        return canvasTitle(
            scene,
            preferredChildId: promptId,
            fallback: SurveyParse.string(scene["title"]) ?? "Question"
        )
    }

    private static func canvasTitle(
        _ json: [String: JSONValue],
        preferredChildId: String? = nil,
        fallback: String
    ) -> String {
        let children = SurveyParse.object(json["canvas"]).flatMap { SurveyParse.array($0["children"]) } ?? []
        for value in children {
            guard let child = SurveyParse.object(value) else { continue }
            if let preferredChildId, SurveyParse.string(child["id"]) != preferredChildId { continue }
            let spans = SurveyParse.object(child["widget"])
                .flatMap { SurveyParse.object($0["props"]) }
                .flatMap { SurveyParse.array($0["spans"]) }
            let text = plainText(spans)
            if !text.isEmpty { return text }
        }
        return fallback
    }

    private static func plainText(_ spans: [JSONValue]?) -> String {
        (spans ?? [])
            .compactMap { SurveyParse.object($0) }
            .compactMap { SurveyParse.string($0["text"]) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func answerLayout(_ input: [String: JSONValue]?) -> AnswerLayout {
        switch input.flatMap({ SurveyParse.object($0["style"]) }).flatMap({ SurveyParse.string($0["layout"]) }) {
        case "row": return .row
        case "grid": return .grid
        default: return .column
        }
    }

    private static func answerPresentation(_ scene: [String: JSONValue]) -> [String: JSONValue]? {
        let answerId = SurveyParse.object(scene["roles"]).flatMap { SurveyParse.nonBlank($0["answerInput"]) }
        let children = SurveyParse.object(scene["canvas"]).flatMap { SurveyParse.array($0["children"]) } ?? []
        for value in children {
            guard let child = SurveyParse.object(value) else { continue }
            if let answerId, SurveyParse.string(child["id"]) != answerId { continue }
            let element = SurveyParse.object(child["element"])
            guard SurveyParse.string(element?["type"]) == "canvasSurvey.answerInput" else { continue }
            return SurveyParse.object(element?["props"])
        }
        return nil
    }

    private static func nodeBranching(_ node: [String: JSONValue]) -> NodeBranching {
        let rules = (SurveyParse.array(node["rules"]) ?? [])
            .compactMap { SurveyParse.object($0) }
            .compactMap(branchRule)
        return NodeBranching(
            type: rules.isEmpty ? .linear : .byCondition,
            rules: rules,
            parentNodeId: nil,
            defaultTarget: target(SurveyParse.object(node["fallback"]))
        )
    }

    private static func branchRule(_ json: [String: JSONValue]) -> BranchRule? {
        guard let id = SurveyParse.nonBlank(json["id"]) else { return nil }
        let conditions = (SurveyParse.array(json["conditions"]) ?? [])
            .compactMap { SurveyParse.object($0) }
            .compactMap(condition)
        guard !conditions.isEmpty else { return nil }
        return BranchRule(
            id: id,
            whenExpr: ConditionExpr(
                operator: SurveyParse.boolOp(SurveyParse.string(json["conditionOperator"]), default: .and),
                groups: [ConditionGroup(operator: .and, conditions: conditions)]
            ),
            target: target(SurveyParse.object(json["target"]))
        )
    }

    private static func condition(_ json: [String: JSONValue]) -> Condition? {
        let op: ConditionOperator?
        let rawOperator = SurveyParse.string(json["operator"])
        switch rawOperator?.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "-", with: "_") {
        case "answered": op = .isAnswered
        default: op = SurveyParse.conditionOperator(rawOperator)
        }
        guard let op else { return nil }
        return Condition(
            nodeId: SurveyParse.nonBlank(json["sourceNodeId"]),
            operator: op,
            values: conditionValues(json["value"])
        )
    }

    private static func conditionValues(_ value: JSONValue?) -> [String] {
        if let values = SurveyParse.array(value) {
            return values.compactMap { SurveyParse.nonBlank($0) }
        }
        return SurveyParse.nonBlank(value).map { [$0] } ?? []
    }

    private static func target(_ json: [String: JSONValue]?) -> BranchTarget {
        guard let json else { return .next }
        switch SurveyParse.string(json["kind"]) {
        case "node":
            return BranchTarget(kind: .node, nodeId: SurveyParse.nonBlank(json["nodeId"]), url: "")
        case "redirect":
            return BranchTarget(kind: .url, nodeId: nil, url: SurveyParse.string(json["url"]) ?? "")
        case "end":
            return .end
        default:
            return .next
        }
    }

    private static func settings(_ json: [String: JSONValue]) -> SurveySettings {
        let behavior = SurveyParse.object(json["behavior"]) ?? [:]
        return SurveySettings(
            pagination: PaginationSettings(
                numberOfPages: SurveyParse.bool(behavior["showPageCount"]) ?? true,
                progressbar: SurveyParse.bool(behavior["showProgress"]) ?? true,
                onlyShowOnQuestionBlock: SurveyParse.bool(behavior["countQuestionsOnly"]) ?? true,
                backButton: true,
                paginationStyle: .continuous,
                progressIndicatorStyle: .default
            ),
            autoAdvance: SurveyParse.bool(behavior["autoAdvance"]) ?? false,
            chooseButton: SurveyParse.bool(behavior["showPrimaryNavigation"]) ?? true,
            cta: .default,
            timer: SurveyTimerSettings(
                enabled: SurveyParse.bool(behavior["timerEnabled"]) ?? false,
                pauseOnNonTimerBlock: SurveyParse.bool(behavior["pauseTimerOnContent"]) ?? true,
                timeLimitSeconds: max(0, SurveyParse.int(behavior["timerDurationSeconds"]) ?? 0),
                warningAtSeconds: max(0, SurveyParse.int(behavior["timerWarningSeconds"]) ?? 0),
                autoPauseBetweenBlocks: false
            ),
            display: display(json)
        )
    }

    private static func display(_ json: [String: JSONValue]) -> SurveyDisplay {
        let display = SurveyParse.object(json["display"]) ?? [:]
        let cornerRadius = SurveyParse.int(display["cornerRadius"]) ?? 20
        let backdropDismissible = SurveyParse.bool(display["backdropDismissible"]) ?? true
        return SurveyDisplay(
            type: SurveyParse.displayType(SurveyParse.string(display["type"])),
            dialog: DialogProps(
                width: .medium,
                customWidth: 0,
                cornerRadius: cornerRadius,
                backdropOpacity: 0.4,
                backdropDismissible: backdropDismissible,
                showCloseButton: SurveyParse.bool(display["showCloseButton"]) ?? true
            ),
            bottomSheet: BottomSheetProps(
                heightMode: .wrap,
                customHeight: 0,
                cornerRadius: cornerRadius,
                showHandle: SurveyParse.bool(display["showHandle"]) ?? true,
                draggable: SurveyParse.bool(display["dragDismissible"]) ?? true,
                backdropDismissible: backdropDismissible
            )
        )
    }

    private static func designWidth(_ json: [String: JSONValue]) -> CGFloat {
        let display = SurveyParse.object(json["display"]) ?? [:]
        let sharedCanvas = documentCanvas(SurveyParse.object(json["sharedUi"]))
        let width = SurveyParse.double(display["designWidth"])
            ?? SurveyParse.double(json["designWidth"])
            ?? sharedCanvas.flatMap { SurveyParse.double($0["canvasWidth"]) }
            ?? 360
        return CGFloat(width > 0 ? width : 360)
    }

    private static func sceneDocuments(
        _ scenes: [JSONValue],
        root: [String: JSONValue],
        designTokens: DesignTokenCatalog,
        fallbackDesignWidth: CGFloat
    ) -> [String: CanvasSurveySceneDocument] {
        let sharedCanvas = parseCanvasDocument(
            SurveyParse.object(root["sharedUi"]),
            designTokens: designTokens,
            fallbackDesignWidth: fallbackDesignWidth
        )
        var documents: [String: CanvasSurveySceneDocument] = [:]
        for value in scenes {
            guard let scene = SurveyParse.object(value),
                  let id = SurveyParse.nonBlank(scene["id"]) else { continue }
            let canvas = parseCanvasDocument(
                SurveyParse.object(scene["canvas"]),
                designTokens: designTokens,
                fallbackDesignWidth: fallbackDesignWidth
            )
            let sceneShared = parseCanvasDocument(
                SurveyParse.object(scene["sharedUi"]),
                designTokens: designTokens,
                fallbackDesignWidth: canvas.canvas.width,
                fallback: sharedCanvas
            )
            documents[id] = CanvasSurveySceneDocument(
                kind: canvasSceneKind(sceneKind(SurveyParse.string(scene["kind"]) ?? "question")),
                canvas: canvas.canvas,
                sharedUi: sceneShared.canvas,
                canvasHosts: canvas.hosts,
                sharedUiHosts: sceneShared.managedHosts
            )
        }
        return documents
    }

    private static func welcomeDocument(
        _ json: [String: JSONValue],
        designTokens: DesignTokenCatalog
    ) -> CanvasSurveyDocument? {
        guard let welcome = SurveyParse.object(json["welcome"]),
              SurveyParse.bool(welcome["enabled"]) ?? false else { return nil }
        let fallbackDesignWidth = designWidth(json)
        let sharedCanvas = parseCanvasDocument(
            SurveyParse.object(json["sharedUi"]),
            designTokens: designTokens,
            fallbackDesignWidth: fallbackDesignWidth
        )
        let canvas = parseCanvasDocument(
            SurveyParse.object(welcome["canvas"]),
            designTokens: designTokens,
            fallbackDesignWidth: fallbackDesignWidth
        )
        let welcomeShared = parseCanvasDocument(
            SurveyParse.object(welcome["sharedUi"]),
            designTokens: designTokens,
            fallbackDesignWidth: canvas.canvas.width,
            fallback: sharedCanvas
        )
        return CanvasSurveyDocument(
            canvas: canvas.canvas,
            sharedUi: welcomeShared.canvas,
            canvasHosts: canvas.hosts,
            sharedUiHosts: welcomeShared.managedHosts
        )
    }

    private static func parseCanvasDocument(
        _ document: [String: JSONValue]?,
        designTokens: DesignTokenCatalog,
        fallbackDesignWidth: CGFloat,
        fallback: ParsedCanvasDocument? = nil
    ) -> ParsedCanvasDocument {
        guard let canvasJson = documentCanvas(document) else {
            return fallback ?? emptyDocument(fallbackDesignWidth: fallbackDesignWidth)
        }
        if let fallback, isSparseSharedUiOverride(canvasJson) {
            return materializedSharedUiOverride(
                canvasJson,
                fallback: fallback,
                fallbackDesignWidth: fallbackDesignWidth
            )
        }
        var normalized = jsonObject(canvasJson)
        normalized["version"] = normalized["version"] ?? 2
        normalized["canvasWidth"] = normalized["canvasWidth"] ?? fallbackDesignWidth
        normalized["canvasHeight"] = normalized["canvasHeight"] ?? 420
        normalized["children"] = normalized["children"] ?? []
        guard let canvas = try? CampaignCanvasParser(designTokens: designTokens).parse(normalized) else {
            return fallback ?? emptyDocument(fallbackDesignWidth: fallbackDesignWidth)
        }
        let children = SurveyParse.array(canvasJson["children"]) ?? []
        let hosts = hostElements(children, canvasWidth: canvas.width, canvasHeight: canvas.height, designTokens: designTokens)
        return ParsedCanvasDocument(
            canvas: canvas,
            hosts: hosts,
            managedHosts: hosts.compactMap {
                if case .managed(let host) = $0 { return host }
                return nil
            }
        )
    }

    private static func isSparseSharedUiOverride(_ canvas: [String: JSONValue]) -> Bool {
        guard let children = SurveyParse.array(canvas["children"]) else { return false }
        return children.allSatisfy { value in
            guard let child = SurveyParse.object(value) else { return false }
            return child["kind"] == nil && child["element"] == nil && child["widget"] == nil
        }
    }

    private static func materializedSharedUiOverride(
        _ canvas: [String: JSONValue],
        fallback: ParsedCanvasDocument,
        fallbackDesignWidth: CGFloat
    ) -> ParsedCanvasDocument {
        let width = CGFloat(
            SurveyParse.double(canvas["canvasWidth"])
                ?? Double(fallback.canvas.width > 0 ? fallback.canvas.width : fallbackDesignWidth)
        )
        let height = CGFloat(
            SurveyParse.double(canvas["canvasHeight"])
                ?? Double(fallback.canvas.height > 0 ? fallback.canvas.height : 420)
        )
        let overrides = sharedUiRectOverrides(
            SurveyParse.array(canvas["children"]) ?? [],
            canvasWidth: width,
            canvasHeight: height
        )
        let ids = Set(overrides.keys)
        let children = fallback.canvas.children.compactMap { child -> CampaignCanvasChild? in
            guard ids.contains(child.id) else { return nil }
            return replaceRect(on: child, rect: overrides[child.id] ?? child.rect)
        }
        let hosts = fallback.hosts.compactMap { host -> CanvasSurveyHostElement? in
            guard ids.contains(host.id) else { return nil }
            return replaceRect(on: host, rect: overrides[host.id] ?? host.rect)
        }
        return ParsedCanvasDocument(
            canvas: CampaignCanvas(
                version: 2,
                width: width > 0 ? width : 360,
                height: height > 0 ? height : 420,
                background: fallback.canvas.background,
                children: children
            ),
            hosts: hosts,
            managedHosts: hosts.compactMap {
                if case .managed(let host) = $0 { return host }
                return nil
            }
        )
    }

    private static func sharedUiRectOverrides(
        _ children: [JSONValue],
        canvasWidth: CGFloat,
        canvasHeight: CGFloat
    ) -> [String: CampaignCanvasRect] {
        var overrides: [String: CampaignCanvasRect] = [:]
        for value in children {
            guard let child = SurveyParse.object(value),
                  let id = SurveyParse.nonBlank(child["id"]),
                  let rectJson = SurveyParse.object(child["rect"]) else { continue }
            overrides[id] = CampaignCanvasRect(
                x: CGFloat(SurveyParse.double(rectJson["x"]) ?? 0) * canvasWidth,
                y: CGFloat(SurveyParse.double(rectJson["y"]) ?? 0) * canvasHeight,
                width: max(0, CGFloat(SurveyParse.double(rectJson["width"]) ?? 0) * canvasWidth),
                height: max(0, CGFloat(SurveyParse.double(rectJson["height"]) ?? 0) * canvasHeight)
            )
        }
        return overrides
    }

    private static func replaceRect(
        on child: CampaignCanvasChild,
        rect: CampaignCanvasRect
    ) -> CampaignCanvasChild {
        switch child {
        case .widget(let id, _, let widget):
            return .widget(id: id, rect: rect, widget: widget)
        case .tapRegion(let id, _, let actions):
            return .tapRegion(id: id, rect: rect, actions: actions)
        }
    }

    private static func replaceRect(
        on host: CanvasSurveyHostElement,
        rect: CampaignCanvasRect
    ) -> CanvasSurveyHostElement {
        switch host {
        case .answer(let host):
            return .answer(CanvasSurveyAnswerHostElement(id: host.id, rect: rect))
        case .managed(let host):
            return .managed(replaceRect(on: host, rect: rect))
        }
    }

    private static func replaceRect(
        on host: CanvasSurveyManagedHostElement,
        rect: CampaignCanvasRect
    ) -> CanvasSurveyManagedHostElement {
        CanvasSurveyManagedHostElement(
            id: host.id,
            rect: rect,
            role: host.role,
            visible: host.visible,
            label: host.label,
            doneLabel: host.doneLabel,
            colorHex: host.colorHex,
            fillHex: host.fillHex,
            trackColorHex: host.trackColorHex,
            borderColorHex: host.borderColorHex,
            borderWidth: host.borderWidth,
            cornerRadius: host.cornerRadius,
            fontSize: host.fontSize,
            gap: host.gap,
            padding: host.padding,
            progressStyle: host.progressStyle
        )
    }

    private static func documentCanvas(_ document: [String: JSONValue]?) -> [String: JSONValue]? {
        guard let document else { return nil }
        if let canvas = SurveyParse.object(document["canvas"]) { return canvas }
        if document["children"] != nil ||
            document["canvasWidth"] != nil ||
            document["canvasHeight"] != nil ||
            document["version"] != nil {
            return document
        }
        return nil
    }

    private static func emptyDocument(fallbackDesignWidth: CGFloat) -> ParsedCanvasDocument {
        let width = fallbackDesignWidth > 0 ? fallbackDesignWidth : 360
        return ParsedCanvasDocument(
            canvas: CampaignCanvas(
                version: 2,
                width: width,
                height: 420,
                background: .solid(.literal("#FFFFFFFF")),
                children: []
            ),
            hosts: [],
            managedHosts: []
        )
    }

    private static func hostElements(
        _ children: [JSONValue],
        canvasWidth: CGFloat,
        canvasHeight: CGFloat,
        designTokens: DesignTokenCatalog
    ) -> [CanvasSurveyHostElement] {
        children.compactMap { value in
            guard let child = SurveyParse.object(value),
                  SurveyParse.string(child["kind"]) == "hostElement",
                  let element = SurveyParse.object(child["element"]),
                  let rectJson = SurveyParse.object(child["rect"]) else { return nil }
            let id = SurveyParse.string(child["id"]) ?? ""
            let rect = CampaignCanvasRect(
                x: CGFloat(SurveyParse.double(rectJson["x"]) ?? 0) * canvasWidth,
                y: CGFloat(SurveyParse.double(rectJson["y"]) ?? 0) * canvasHeight,
                width: max(0, CGFloat(SurveyParse.double(rectJson["width"]) ?? 0) * canvasWidth),
                height: max(0, CGFloat(SurveyParse.double(rectJson["height"]) ?? 0) * canvasHeight)
            )
            switch SurveyParse.string(element["type"]) {
            case "canvasSurvey.answerInput":
                return .answer(CanvasSurveyAnswerHostElement(id: id, rect: rect))
            case "canvasSurvey.managed":
                guard let props = SurveyParse.object(element["props"]),
                      let role = managedRole(SurveyParse.string(props["role"])) else { return nil }
                return .managed(CanvasSurveyManagedHostElement(
                    id: id,
                    rect: rect,
                    role: role,
                    visible: SurveyParse.bool(props["visible"]) ?? true,
                    label: SurveyParse.string(props["label"]) ?? "",
                    doneLabel: SurveyParse.string(props["doneLabel"]) ?? "",
                    colorHex: colorHex(props["color"], designTokens: designTokens, fallback: "#FF18181B"),
                    fillHex: colorHex(props["fill"], designTokens: designTokens, fallback: "#FFF4F4F5"),
                    trackColorHex: colorHex(props["trackColor"], designTokens: designTokens, fallback: "#FFE5E7EB"),
                    borderColorHex: colorHex(props["borderColor"], designTokens: designTokens, fallback: "#00000000"),
                    borderWidth: CGFloat(max(0, SurveyParse.double(props["borderWidth"]) ?? 0)),
                    cornerRadius: CGFloat(max(0, SurveyParse.double(props["cornerRadius"]) ?? 999)),
                    fontSize: CGFloat(min(64, max(8, SurveyParse.double(props["fontSize"]) ?? 14))),
                    gap: CGFloat(min(64, max(0, SurveyParse.double(props["gap"]) ?? 4))),
                    padding: CGFloat(min(64, max(0, SurveyParse.double(props["padding"]) ?? 6))),
                    progressStyle: SurveyParse.string(props["progressStyle"]) ?? "segmented"
                ))
            default:
                return nil
            }
        }
    }

    private static func sceneKind(_ value: String?) -> SceneKind {
        switch normalise(value) {
        case "question": return .question
        case "result": return .result
        default: return .content
        }
    }

    private static func canvasSceneKind(_ kind: SceneKind) -> CanvasSurveySceneKind {
        switch kind {
        case .question: return .question
        case .content: return .content
        case .result: return .result
        }
    }

    private static func managedRole(_ role: String?) -> CanvasSurveyManagedRole? {
        switch role {
        case "progress": return .progress
        case "pageCount": return .pageCount
        case "timer": return .timer
        case "primaryNavigation": return .primaryNavigation
        case "backNavigation": return .backNavigation
        case "dismiss": return .dismiss
        default: return nil
        }
    }

    private static func colorHex(
        _ value: JSONValue?,
        designTokens: DesignTokenCatalog,
        fallback: String
    ) -> String {
        (try? designTokens.resolveColor(jsonAny(value)))?.lightHex
            ?? canonicalCampaignColorHex(unwrapLiteral(jsonAny(value)))
            ?? fallback
    }

    private static func normalise(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
    }

    private static func jsonObject(_ json: [String: JSONValue]) -> [String: Any] {
        json.mapValues(jsonAny)
    }

    private static func jsonAny(_ value: JSONValue?) -> Any {
        guard let value else { return NSNull() }
        switch value {
        case .string(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .bool(let value): return value
        case .array(let value): return value.map(jsonAny)
        case .object(let value): return jsonObject(value)
        case .null: return NSNull()
        }
    }
}
