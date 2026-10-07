import Foundation
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

@MainActor
@Suite("Canvas story renderer", .serialized, .tags(.canvas, .component))
struct CanvasStoryRendererTests {

    // MARK: - 1. Story Rail Parser & Properties Preservation

    @Test("story rail parser preserves pages, playback mode, and chrome configuration")
    func storyRailParserPreservesProperties() throws {
        let widget = try parsedStoryWidget([
            "cardAspectRatio": 0.75,
            "cardCornerRadius": 16,
            "cardSpacing": 14,
            "showRail": true,
            "thumbnailVideoPlayback": "sequential",
            "restartOnCompleted": true,
            "startMuted": false,
            "defaultDurationSeconds": 6.5
        ], pages: [
            makeStoryPageJSON(url: "https://example.com/story1.jpg", durationSeconds: 8.0),
            makeStoryPageJSON(url: "https://example.com/story2.mp4", isVideo: true, durationSeconds: 0.0) // 0 inherits defaultDurationSeconds
        ])

        guard case .story(
            let box, let pages, let cardAspectRatio, let cardCornerRadius, let cardSpacing,
            let showRail, let thumbnailVideoPlayback, let restartOnCompleted, let startMuted,
            let chrome
        ) = widget else {
            Issue.record("Expected .story widget")
            return
        }

        #expect(box == .none)
        #expect(pages.count == 2)
        #expect(pages[0].thumbnailUrl == "https://example.com/story1.jpg")
        #expect(pages[0].thumbnailIsVideo == false)
        #expect(pages[0].duration == 8.0)

        #expect(pages[1].thumbnailUrl == "https://example.com/story2.mp4")
        #expect(pages[1].thumbnailIsVideo == true)
        #expect(pages[1].duration == 6.5) // Inherited fallback from defaultDurationSeconds

        #expect(cardAspectRatio == 0.75)
        #expect(cardCornerRadius == 16)
        #expect(cardSpacing == 14)
        #expect(showRail == true)
        #expect(thumbnailVideoPlayback == .sequential)
        #expect(restartOnCompleted == true)
        #expect(startMuted == false)
        #expect(chrome.width == 360)
    }

    @Test("story rail parser applies defaults and clamps invalid properties")
    func storyRailParserClampingAndDefaults() throws {
        let widget = try parsedStoryWidget([
            "cardAspectRatio": -0.5, // <= 0 -> fallback 0.72
            "thumbnailVideoPlayback": "unknown_mode", // -> .simultaneous
            "defaultDurationSeconds": -2.0 // <= 0 -> max(0.1, ...) fallback 5.0
        ])

        guard case .story(
            _, let pages, let ratio, _, _,
            let showRail, let playbackMode, let restart, let muted, _
        ) = widget else {
            Issue.record("Expected .story widget")
            return
        }

        #expect(ratio == 0.72)
        #expect(playbackMode == .simultaneous)
        #expect(showRail == true) // Default
        #expect(restart == false) // Default
        #expect(muted == true) // Default
        #expect(pages.first?.duration == 5.0) // Fallback default duration
    }

    // MARK: - 2. Story Chrome Widgets Parser

