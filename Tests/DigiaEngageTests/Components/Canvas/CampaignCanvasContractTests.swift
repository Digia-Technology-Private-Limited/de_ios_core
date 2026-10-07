import Foundation
import Testing
@testable import DigiaEngage

@Suite("Campaign Canvas v2 contract", .serialized, .tags(.canvas, .contract))
struct CampaignCanvasContractTests {
    @Test("design tokens canonicalize themes and nested typography wrappers")
    func designTokens() throws {
        let catalog = try DesignTokenCatalog.fromJson([
            "supportedThemes": ["light", "dark"],
            "themes": [
                "light": ["colors": [["id": "surface", "value": "#abc"]]],
                "dark": ["colors": [["id": "surface", "value": ["value": "#80112233"]]]],
            ],
            "typography": [[
                "id": "body",
                "value": ["value": [
                    "fontFamily": ["value": "Inter"],
                    "fontSize": ["value": ["value": 16]],
                    "fontWeight": "W600",
                    "lineHeight": 24,
                    "letterSpacing": 0.25,
                ]],
            ]],
        ])

        #expect(try catalog.resolveColor(["token": "surface"]) == CampaignColor(lightHex: "#FFAABBCC", darkHex: "#80112233"))
        #expect(try catalog.resolveTypography(["value": ["token": "body"]]) == CampaignTypography(fontFamily: "Inter", fontSize: 16, fontWeight: 600, lineHeight: 24, letterSpacing: 0.25))
    }

    @Test("one configured theme supplies both runtime variants")
    func oneTheme() throws {
        let catalog = try DesignTokenCatalog.fromJson([
            "supportedThemes": ["brand"],
            "themes": ["brand": ["colors": [["id": "accent", "value": "#123456"]]]],
        ])

        #expect(try catalog.resolveColor(["token": "accent"]) == CampaignColor(lightHex: "#FF123456", darkHex: "#FF123456"))
        #expect(try catalog.resolveColor(["token": "missing"]) == nil)
        #expect(try catalog.resolveColor(["token": "accent", "value": "#fff"]) == CampaignColor(lightHex: "#FF123456", darkHex: "#FF123456"))
        #expect(try catalog.resolveColor(["token": ""]) == nil)
        #expect(throws: DesignTokenError.self) { try catalog.resolveTypography(["token": "body", "fontSize": 16]) }
    }

    @Test("a token defined for only one theme reuses that color for both variants")
    func oneThemeValue() throws {
        let catalog = try DesignTokenCatalog.fromJson([
            "supportedThemes": ["light", "dark"],
            "themes": [
                "light": ["colors": [["id": "accent", "value": "#112233"]]],
                "dark": ["colors": [["id": "accent", "value": ""]]],
            ],
        ])

        #expect(try catalog.resolveColor(["token": "accent"]) == CampaignColor(lightHex: "#FF112233", darkHex: "#FF112233"))
    }

