import Foundation
import Testing
@testable import DigiaEngage

/// The two canvas strips — carousel and story — parse as *widgets* inside an
/// ordinary inline canvas, which is why neither has a campaign type of its own.
@Suite("Campaign Canvas strips")
struct CampaignCanvasStripTests {
    private func nestedCanvas(version: Int = 2, height: Int = 180) -> [String: Any] {
        [
            "version": version,
            "canvasWidth": 360,
            "canvasHeight": height,
            "background": ["type": "solid", "color": ["value": "#FFFFFFFF"]],
            "children": [],
        ]
    }

    private func canvas(with widget: [String: Any]) -> [String: Any] {
        [
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 224,
            "background": ["type": "solid", "color": ["value": "#00000000"]],
            "children": [[
                "kind": "widget",
                "id": "child",
                "rect": ["x": 0, "y": 0.05, "width": 1, "height": 0.9],
                "widget": widget,
            ]],
        ]
    }

    private func carouselWidget(slides: [[String: Any]]? = nil) -> [String: Any] {
        [
            "id": "w",
            "type": "digia/canvasCarousel",
            "props": [
                "slides": slides ?? [nestedCanvas(), nestedCanvas()],
                "viewportFraction": 0.88,
                "itemSpacing": 12,
                "autoPlay": false,
                "infiniteScroll": false,
                "cornerRadius": 12,
                "showIndicator": true,
                "indicatorEffect": "worm",
            ],
        ]
    }

    private func storyWidget(
        pages: [[String: Any]]? = nil,
        chrome: [String: Any]? = nil,
        includeChrome: Bool = true,
        showRail: Bool = true
    ) -> [String: Any] {
        var props: [String: Any] = [
            "pages": pages ?? [[
                "thumbnailType": "image",
                "thumbnailUrl": "https://x/a.jpg",
                "thumbnailFit": "cover",
                "pageFit": "contain",
                "durationSeconds": 0,
                "canvas": nestedCanvas(height: 732),
            ]],
            "showRail": showRail,
            "cardAspectRatio": 0.72,
            "cardSpacing": 12,
            "cardCornerRadius": 12,
            "defaultDurationSeconds": 7,
            "restartOnCompleted": true,
            "startMuted": false,
        ]
        if includeChrome { props["chromeCanvas"] = chrome ?? nestedCanvas(height: 732) }
        return ["id": "w", "type": "digia/canvasStory", "props": props]
    }

    private func firstWidget(_ parsed: CampaignCanvas) -> CampaignCanvasWidget? {
        parsed.children.compactMap { child -> CampaignCanvasWidget? in
            guard case .widget(_, _, let widget) = child else { return nil }
            return widget
        }.first
    }

    @Test("carousel parses its nested slides and playback")
    func carousel() throws {
        let parsed = try CampaignCanvasParser().parse(canvas(with: carouselWidget()))
        guard case .carousel(_, let slides, let fraction, _, let autoPlay, _, _, _, _, _, _, _, _, _, _, let effect) =
            try #require(firstWidget(parsed)) else { return }
        #expect(slides.count == 2)
        #expect(slides.first?.width == 360)
        #expect(fraction == 0.88)
        #expect(autoPlay == false)
        #expect(effect == "worm")
    }

    @Test("carousel with an unreadable slide is dropped whole")
    func carouselDropsPartial() throws {
        // All-or-nothing: rendering the slides that parsed would give the
        // marketer a carousel quietly missing one.
        let parsed = try CampaignCanvasParser().parse(
            canvas(with: carouselWidget(slides: [nestedCanvas(), nestedCanvas(version: 99)]))
        )
        #expect(firstWidget(parsed) == nil)
    }

    @Test("carousel with no slides is dropped")
    func carouselDropsEmpty() throws {
        let parsed = try CampaignCanvasParser().parse(canvas(with: carouselWidget(slides: [])))
        #expect(firstWidget(parsed) == nil)
    }

    @Test("story parses its pages, chrome and viewer settings")
    func story() throws {
        let parsed = try CampaignCanvasParser().parse(canvas(with: storyWidget()))
        guard case .story(_, let pages, _, _, _, _, _, let restart, let startMuted, _) =
            try #require(firstWidget(parsed)) else { return }
        #expect(pages.count == 1)
        #expect(pages[0].thumbnailUrl == "https://x/a.jpg")
        #expect(pages[0].pageFit == "contain")
        // No duration of its own, so it inherits `defaultDurationSeconds`.
        #expect(pages[0].duration == 7)
        #expect(restart == true)
        #expect(startMuted == false)
    }

    @Test("story with no chrome is dropped, since it would open with no way out")
    func storyNeedsChrome() throws {
        let parsed = try CampaignCanvasParser().parse(
            canvas(with: storyWidget(includeChrome: false))
        )
        #expect(firstWidget(parsed) == nil)
    }

    @Test("story with an unreadable page is dropped whole")
    func storyDropsPartial() throws {
        let parsed = try CampaignCanvasParser().parse(
            canvas(with: storyWidget(pages: [[
                "thumbnailUrl": "https://x/a.jpg",
                "canvas": nestedCanvas(version: 99),
            ]]))
        )
        #expect(firstWidget(parsed) == nil)
    }

    @Test("a hidden rail still carries its stories")
    func hiddenRail() throws {
        let parsed = try CampaignCanvasParser().parse(canvas(with: storyWidget(showRail: false)))
        guard case .story(_, let pages, _, _, _, let showRail, _, _, _, _) =
            try #require(firstWidget(parsed)) else { return }
        // Nothing renders, but the widget has to stay: it holds the stories and
        // the chrome, and an `Action.showStory` elsewhere opens them.
        #expect(showRail == false)
        #expect(pages.count == 1)
    }

    @Test("show story action carries a clamped zero-based index")
    func showStoryAction() {
        let actions = EngageActionParser().parse([
            "steps": [["type": "Action.showStory", "data": ["index": 2]]],
        ])
        #expect(actions == [.showStory(2)])

        let negative = EngageActionParser().parse([
            "steps": [["type": "Action.showStory", "data": ["index": -4]]],
        ])
        #expect(negative == [.showStory(0)])
    }
}
