import Foundation

struct ParsedCanvasSurveyDocument {
    let canvas: CampaignCanvas
    let hosts: [CanvasSurveyHostElement]
    let managedHosts: [CanvasSurveyManagedHostElement]
}

struct CanvasSurveyDocumentParser {
    var designTokens: DesignTokenCatalog = .empty
    var hostElements = CanvasSurveyHostElementCodecRegistry()

    func parse(
        _ document: [String: JSONValue]?,
        fallbackDesignWidth: CGFloat
    ) -> ParsedCanvasSurveyDocument {
        guard let canvasJson = Self.documentCanvas(document) else {
            return empty(fallbackDesignWidth: fallbackDesignWidth)
        }
        var normalized = canvasSurveyJsonObject(canvasJson)
        normalized["version"] = normalized["version"] ?? 2
        normalized["canvasWidth"] = normalized["canvasWidth"] ?? fallbackDesignWidth
        normalized["canvasHeight"] = normalized["canvasHeight"] ?? 420
        normalized["children"] = normalized["children"] ?? []
        guard let canvas = try? CampaignCanvasParser(designTokens: designTokens).parse(normalized) else {
            return empty(fallbackDesignWidth: fallbackDesignWidth)
        }
        let hosts = self.hosts(canvasJson, canvasWidth: canvas.width, canvasHeight: canvas.height)
        return ParsedCanvasSurveyDocument(
            canvas: canvas,
            hosts: hosts,
            managedHosts: hosts.compactMap {
                if case .managed(let host) = $0 { return host }
                return nil
            }
        )
    }

    func empty(fallbackDesignWidth: CGFloat) -> ParsedCanvasSurveyDocument {
        let width = fallbackDesignWidth > 0 ? fallbackDesignWidth : 360
        return ParsedCanvasSurveyDocument(
            canvas: CampaignCanvas(
                version: 2,
                width: width,
                height: 420,
                background: .solid(.literal("#00000000")),
                children: []
            ),
            hosts: [],
            managedHosts: []
        )
    }

    static func documentCanvas(_ document: [String: JSONValue]?) -> [String: JSONValue]? {
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

    private func hosts(
        _ canvasJson: [String: JSONValue],
        canvasWidth: CGFloat,
        canvasHeight: CGFloat
    ) -> [CanvasSurveyHostElement] {
        let context = CanvasSurveyParseContext(designTokens: designTokens)
        let children = (SurveyParse.array(canvasJson["children"]) ?? []).compactMap(SurveyParse.object)
        return children.compactMap {
            hostElements.parse($0, canvasWidth: canvasWidth, canvasHeight: canvasHeight, context: context)
        }
    }
}