    @Test("v2 parser expands normalized rects to pixel dimensions")
    func parserExpandsNormalizedRects() throws {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 200,
            "canvasHeight": 100,
            "children": [
                [
                    "kind": "widget", "id": "text",
                    "rect": ["x": 0.1, "y": 0.2, "width": 0.5, "height": 0.4],
                    "widget": ["type": "digia/text", "props": ["spans": []]],
                ],
            ],
        ])
        #expect(canvas.children[0].rect == CampaignCanvasRect(x: 20, y: 20, width: 100, height: 40))
    }

    @Test("v2 parser sorts canvas background gradient stops by offset")
    func parserSortsGradientStops() throws {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 200,
            "canvasHeight": 100,
            "background": [
                "type": "gradient",
                "stops": [
                    ["color": "#fff", "offset": 1],
                    ["color": "#000", "offset": 0],
                ],
            ],
            "children": [],
        ])
        guard case .gradient(_, _, _, _, _, _, _, let stops) = canvas.background else {
            Issue.record("Expected gradient background")
            return
        }
        #expect(stops.map(\.offset) == [0, 1])
    }

    @Test("unsupported Canvas versions are rejected")
    func unsupportedVersion() {
        #expect(throws: DesignTokenError.self) {
            try CampaignCanvasParser().parse(["version": 1])
        }
    }

    @Test("reset shadow color falls back without dropping the widget")
    func resetShadowColorFallsBack() throws {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 100,
            "background": ["type": "solid", "color": "#fff"],
            "children": [[
                "kind": "widget",
                "id": "container",
                "rect": ["x": 0, "y": 0, "width": 1, "height": 1],
                "widget": [
                    "type": "digia/canvasContainer",
                    "props": [
                        "fill": ["type": "solid", "color": "#fff"],
                        "shadow": ["color": "", "blur": 12, "spread": 3, "offsetY": 4],
                    ],
                ],
            ]],
        ])

        #expect(canvas.children.count == 1)
        guard case .widget(_, _, .container(_, _, _, let shadow)) = canvas.children.first else {
            Issue.record("Expected parsed canvas container")
            return
        }
        #expect(shadow?.color == CampaignColor.literal("#FF000000"))
    }

    @Test("all supported widgets have registered renderers and unknown widgets are omitted")
    @MainActor
    func allSupportedWidgetsHaveRenderer() throws {
        let canvas = try parseContractFixture()
        let widgets = canvas.children.compactMap { child -> CampaignCanvasWidget? in
            guard case .widget(_, _, let widget) = child else { return nil }
            return widget
        }
        #expect(widgets.count == 8)
        #expect(widgets.allSatisfy(CampaignCanvasRendererRegistry.hasRenderer))
    }

    @Test("child hit-testability reflects presence of actions")
    func childHitTestability() throws {
        let canvas = try parseContractFixture()
        #expect(canvas.children[0].isHitTestable)
        #expect(canvas.children[2].isHitTestable)
        #expect(!canvas.children[1].isHitTestable)
        #expect(!canvas.children[5].isHitTestable)
    }

    @Test("text widget contract preserves container box properties and text shadow")
    func textWidgetContract() throws {
        let canvas = try parseContractFixture()
        guard case .widget(_, _, .text(let box, let block, let textShadow)) = canvas.children[0] else {
            Issue.record("Expected text")
            return
        }
        #expect(box.padding == CampaignCanvasEdgeInsets(top: 1, right: 2, bottom: 3, left: 4))
        #expect(box.cornerRadius == CampaignCanvasCornerRadius(topLeft: 24, topRight: 20, bottomRight: 8, bottomLeft: 4))
        #expect(box.border?.width == 2)
        #expect(box.shadow?.spread == 4)
        #expect(textShadow?.spread == 2)
        #expect(textShadow?.offsetY == 5)
        #expect(block.spans.first?.typography?.lineHeight == nil)
    }

    @Test("image widget contract clamps focal position and scale")
    func imageWidgetContract() throws {
        let canvas = try parseContractFixture()
        guard case .widget(_, _, .image(_, _, _, let x, let y, let scale, _)) = canvas.children[1] else {
            Issue.record("Expected image")
            return
        }
        #expect(x == 1)
        #expect(y == 0)
        #expect(scale == 4)
    }

    @Test("button widget contract parses radial gradient fill and shadow properties")
    func buttonWidgetContract() throws {
        let canvas = try parseContractFixture()
        guard case .widget(_, _, .button(let buttonBox, let label, let buttonRadius, let style, let shadow, let primary, let destructive, let applyDestructive, _, let confirm)) = canvas.children[2],
              case .fill(let buttonFill) = style,
              case .gradient(let buttonType, _, _, _, _, _, _, _) = buttonFill
        else {
            Issue.record("Expected gradient button")
            return
        }
        #expect(label.spans.count == 2)
        #expect(buttonType == .radial)
        #expect(buttonBox.shadow == nil)
        #expect(shadow?.spread == 3)
        #expect(shadow?.offsetY == 5)
        let actionlessButton = CampaignCanvasChild.widget(
            id: "actionless",
            rect: CampaignCanvasRect(x: 0, y: 0, width: 10, height: 10),
            widget: .button(
                box: buttonBox, label: label, cornerRadius: buttonRadius, style: style, shadow: shadow,
                isPrimary: primary, isDestructive: destructive,
                applyDestructiveStyling: applyDestructive, actions: [], confirm: confirm
            )
        )
        #expect(!actionlessButton.isHitTestable)
    }

    @Test("progress bar widget contract parses sweep gradient and clamped animation duration")
    func progressWidgetContract() throws {
        let canvas = try parseContractFixture()
        guard case .widget(_, _, .progress(_, _, _, _, _, _, let indicator, let track, _, let animation)) = canvas.children[3],
              case .gradient(let progressType, _, _, _, _, let start, let end, let stops) = indicator
        else {
            Issue.record("Expected sweep progress")
            return
        }
        #expect(progressType == .sweep)
        #expect(stops.map(\.offset) == [0, 1])
        #expect(start == 30)
        #expect(end == 240)
        #expect(track == .none)
        #expect(animation.durationMs == 5_000)
    }

    @Test("container widget contract parses image fill and shadow spread")
    func containerWidgetContract() throws {
        let canvas = try parseContractFixture()
        guard case .widget(_, _, .container(let fill, _, _, let shadow)) = canvas.children[6], case .image = fill else {
            Issue.record("Expected image-filled container")
            return
        }
        #expect(shadow?.spread == 5)
    }


    @Test("text spans accept direct and style level typography overrides")
    func textSpanOverrides() throws {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 100,
            "canvasHeight": 100,
            "children": [[
                "kind": "widget",
                "id": "text",
                "rect": ["x": 0, "y": 0, "width": 1, "height": 1],
                "widget": [
                    "type": "digia/text",
                    "props": [
                        "spans": [[
                            "text": "Styled",
                            "fontWeight": "heavy",
                            "textColor": "#112233",
                            "style": [
                                "fontSize": 18,
                                "lineHeight": 24,
                                "letterSpacing": 0.5,
                                "decoration": "line-through",
                                "decorationThickness": 99,
                            ],
                        ]],
                    ],
                ],
            ]],
        ])

        guard case .widget(_, _, .text(_, let block, _)) = canvas.children.first else {
            Issue.record("Expected text widget")
            return
        }
        let span = try #require(block.spans.first)
        #expect(span.typography?.fontWeight == 900)
        #expect(span.typography?.fontSize == 18)
        #expect(span.typography?.lineHeight == 24)
        #expect(span.typography?.letterSpacing == 0.5)
        #expect(span.color?.lightHex == "#FF112233")
        #expect(span.decoration == .lineThrough)
        #expect(span.decorationThickness == 8)
    }

    @Test("runtime theme updates drive light and dark mode state")
    @MainActor
    func runtimeThemeModeUpdates() {
        let theme = CampaignCanvasTheme.shared
        defer { theme.update(.auto) }

        theme.update(.auto)
        #expect(!theme.isDark(.light))
        #expect(theme.isDark(.dark))
        theme.update(.light)
        #expect(!theme.isDark(.dark))
        theme.update(.dark)
        #expect(theme.isDark(.light))
    }

    @Test("runtime theme selects correct light, dark, and shared media variants")
    @MainActor
    func runtimeThemeMediaURLSelection() {
        let theme = CampaignCanvasTheme.shared
        let darkMedia = CampaignCanvasMediaSource(url: "light.png", darkUrl: "dark.png", placeholder: nil)
        let sharedMedia = CampaignCanvasMediaSource(url: "shared.png", darkUrl: nil, placeholder: nil)

        #expect(theme.mediaURL(darkMedia, isDark: false) == "light.png")
        #expect(theme.mediaURL(darkMedia, isDark: true) == "dark.png")
        #expect(theme.mediaURL(sharedMedia, isDark: true) == "shared.png")
    }

    @Test("rounded shape renders true circular arcs and scales oversized radii like Flutter/CSS")
    func roundedShapeCircularAndScaling() throws {
        let square = CGRect(x: 0, y: 0, width: 90, height: 90)
        let exactCircleShape = CampaignCanvasRoundedShape(
            radius: CampaignCanvasCornerRadius(topLeft: 45, topRight: 45, bottomRight: 45, bottomLeft: 45)
        )
        let oversizedCircleShape = CampaignCanvasRoundedShape(
            radius: CampaignCanvasCornerRadius(topLeft: 999, topRight: 999, bottomRight: 999, bottomLeft: 999)
        )
        let p1 = exactCircleShape.path(in: square)
        let p2 = oversizedCircleShape.path(in: square)

        // Both exact 45 (size / 2) and oversized 999 produce identical circular paths
        #expect(p1.description == p2.description)
        #expect(!p1.isEmpty)

        // Capsule / stadium test: 100x40 with radius 50 scales to radius 20
        let rect = CGRect(x: 0, y: 0, width: 100, height: 40)
        let capsuleShape = CampaignCanvasRoundedShape(
            radius: CampaignCanvasCornerRadius(topLeft: 50, topRight: 50, bottomRight: 50, bottomLeft: 50)
        )
        let capsulePath = capsuleShape.path(in: rect)
        #expect(!capsulePath.isEmpty)
    }

    private func parseContractFixture() throws -> CampaignCanvas {
        let data = Data(
            """
            {
              "version":2, "canvasWidth":360, "canvasHeight":640,
              "background":{"type":"gradient","gradientType":"linear","angleDeg":45,"stops":[{"color":"#fff","offset":1},{"color":"#000","offset":0}]},
              "children":[
                {"kind":"widget","id":"text","rect":{"x":0,"y":0,"width":1,"height":0.1},"widget":{"type":"digia/text","containerProps":{"fill":{"type":"solid","color":{"value":"#123"}},"padding":{"value":{"top":1,"right":2,"bottom":3,"left":4}},"cornerRadius":{"topLeft":24,"topRight":20,"bottomRight":8,"bottomLeft":4},"border":{"color":"#000","width":{"value":2}},"shadow":{"color":"#33000000","blur":10,"spread":4,"offsetX":1,"offsetY":2}},"props":{"shadow":{"color":"#44010203","blur":8,"spread":2,"offsetX":3,"offsetY":5},"spans":[{"text":"Base","typography":{"fontSize":18,"fontWeight":"bold"},"color":"#111","onClick":{"steps":[{"type":"dismiss"}]}},{"text":" rich","typography":{"fontSize":20},"color":"#222"}]}}},
                {"kind":"widget","id":"image","rect":{"x":0,"y":0.1,"width":1,"height":0.1},"widget":{"type":"digia/image","props":{"source":{"url":"light.png","darkUrl":"dark.png"},"positionX":2,"positionY":-1,"scale":9,"tintColor":"#abc"}}},
                {"kind":"widget","id":"button","rect":{"x":0,"y":0.2,"width":1,"height":0.1},"widget":{"type":"digia/button","containerProps":{"shadow":{"color":"#FF000000","spread":99}},"props":{"label":{"spans":[{"text":"Buy","color":"#111"},{"text":" now","italic":true,"color":"#222"}]},"style":{"variant":"fill","fill":{"type":"gradient","gradientType":"radial","centerX":0.25,"centerY":0.75,"radius":2,"stops":[{"color":"#f00","offset":0},{"color":"#00f","offset":1}]}},"shadow":{"color":"#44000000","blur":12,"spread":3,"offsetX":2,"offsetY":5},"cornerRadius":{"topLeft":9,"topRight":8,"bottomRight":7,"bottomLeft":6},"onClick":{"steps":[{"type":"dismiss"}]}}}},
                {"kind":"widget","id":"progress","rect":{"x":0,"y":0.3,"width":1,"height":0.1},"widget":{"type":"digia/linearProgressBar","props":{"indicator":{"type":"gradient","gradientType":"sweep","startAngleDeg":30,"endAngleDeg":240,"stops":[{"color":"#fff","offset":1},{"color":"#000","offset":0}]},"track":{"type":"image","source":{"url":"ignored"}},"animateOnAppear":{"enabled":true,"durationMs":9000}}}},
                {"kind":"widget","id":"lottie","rect":{"x":0,"y":0.4,"width":1,"height":0.1},"widget":{"type":"digia/lottie","props":{"source":{"url":"a.json","darkUrl":"b.json"}}}},
                {"kind":"widget","id":"video","rect":{"x":0,"y":0.5,"width":1,"height":0.1},"widget":{"type":"digia/videoPlayer","props":{"source":{"url":"a.mp4","darkUrl":"b.mp4"},"showControls":false}}},
                {"kind":"widget","id":"container","rect":{"x":0,"y":0.6,"width":1,"height":0.1},"widget":{"type":"digia/canvasContainer","containerProps":{"padding":99},"props":{"fill":{"type":"image","source":{"url":"card.png","darkUrl":"card-dark.png"},"positionX":0.2,"positionY":0.8,"scale":1.5},"shadow":{"color":"#80000000","blur":12,"spread":5,"offsetX":2,"offsetY":4}}}},
                {"kind":"widget","id":"divider","rect":{"x":0,"y":0.7,"width":1,"height":0.1},"widget":{"type":"digia/styledHorizontalDivider","props":{"type":"vertical","style":"dashed","strokeCap":"round","inset":3,"dashPattern":"9, 2","color":"#123456"}}},
                {"kind":"widget","id":"unknown","rect":{"x":0,"y":0.8,"width":1,"height":0.1},"widget":{"type":"digia/not-supported","props":{}}}
              ]
            }
            """.utf8
        )
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try CampaignCanvasParser().parse(json)
    }
}

