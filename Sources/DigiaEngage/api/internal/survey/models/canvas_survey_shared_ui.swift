import Foundation

struct CanvasSurveySharedUiOverlay {
    func apply(
        overrideDocument: [String: JSONValue]?,
        master: ParsedCanvasSurveyDocument,
        body: ParsedCanvasSurveyDocument,
        fallbackDesignWidth: CGFloat,
        isWelcome: Bool,
        sceneKind: CanvasSurveySceneKind?,
        isRootScene: Bool,
        canNavigateBackFromRoot: Bool
    ) -> CanvasSurveyDocument {
        let canvasJson = CanvasSurveyDocumentParser.documentCanvas(overrideDocument)
        let rectOverrides: [String: CampaignCanvasRect]
        if let canvasJson,
           isSameCanvasSpace(canvasJson, body: body.canvas, fallbackDesignWidth: fallbackDesignWidth),
           let parsedOverrides = sparseRectOverrides(canvasJson, fallbackDesignWidth: fallbackDesignWidth) {
            rectOverrides = parsedOverrides
        } else {
            rectOverrides = [:]
        }
        let backNavigation = master.managedHosts.first { $0.role == .backNavigation }
        let hosts = master.managedHosts.compactMap { host -> CanvasSurveyManagedHostElement? in
            guard shouldInclude(
                host,
                isWelcome: isWelcome,
                sceneKind: sceneKind,
                isRootScene: isRootScene,
                canNavigateBackFromRoot: canNavigateBackFromRoot
            ) else { return nil }
            return replaceRect(
                on: host,
                rect: effectiveRect(
                    host: host,
                    sourceCanvas: master.canvas,
                    targetCanvas: body.canvas,
                    backNavigation: backNavigation,
                    override: rectOverrides[host.id],
                    isRootScene: isRootScene,
                    canNavigateBackFromRoot: canNavigateBackFromRoot
                )
            )
        }
        return CanvasSurveyDocument(
            canvas: body.canvas,
            sharedUi: emptyOverlay(masterCanvas: master.canvas, bodyCanvas: body.canvas),
            canvasHosts: body.hosts,
            sharedUiHosts: hosts
        )
    }

    private func shouldInclude(
        _ host: CanvasSurveyManagedHostElement,
        isWelcome: Bool,
        sceneKind: CanvasSurveySceneKind?,
        isRootScene: Bool,
        canNavigateBackFromRoot: Bool
    ) -> Bool {
        if isWelcome || sceneKind == .result {
            return host.visible && host.role == .dismiss
        }
        if !host.visible { return false }
        if host.role == .backNavigation && isRootScene && !canNavigateBackFromRoot {
            return false
        }
        return true
    }

    private func effectiveRect(
        host: CanvasSurveyManagedHostElement,
        sourceCanvas: CampaignCanvas,
        targetCanvas: CampaignCanvas,
        backNavigation: CanvasSurveyManagedHostElement?,
        override: CampaignCanvasRect?,
        isRootScene: Bool,
        canNavigateBackFromRoot: Bool
    ) -> CampaignCanvasRect {
        let inherited = defaultRect(
            host: host,
            sourceCanvas: sourceCanvas,
            targetCanvas: targetCanvas,
            backNavigation: backNavigation,
            isRootScene: isRootScene,
            canNavigateBackFromRoot: canNavigateBackFromRoot
        )
        guard let override else { return inherited }
        let positioned = CampaignCanvasRect(
            x: override.x,
            y: override.y,
            width: inherited.width,
            height: inherited.height
        )
        return fits(positioned, canvas: targetCanvas) ? positioned : inherited
    }

    private func defaultRect(
        host: CanvasSurveyManagedHostElement,
        sourceCanvas: CampaignCanvas,
        targetCanvas: CampaignCanvas,
        backNavigation: CanvasSurveyManagedHostElement?,
        isRootScene: Bool,
        canNavigateBackFromRoot: Bool
    ) -> CampaignCanvasRect {
        let positioned = isBottomAnchored(host.role)
            ? bottomAnchoredRect(host.rect, sourceCanvas: sourceCanvas, targetCanvas: targetCanvas)
            : positionedRect(host.rect, sourceCanvas: sourceCanvas, targetCanvas: targetCanvas)
        guard host.role == .primaryNavigation, isRootScene, !canNavigateBackFromRoot else {
            return positioned
        }
        let backRect = backNavigation.map {
            bottomAnchoredRect($0.rect, sourceCanvas: sourceCanvas, targetCanvas: targetCanvas)
        }
        let mappedLeft = min(positioned.x, backRect?.x ?? positioned.x)
        let mappedRight = max(0, targetCanvas.width - positioned.x - positioned.width)
        return CampaignCanvasRect(
            x: mappedLeft,
            y: positioned.y,
            width: max(1, targetCanvas.width - mappedLeft - mappedRight),
            height: host.rect.height
        )
    }

