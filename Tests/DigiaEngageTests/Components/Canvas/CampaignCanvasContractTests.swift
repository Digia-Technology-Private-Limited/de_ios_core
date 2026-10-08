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

    @Test(
        "all 14 supported widgets have registered renderers in CampaignCanvasRendererRegistry",
        arguments: allSampleWidgets
    )
    @MainActor
    func allFourteenSupportedWidgetsHaveRegisteredRenderers(widget: CampaignCanvasWidget) {
        #expect(CampaignCanvasRendererRegistry.hasRenderer(for: widget))
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

    private static func sampleTextBlock() -> CampaignCanvasTextBlock {
        CampaignCanvasTextBlock(
            horizontalAlign: .left,
            textAlign: .left,
            verticalAlign: .top,
            maxLines: 0,
            overflow: "none",
            sizingMode: "auto",
            spans: []
        )
    }

    private static func sampleMediaSource(_ url: String = "https://example.com/media") -> CampaignCanvasMediaSource {
        CampaignCanvasMediaSource(url: url, darkUrl: nil, placeholder: nil)
    }

    private static let allSampleWidgets: [CampaignCanvasWidget] = [
        .text(box: .none, block: sampleTextBlock(), shadow: nil),
        .image(
            box: .none,
            source: sampleMediaSource("https://example.com/img.png"),
            fit: "cover",
            positionX: 0.5,
            positionY: 0.5,
            scale: 1,
            tintColor: nil
        ),
        .button(
            box: .none,
            label: sampleTextBlock(),
            cornerRadius: .zero,
            style: .fill(fill: .none),
            shadow: nil,
            isPrimary: true,
            isDestructive: false,
            applyDestructiveStyling: false,
            actions: [],
            confirm: CampaignCanvasConfirmDialog()
        ),
        .progress(
            box: .none,
            valueMode: .percent,
            percent: "50",
            rangeStart: "0",
            rangeCurrent: "50",
            rangeEnd: "100",
            indicator: .none,
            track: .none,
            cornerRadius: .zero,
            animateOnAppear: CampaignCanvasAppearAnimation(enabled: false, durationMs: 0)
        ),
        .lottie(
            box: .none,
            source: sampleMediaSource("https://example.com/anim.json"),
            autoplay: true,
            loop: true,
            fit: "contain"
        ),
        .video(
            box: .none,
            source: sampleMediaSource("https://example.com/video.mp4"),
            autoplay: true,
            loop: true,
            muted: true,
            showControls: false,
            fit: "cover"
        ),
        .container(
            fill: .none,
            cornerRadius: .zero,
            border: nil,
            shadow: nil
        ),
        .divider(
            box: .none,
            axis: .horizontal,
            pattern: .solid,
            strokeCap: .butt,
            inset: 0,
            dashPattern: [],
            color: CampaignColor.literal("#000000")
        ),
        .carousel(
            box: .none,
            slides: [],
            viewportFraction: 0.8,
            itemSpacing: 8,
            autoPlay: false,
            autoPlayInterval: 3,
            animationDuration: 0.3,
            infiniteScroll: false,
            cornerRadius: 0,
            showIndicator: true,
            dotWidth: 8,
            dotHeight: 8,
            dotSpacing: 4,
            dotColor: nil,
            activeDotColor: nil,
            indicatorEffect: "scale"
        ),
        .story(
            box: .none,
            pages: [],
            cardAspectRatio: 9 / 16,
            cardCornerRadius: 8,
            cardSpacing: 8,
            showRail: true,
            thumbnailVideoPlayback: .sequential,
            restartOnCompleted: false,
            startMuted: true,
            chrome: CampaignCanvas(version: 2, width: 100, height: 100, background: .none, children: [])
        ),
        .storyProgress(
            box: .none,
            activeColor: nil,
            trackColor: nil,
            barHeight: 2,
            cornerRadius: 1,
            gap: 4
        ),
        .storyClose(
            box: .none,
            visible: true,
            iconColor: nil,
            backgroundColor: nil
        ),
        .storyMute(
            box: .none,
            visible: true,
            iconColor: nil,
            backgroundColor: nil
        ),
        .timer(
            box: .none,
            preset: "default",
            separator: ":",
            units: [:],
            labels: [:],
            labelSpans: [:],
            textWidgets: [:],
            style: CampaignCanvasTimerUnitStyle(
                digitTextStyle: nil,
                digitTypography: nil,
                digitColor: nil,
                labelTypography: nil,
                labelColor: nil,
                boxFill: .none,
                cornerRadius: .zero
            ),
            unitOverrides: [:],
            layout: CampaignCanvasTimerLayout()
        )
    ]
}