    @Test("storyProgress parser preserves track, active color, bar height, and gap")
    func storyProgressParser() throws {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 40,
            "children": [
                [
                    "kind": "widget",
                    "id": "progress-widget",
                    "rect": ["x": 0.05, "y": 0.2, "width": 0.9, "height": 0.6],
                    "widget": [
                        "type": "digia/storyProgress",
                        "props": [
                            "activeColor": "#FFFFFFFF",
                            "trackColor": "#55FFFFFF",
                            "barHeight": 4,
                            "cornerRadius": 2,
                            "gap": 6
                        ]
                    ]
                ]
            ]
        ])

        guard case .widget(_, _, let widget) = canvas.children.first else {
            Issue.record("Expected widget")
            return
        }

        guard case .storyProgress(let box, let active, let track, let height, let radius, let gap) = widget else {
            Issue.record("Expected .storyProgress widget")
            return
        }

        #expect(box == .none)
        #expect(active == .literal("#FFFFFFFF"))
        #expect(track == .literal("#55FFFFFF"))
        #expect(height == 4)
        #expect(radius == 2)
        #expect(gap == 6)
    }

    @Test("storyClose and storyMute parsers preserve visibility and color styling")
    func storyCloseAndMuteParsers() throws {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 80,
            "children": [
                [
                    "kind": "widget",
                    "id": "close-btn",
                    "rect": ["x": 0.85, "y": 0.2, "width": 0.1, "height": 0.6],
                    "widget": [
                        "type": "digia/storyClose",
                        "props": [
                            "visible": true,
                            "iconColor": "#FFFFFFFF",
                            "backgroundColor": "#88000000"
                        ]
                    ]
                ],
                [
                    "kind": "widget",
                    "id": "mute-btn",
                    "rect": ["x": 0.72, "y": 0.2, "width": 0.1, "height": 0.6],
                    "widget": [
                        "type": "digia/storyMute",
                        "props": [
                            "visible": false,
                            "iconColor": "#FF000000",
                            "backgroundColor": "#FFFFFFFF"
                        ]
                    ]
                ]
            ]
        ])

        #expect(canvas.children.count == 2)

        guard case .widget(_, _, let closeWidget) = canvas.children[0],
              case .storyClose(_, let closeVisible, let closeIcon, let closeBg) = closeWidget else {
            Issue.record("Expected .storyClose widget")
            return
        }
        #expect(closeVisible == true)
        #expect(closeIcon == .literal("#FFFFFFFF"))
        #expect(closeBg == .literal("#88000000"))

        guard case .widget(_, _, let muteWidget) = canvas.children[1],
              case .storyMute(_, let muteVisible, let muteIcon, let muteBg) = muteWidget else {
            Issue.record("Expected .storyMute widget")
            return
        }
        #expect(muteVisible == false)
        #expect(muteIcon == .literal("#FF000000"))
        #expect(muteBg == .literal("#FFFFFFFF"))
    }

    // MARK: - 3. Progress Segment Fraction & Arithmetic

    @Test("story progress segment fraction calculates proper fill widths")
    func storyProgressSegmentFraction() {
        // Scenario 1: Middle story (active = 1 of 4), half elapsed (progress = 0.5)
        #expect(CanvasStoryProgressRenderer.fraction(for: 0, active: 1, elapsed: 0.5) == 1.0)
        #expect(CanvasStoryProgressRenderer.fraction(for: 1, active: 1, elapsed: 0.5) == 0.5)
        #expect(CanvasStoryProgressRenderer.fraction(for: 2, active: 1, elapsed: 0.5) == 0.0)
        #expect(CanvasStoryProgressRenderer.fraction(for: 3, active: 1, elapsed: 0.5) == 0.0)

        // Scenario 2: First story (active = 0 of 3), clamped negative progress (-0.2 -> 0.0)
        #expect(CanvasStoryProgressRenderer.fraction(for: 0, active: 0, elapsed: -0.2) == 0.0)
        #expect(CanvasStoryProgressRenderer.fraction(for: 1, active: 0, elapsed: -0.2) == 0.0)
        #expect(CanvasStoryProgressRenderer.fraction(for: 2, active: 0, elapsed: -0.2) == 0.0)

        // Scenario 3: Last story (active = 2 of 3), clamped over-unity progress (1.4 -> 1.0)
        #expect(CanvasStoryProgressRenderer.fraction(for: 0, active: 2, elapsed: 1.4) == 1.0)
        #expect(CanvasStoryProgressRenderer.fraction(for: 1, active: 2, elapsed: 1.4) == 1.0)
        #expect(CanvasStoryProgressRenderer.fraction(for: 2, active: 2, elapsed: 1.4) == 1.0)
    }

    @Test("story progress increment and hold to pause rules")
    func storyProgressIncrementAndHoldToPause() {
        let interval: TimeInterval = 1.0 / 30.0
        let duration: Double = 5.0

        // Normal playback increments progress proportionally
        let normalIncrement = CanvasStoryViewer.progressIncrement(
            interval: interval, duration: duration, isPaused: false
        )
        let expectedIncrement = CGFloat(interval / duration)
        #expect(abs(normalIncrement - expectedIncrement) < 0.0001)

        // Hold-to-pause stops accumulation completely
        let pausedIncrement = CanvasStoryViewer.progressIncrement(
            interval: interval, duration: duration, isPaused: true
        )
        #expect(pausedIncrement == 0.0)

        // Safe division against zero or negative authored duration
        let zeroDurationIncrement = CanvasStoryViewer.progressIncrement(
            interval: interval, duration: 0.0, isPaused: false
        )
        #expect(zeroDurationIncrement == CGFloat(interval / 0.1))
    }

    // MARK: - 4. Story Chrome Symbols & Mute

    @Test("story chrome buttons verify symbols for close and mute states")
    func storyChromeButtonSymbols() {
        // Close button is always "xmark"
        #expect(CanvasStoryChromeButton.symbol(for: .close, viewer: nil) == "xmark")
        #expect(CanvasStoryChromeButton.symbol(for: .close, viewer: CanvasStoryViewerState(muted: false)) == "xmark")

        // Mute button reflects viewer state or defaults to muted
        #expect(CanvasStoryChromeButton.symbol(for: .mute, viewer: nil) == "speaker.slash.fill")
        #expect(CanvasStoryChromeButton.symbol(for: .mute, viewer: CanvasStoryViewerState(muted: true)) == "speaker.slash.fill")
        #expect(CanvasStoryChromeButton.symbol(for: .mute, viewer: CanvasStoryViewerState(muted: false)) == "speaker.wave.2.fill")
    }

    // MARK: - 5. Fit & Item Mapping Oracle

    @Test("story fit and content mode conversion oracle")
    func storyFitAndContentModeMappingOracle() {
        #expect(canvasContentMode("contain") == .fit)
        #expect(canvasContentMode("cover") == .fill)
        #expect(canvasContentMode("anything") == .fill)

        #expect(storyFit(.fit) == .contain)
        #expect(storyFit(.fill) == .cover)
    }

    @Test("canvasStoryItem mapping transforms CampaignCanvasStoryPage into StoryItemConfig")
    func canvasStoryItemMappingOracle() {
        let mockCanvas = try! CampaignCanvasParser().parse(makeNestedCanvasJSON(height: 700))
        let page = CampaignCanvasStoryPage(
            thumbnailIsVideo: true,
            thumbnailUrl: "https://media.example.com/video.mp4",
            thumbnailFit: "contain",
            pageFit: "fill",
            thumbnailPlayback: CampaignCanvasStoryThumbnailPlayback(
                startTime: 1.5,
                fixedDuration: true,
                duration: 4.0
            ),
            duration: 8.5,
            canvas: mockCanvas
        )

        let item = canvasStoryItem(page)
        #expect(item.type == .video)
        #expect(item.url == "https://media.example.com/video.mp4")
        #expect(item.duration == 8500) // 8.5s * 1000
        #expect(item.thumbnailPlayback.startTimeMs == 1500) // 1.5s * 1000
        #expect(item.thumbnailPlayback.durationMode == .fixed)
        #expect(item.thumbnailPlayback.durationMs == 4000) // 4.0s * 1000
        #expect(item.boxFit == .fill)
        #expect(item.thumbnailBoxFit == .contain)
    }

    @Test("story rail card dimensions derives card width from authored ratio")
    func storyRailCardDimension() {
        let railHeight: CGFloat = 160
        let cardAspectRatio: CGFloat = 0.72
        let cardWidth = CanvasStoryRailRenderer.cardWidth(railHeight: railHeight, cardAspectRatio: cardAspectRatio)
        #expect(abs(cardWidth - 115.2) < 0.001)

        let squareAspectRatio: CGFloat = 1.0
        #expect(abs(CanvasStoryRailRenderer.cardWidth(railHeight: railHeight, cardAspectRatio: squareAspectRatio) - 160.0) < 0.001)
    }

    // MARK: - 6. Visual Golden Tests

    @Test("story progress and chrome buttons render segmented strip and interactive controls")
    func storyProgressAndChromeVisualGolden() throws {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 80,
            "background": ["type": "solid", "color": ["value": "#FF1E293B"]],
            "children": [
                [
                    "kind": "widget",
                    "id": "chrome-progress",
                    "rect": ["x": 0.04, "y": 0.16, "width": 0.92, "height": 0.1],
                    "widget": [
                        "type": "digia/storyProgress",
                        "props": [
                            "activeColor": "#FFFFFFFF",
                            "trackColor": "#55FFFFFF",
                            "barHeight": 4,
                            "cornerRadius": 2,
                            "gap": 6
                        ]
                    ]
                ],
                [
                    "kind": "widget",
                    "id": "chrome-mute",
                    "rect": ["x": 0.74, "y": 0.38, "width": 0.1, "height": 0.45],
                    "widget": [
                        "type": "digia/storyMute",
                        "props": [
                            "visible": true,
                            "iconColor": "#FFFFFFFF",
                            "backgroundColor": "#55000000"
                        ]
                    ]
                ],
                [
                    "kind": "widget",
                    "id": "chrome-close",
                    "rect": ["x": 0.86, "y": 0.38, "width": 0.1, "height": 0.45],
                    "widget": [
                        "type": "digia/storyClose",
                        "props": [
                            "visible": true,
                            "iconColor": "#FFFFFFFF",
                            "backgroundColor": "#55000000"
                        ]
                    ]
                ]
            ]
        ])

        // Mount with active story index 1 of 3, 65% progressed, unmuted (speaker wave icon)
        let viewerState = CanvasStoryViewerState(
            index: 1,
            pageCount: 3,
            progress: 0.65,
            muted: false
        )

        let window = mount(canvas: canvas, storyViewerState: viewerState)
        defer { unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.1)

        let image = ComponentTestHost.renderImage(of: window.rootViewController!.view)
        assertVisualGolden(matching: image, precision: 0.999, perceptualPrecision: 0.98)
    }

    @Test("story progress and chrome render muted resting state")
    func storyProgressAndChromeMutedVisualGolden() throws {
        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 80,
            "background": ["type": "solid", "color": ["value": "#FF0F172A"]],
            "children": [
                [
                    "kind": "widget",
                    "id": "chrome-progress-dark",
                    "rect": ["x": 0.04, "y": 0.16, "width": 0.92, "height": 0.1],
                    "widget": [
                        "type": "digia/storyProgress",
                        "props": [
                            "activeColor": "#FF38BDF8",
                            "trackColor": "#3338BDF8",
                            "barHeight": 4,
                            "cornerRadius": 2,
                            "gap": 4
                        ]
                    ]
                ],
                [
                    "kind": "widget",
                    "id": "chrome-mute-dark",
                    "rect": ["x": 0.74, "y": 0.38, "width": 0.1, "height": 0.45],
                    "widget": [
                        "type": "digia/storyMute",
                        "props": [
                            "visible": true,
                            "iconColor": "#FFFFFFFF",
                            "backgroundColor": "#66000000"
                        ]
                    ]
                ],
                [
                    "kind": "widget",
                    "id": "chrome-close-dark",
                    "rect": ["x": 0.86, "y": 0.38, "width": 0.1, "height": 0.45],
                    "widget": [
                        "type": "digia/storyClose",
                        "props": [
                            "visible": true,
                            "iconColor": "#FFFFFFFF",
                            "backgroundColor": "#66000000"
                        ]
                    ]
                ]
            ]
        ])

        // Mount with active story index 0 of 4, 30% progressed, muted (speaker slash icon)
        let viewerState = CanvasStoryViewerState(
            index: 0,
            pageCount: 4,
            progress: 0.30,
            muted: true
        )

        let window = mount(canvas: canvas, storyViewerState: viewerState, isDark: true)
        defer { unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.1)

        let image = ComponentTestHost.renderImage(of: window.rootViewController!.view)
        assertVisualGolden(matching: image, precision: 0.999, perceptualPrecision: 0.98)
    }

    @Test("story rail renderer renders horizontal card rail with aspect ratio and rounded corners")
    func storyRailVisualGolden() throws {
        let strawberryUrl = try prewarmedAssetURL(named: "strawberry.jpg")
        let whatsappUrl = try prewarmedAssetURL(named: "cloudinary-whatsapp.jpg")

        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 140,
            "background": ["type": "solid", "color": ["value": "#FFF1F5F9"]],
            "children": [
                [
                    "kind": "widget",
                    "id": "story-rail-widget",
                    "rect": ["x": 0.0, "y": 0.05, "width": 1.0, "height": 0.9],
                    "widget": [
                        "type": "digia/canvasStory",
                        "props": [
                            "pages": [
                                makeStoryPageJSON(url: strawberryUrl, durationSeconds: 5.0),
                                makeStoryPageJSON(url: whatsappUrl, durationSeconds: 5.0),
                                makeStoryPageJSON(url: strawberryUrl, durationSeconds: 5.0)
                            ],
                            "cardAspectRatio": 0.72,
                            "cardCornerRadius": 12,
                            "cardSpacing": 10,
                            "showRail": true,
                            "chromeCanvas": makeNestedCanvasJSON(height: 700)
                        ]
                    ]
                ]
            ]
        ])

        let window = mount(canvas: canvas)
        defer { unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.5)
        window.rootViewController?.overrideUserInterfaceStyle = .dark
        ComponentTestHost.drainRunLoop(for: 0.4)
        window.rootViewController?.overrideUserInterfaceStyle = .light
        ComponentTestHost.drainRunLoop(for: 0.5)
        window.layoutIfNeeded()

        let image = ComponentTestHost.renderImage(of: window.rootViewController!.view)
        assertVisualGolden(matching: image, precision: 0.999, perceptualPrecision: 0.98)
    }

    @Test("story viewer full screen renders background media, overlay page canvas, and top chrome controls")
    func storyViewerFullScreenVisualGolden() throws {
        let strawberryUrl = try prewarmedAssetURL(named: "strawberry.jpg")
        let whatsappUrl = try prewarmedAssetURL(named: "cloudinary-whatsapp.jpg")

        let pageCanvasJSON: [String: Any] = [
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 180,
            "background": ["type": "solid", "color": ["value": "#CC0F172A"]],
            "children": [
                [
                    "kind": "widget",
                    "id": "story-title",
                    "rect": ["x": 0.08, "y": 0.12, "width": 0.84, "height": 0.24],
                    "widget": [
                        "type": "digia/text",
                        "props": [
                            "spans": [
                                [
                                    "text": "Organic Strawberries",
                                    "color": "#FFFFFFFF",
                                    "typography": ["fontSize": 20, "fontWeight": 700]
                                ]
                            ]
                        ]
                    ]
                ],
                [
                    "kind": "widget",
                    "id": "story-desc",
                    "rect": ["x": 0.08, "y": 0.40, "width": 0.84, "height": 0.20],
                    "widget": [
                        "type": "digia/text",
                        "props": [
                            "spans": [
                                [
                                    "text": "Freshly harvested from organic farms.",
                                    "color": "#FF94A3B8",
                                    "typography": ["fontSize": 13, "fontWeight": 400]
                                ]
                            ]
                        ]
                    ]
                ],
                [
                    "kind": "widget",
                    "id": "story-cta",
                    "rect": ["x": 0.08, "y": 0.65, "width": 0.84, "height": 0.26],
                    "widget": [
                        "type": "digia/button",
                        "props": [
                            "label": [
                                "spans": [
                                    [
                                        "text": "Shop Fresh",
                                        "color": "#FFFFFFFF",
                                        "fontSize": 14,
                                        "fontWeight": 700
                                    ]
                                ]
                            ],
                            "style": [
                                "variant": "fill",
                                "fill": ["type": "solid", "color": "#FF4F46E5"]
                            ],
                            "cornerRadius": 10
                        ]
                    ]
                ]
            ]
        ]

        let chromeCanvasJSON: [String: Any] = [
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 50,
            "background": ["type": "solid", "color": ["value": "#00000000"]],
            "children": [
                [
                    "kind": "widget",
                    "id": "story-progress",
                    "rect": ["x": 0.04, "y": 0.10, "width": 0.92, "height": 0.16],
                    "widget": [
                        "type": "digia/storyProgress",
                        "props": [
                            "activeColor": "#FFFFFFFF",
                            "trackColor": "#66FFFFFF",
                            "barHeight": 4,
                            "gap": 4
                        ]
                    ]
                ],
                [
                    "kind": "widget",
                    "id": "story-mute-btn",
                    "rect": ["x": 0.74, "y": 0.30, "width": 0.10, "height": 0.65],
                    "widget": [
                        "type": "digia/storyMute",
                        "props": [
                            "visible": true,
                            "iconColor": "#FFFFFFFF",
                            "backgroundColor": "#66000000"
                        ]
                    ]
                ],
                [
                    "kind": "widget",
                    "id": "story-close-btn",
                    "rect": ["x": 0.86, "y": 0.30, "width": 0.10, "height": 0.65],
                    "widget": [
                        "type": "digia/storyClose",
                        "props": [
                            "visible": true,
                            "iconColor": "#FFFFFFFF",
                            "backgroundColor": "#66000000"
                        ]
                    ]
                ]
            ]
        ]

        let parsedWidget = try parsedStoryWidget([
            "showRail": true,
            "restartOnCompleted": false,
            "startMuted": true,
            "defaultDurationSeconds": 1000.0
        ], pages: [
            [
                "thumbnailType": "image",
                "thumbnailUrl": strawberryUrl,
                "thumbnailFit": "cover",
                "pageFit": "cover",
                "durationSeconds": 1000.0,
                "canvas": pageCanvasJSON
            ],
            [
                "thumbnailType": "image",
                "thumbnailUrl": whatsappUrl,
                "thumbnailFit": "cover",
                "pageFit": "cover",
                "durationSeconds": 1000.0,
                "canvas": makeNestedCanvasJSON(height: 180)
            ],
            [
                "thumbnailType": "image",
                "thumbnailUrl": strawberryUrl,
                "thumbnailFit": "cover",
                "pageFit": "cover",
                "durationSeconds": 1000.0,
                "canvas": makeNestedCanvasJSON(height: 180)
            ]
        ], chrome: chromeCanvasJSON)

        guard case .story(
            _, let pages, _, _, _, _, _, let restartOnCompleted, let startMuted, let chrome
        ) = parsedWidget else {
            Issue.record("Expected .story widget")
            return
        }

        let viewer = CanvasStoryViewer(
            pages: pages,
            chrome: chrome,
            initialIndex: 1,
            restartOnCompleted: restartOnCompleted,
            startMuted: startMuted,
            isDark: false,
            onAction: { _ in },
            onDismiss: {},
            showsOverlays: true,
            safeAreaInsets: EdgeInsets(top: 47, leading: 0, bottom: 34, trailing: 0)
        )

        let (window, _) = ComponentTestHost.mount(
            rootView: viewer,
            size: CGSize(width: 390, height: 844),
            backgroundColor: .black
        )
        defer { ComponentTestHost.unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.5)
        window.rootViewController?.overrideUserInterfaceStyle = .dark
        ComponentTestHost.drainRunLoop(for: 0.4)
        window.rootViewController?.overrideUserInterfaceStyle = .light
        ComponentTestHost.drainRunLoop(for: 0.5)
        window.layoutIfNeeded()

        let image = ComponentTestHost.renderImage(of: window.rootViewController!.view)
        assertVisualGolden(matching: image, precision: 0.999, perceptualPrecision: 0.98)
    }

    // MARK: - 7. Navigation & Interaction Mechanics

    @Test("story navigation outcome on CanvasStoryViewer models tap back, advance, and completion bounds")
    func storyStepNavigationOutcome() {
        let totalPages = 3

        // 1. Tapping left at page 0: delta -1 -> restarts current page
        #expect(CanvasStoryViewer.navigationOutcome(
            currentIndex: 0,
            delta: -1,
            pageCount: totalPages,
            restartOnCompleted: false
        ) == .restartCurrent)

        // 2. Tapping right at page 0 -> advances to page 1
        #expect(CanvasStoryViewer.navigationOutcome(
            currentIndex: 0,
            delta: 1,
            pageCount: totalPages,
            restartOnCompleted: false
        ) == .advance(to: 1))

        // 3. Tapping left at page 1 -> moves back to page 0
        #expect(CanvasStoryViewer.navigationOutcome(
            currentIndex: 1,
            delta: -1,
            pageCount: totalPages,
            restartOnCompleted: false
        ) == .advance(to: 0))

        // 4. Tapping right at page 1 -> advances to page 2 (last page)
        #expect(CanvasStoryViewer.navigationOutcome(
            currentIndex: 1,
            delta: 1,
            pageCount: totalPages,
            restartOnCompleted: false
        ) == .advance(to: 2))

        // 5. Tapping right at page 2 (last page, restartOnCompleted = false) -> completes and signals dismiss
        #expect(CanvasStoryViewer.navigationOutcome(
            currentIndex: 2,
            delta: 1,
            pageCount: totalPages,
            restartOnCompleted: false
        ) == .complete(loopToStart: false))

        // 6. Tapping right at page 2 (last page, restartOnCompleted = true) -> completes and loops to page 0
        #expect(CanvasStoryViewer.navigationOutcome(
            currentIndex: 2,
            delta: 1,
            pageCount: totalPages,
            restartOnCompleted: true
        ) == .complete(loopToStart: true))
    }

    @Test("story chrome button dispatches close and mute callbacks")
    func storyChromeButtonDispatchesCallbacks() {
        var closeCalled = false
        var muteCalled = false

        let closeCallback = CanvasStoryCallback(run: { closeCalled = true })
        let muteCallback = CanvasStoryCallback(run: { muteCalled = true })

        CanvasStoryChromeButton.performAction(kind: .close, close: closeCallback, toggleMute: muteCallback)
        #expect(closeCalled == true)
        #expect(muteCalled == false)

        closeCalled = false
        muteCalled = false
        CanvasStoryChromeButton.performAction(kind: .mute, close: closeCallback, toggleMute: muteCallback)
        #expect(closeCalled == false)
        #expect(muteCalled == true)

        // Nil-safety when callbacks are not provided
        CanvasStoryChromeButton.performAction(kind: .close, close: nil, toggleMute: nil)
        CanvasStoryChromeButton.performAction(kind: .mute, close: nil, toggleMute: nil)
    }

    @Test("story viewer distinguishes dismissal from completion analytics")
    func storyViewerAnalyticsAndDismissal() {
        // Scenario 1: Early dismissal on page 1 of 3
        let earlyDismiss = CanvasStoryViewer.dismissalInteraction(currentIndex: 1, pageCount: 3, completedReported: false)
        #expect(earlyDismiss == .storyPageDismissed(index: 1, total: 3))

        // Scenario 2: Close after already completed does not double-report
        let completedDismiss = CanvasStoryViewer.dismissalInteraction(currentIndex: 2, pageCount: 3, completedReported: true)
        #expect(completedDismiss == nil)

        // Scenario 3: First completion reports storyCompleted
        let completion = CanvasStoryViewer.completionInteraction(pageCount: 3, timeToCompleteMs: 4200, completedReported: false)
        #expect(completion == .storyCompleted(total: 3, timeToCompleteMs: 4200))

        // Scenario 4: Subsequent completion does not double-report
        let repeatedCompletion = CanvasStoryViewer.completionInteraction(pageCount: 3, timeToCompleteMs: 8400, completedReported: true)
        #expect(repeatedCompletion == nil)
    }

    // MARK: - Test Helpers

    private func prewarmedAssetURL(named fileName: String) throws -> String {
        try #require(ComponentTestHost.prewarmAssetImage(named: fileName))
        guard let workspaceUrl = FixtureLoader.workspaceURL() else {
            Issue.record("Workspace URL not available")
            throw DesignTokenError.invalid("Workspace URL not available")
        }
        let assetOrigin = workspaceUrl.appendingPathComponent("testkit/mock-server").absoluteString
        let cleanOrigin = assetOrigin.hasSuffix("/") ? String(assetOrigin.dropLast()) : assetOrigin
        return "\(cleanOrigin)/assets/\(fileName)"
    }

    private func parsedStoryWidget(
        _ props: [String: Any],
        pages: [[String: Any]]? = nil,
        chrome: [String: Any]? = nil
    ) throws -> CampaignCanvasWidget {
        var mergedProps = props
        if mergedProps["pages"] == nil {
            mergedProps["pages"] = pages ?? [
                makeStoryPageJSON(url: "https://example.com/story.jpg", durationSeconds: 5.0)
            ]
        }
        if mergedProps["chromeCanvas"] == nil {
            mergedProps["chromeCanvas"] = chrome ?? makeNestedCanvasJSON(height: 700)
        }

        let canvas = try CampaignCanvasParser().parse([
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": 200,
            "children": [
                [
                    "kind": "widget",
                    "id": "story-test",
                    "rect": ["x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0],
                    "widget": [
                        "type": "digia/canvasStory",
                        "props": mergedProps
                    ]
                ]
            ]
        ])

        guard case .widget(_, _, let widget) = canvas.children.first else {
            throw DesignTokenError.invalid("Failed to parse story widget")
        }
        return widget
    }

    private func makeStoryPageJSON(
        url: String,
        isVideo: Bool = false,
        durationSeconds: Double = 5.0
    ) -> [String: Any] {
        [
            "thumbnailType": isVideo ? "video" : "image",
            "thumbnailUrl": url,
            "thumbnailFit": "cover",
            "pageFit": "cover",
            "durationSeconds": durationSeconds,
            "canvas": makeNestedCanvasJSON(height: 700)
        ]
    }

    private func makeNestedCanvasJSON(height: Int = 200) -> [String: Any] {
        [
            "version": 2,
            "canvasWidth": 360,
            "canvasHeight": height,
            "background": ["type": "solid", "color": ["value": "#FF1E293B"]],
            "children": []
        ]
    }

    private func mount(
        canvas: CampaignCanvas,
        storyViewerState: CanvasStoryViewerState? = nil,
        isDark: Bool = false,
        onAction: @escaping (CampaignCanvasActionRequest) -> Void = { _ in }
    ) -> UIWindow {
        ComponentTestHost.mountCanvas(
            canvas,
            isDark: isDark,
            storyViewerState: storyViewerState,
            onAction: onAction
        ).window
    }

    private func unmount(_ window: UIWindow) {
        ComponentTestHost.unmount(window)
    }
}