    private func isBottomAnchored(_ role: CanvasSurveyManagedRole) -> Bool {
        role == .primaryNavigation || role == .backNavigation
    }

    private func positionedRect(
        _ rect: CampaignCanvasRect,
        sourceCanvas: CampaignCanvas,
        targetCanvas: CampaignCanvas
    ) -> CampaignCanvasRect {
        CampaignCanvasRect(
            x: mapAxisPosition(rect.x, size: rect.width, sourceSize: sourceCanvas.width, targetSize: targetCanvas.width),
            y: mapAxisPosition(rect.y, size: rect.height, sourceSize: sourceCanvas.height, targetSize: targetCanvas.height),
            width: rect.width,
            height: rect.height
        )
    }

    private func bottomAnchoredRect(
        _ rect: CampaignCanvasRect,
        sourceCanvas: CampaignCanvas,
        targetCanvas: CampaignCanvas
    ) -> CampaignCanvasRect {
        let positioned = positionedRect(rect, sourceCanvas: sourceCanvas, targetCanvas: targetCanvas)
        let bottomOffset = sourceCanvas.height - rect.y - rect.height
        return CampaignCanvasRect(
            x: positioned.x,
            y: targetCanvas.height - bottomOffset - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    private func mapAxisPosition(
        _ position: CGFloat,
        size: CGFloat,
        sourceSize: CGFloat,
        targetSize: CGFloat
    ) -> CGFloat {
        let sourceTravel = max(1, sourceSize - size)
        let targetTravel = max(0, targetSize - size)
        return (position / sourceTravel) * targetTravel
    }

    private func fits(_ rect: CampaignCanvasRect, canvas: CampaignCanvas) -> Bool {
        let epsilon: CGFloat = 0.01
        return rect.x >= -epsilon &&
            rect.y >= -epsilon &&
            rect.x + rect.width <= canvas.width + epsilon &&
            rect.y + rect.height <= canvas.height + epsilon
    }

    private func sparseRectOverrides(
        _ canvas: [String: JSONValue],
        fallbackDesignWidth: CGFloat
    ) -> [String: CampaignCanvasRect]? {
        let children = SurveyParse.array(canvas["children"]) ?? []
        let width = CGFloat(SurveyParse.double(canvas["canvasWidth"]) ?? Double(fallbackDesignWidth))
        let height = CGFloat(SurveyParse.double(canvas["canvasHeight"]) ?? 420)
        var result: [String: CampaignCanvasRect] = [:]
        for value in children {
            guard let child = SurveyParse.object(value),
                  child["kind"] == nil,
                  child["widget"] == nil,
                  child["element"] == nil,
                  let id = SurveyParse.nonBlank(child["id"]),
                  let rectJson = SurveyParse.object(child["rect"]) else { return nil }
            result[id] = CampaignCanvasRect(
                x: CGFloat(SurveyParse.double(rectJson["x"]) ?? 0) * width,
                y: CGFloat(SurveyParse.double(rectJson["y"]) ?? 0) * height,
                width: max(0, CGFloat(SurveyParse.double(rectJson["width"]) ?? 0) * width),
                height: max(0, CGFloat(SurveyParse.double(rectJson["height"]) ?? 0) * height)
            )
        }
        return result
    }

    private func isSameCanvasSpace(
        _ canvas: [String: JSONValue],
        body: CampaignCanvas,
        fallbackDesignWidth: CGFloat
    ) -> Bool {
        let width = CGFloat(SurveyParse.double(canvas["canvasWidth"]) ?? Double(fallbackDesignWidth))
        let height = CGFloat(SurveyParse.double(canvas["canvasHeight"]) ?? 420)
        let epsilon: CGFloat = 0.01
        return abs(width - body.width) <= epsilon && abs(height - body.height) <= epsilon
    }

    private func emptyOverlay(masterCanvas: CampaignCanvas, bodyCanvas: CampaignCanvas) -> CampaignCanvas {
        CampaignCanvas(
            version: 2,
            width: bodyCanvas.width,
            height: bodyCanvas.height,
            background: masterCanvas.background,
            children: []
        )
    }

    private func replaceRect(
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
            progressStyle: host.progressStyle,
            countQuestionsOnly: host.countQuestionsOnly,
            iconColorHex: host.iconColorHex,
            iconSize: host.iconSize,
            button: host.button
        )
    }
}
