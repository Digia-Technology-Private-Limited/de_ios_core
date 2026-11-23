import Foundation
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

// A classic nudge image or Lottie whose URL is blank or an unresolved `{{variable}}` goes through
// the media wrapper like any other failure: one `invalid_url` for the campaign, and the node keeps
// the height it would have had, so the dialog does not collapse. A carousel drops such slides
// instead: they take no page, and a carousel left with none keeps its height and reports nothing.

extension RenderedUITests {
@MainActor
@Suite("Classic nudge media with an unusable url", .serialized, .tags(.media, .component, .nudge))
struct MediaNudgeUnresolvedTests {
    private static let image = NudgeNode.image(NudgeImage(
        box: NudgeBox(), url: "{{hero}}", aspectRatio: 0, fit: .cover, placeholder: nil))
    private static let lottie = NudgeNode.lottie(NudgeLottie(
        box: NudgeBox(), url: "", height: 90, loop: true, autoplay: true, fit: .cover, aspectRatio: 0))
    private static func carousel(_ images: [String]) -> NudgeNode {
        .carousel(NudgeCarousel(
            box: NudgeBox(), images: images, height: 100, autoPlay: false,
            autoPlayIntervalMs: 3000, loop: false, showIndicator: false))
    }

    private static func column(_ node: NudgeNode) -> NudgeColumn {
        NudgeColumn(crossAxisAlignment: .start, mainAxisAlignment: .start, children: [node])
    }

    @Test("an unusable url reports invalid_url once for the campaign and keeps the node's height", arguments: [
        (0, HealthMediaKind.image, CGFloat(120)),
        (1, HealthMediaKind.lottie, CGFloat(90)),
    ])
    func unusableURLReportsAndKeepsSize(index: Int, kind: HealthMediaKind, height: CGFloat) async {
        let node = [Self.image, Self.lottie][index]
        let recorder = HealthRecorder()

        let window = MediaStage.mount(NudgeColumnContent(column: Self.column(node), onDismiss: {}))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !recorder.all.isEmpty })
        ComponentTestHost.drainRunLoop(for: 0.3)

        #expect(recorder.all == [.init(campaignKey: MediaStage.campaign, kind: kind, cause: "invalid_url")])

        let host = UIHostingController(rootView: NudgeColumnContent(column: Self.column(node), onDismiss: {}))
        let fitted = host.sizeThatFits(in: CGSize(width: 390, height: 2000))
        #expect(fitted.height == height)
    }

    // Fails if `NudgeCarouselView.images` stops dropping slides whose url is not usable: the
    // blank first slide would take a page and report `invalid_url`.
    @Test("a carousel drops its unusable slides: they take no page and report nothing")
    func carouselDropsUnusableSlides() async {
        MediaOrigin.install()
        defer { MediaOrigin.end() }
        let target = MediaOrigin.url("slide.png")
        MediaOrigin.set(.status(200, solidPNG(.red)), for: target)
        let recorder = HealthRecorder()

        let node = Self.carousel(["{{first}}", target.absoluteString])
        let window = MediaStage.mount(NudgeColumnContent(column: Self.column(node), onDismiss: {}))
        defer { ComponentTestHost.unmount(window) }
        #expect(await waitUntilMedia { !MediaOrigin.requests(for: target).isEmpty })
        ComponentTestHost.drainRunLoop(for: 0.3)

        #expect(recorder.all.isEmpty)
    }

    @Test("a carousel with no usable slide reports nothing and keeps its height")
    func blankCarouselKeepsHeight() async {
        let node = Self.carousel(["{{first}}", ""])
        let recorder = HealthRecorder()
        defer { MediaOrigin.end() }

        let window = MediaStage.mount(NudgeColumnContent(column: Self.column(node), onDismiss: {}))
        defer { ComponentTestHost.unmount(window) }
        ComponentTestHost.drainRunLoop(for: 0.3)
        #expect(recorder.all.isEmpty)

        let host = UIHostingController(rootView: NudgeColumnContent(column: Self.column(node), onDismiss: {}))
        #expect(host.sizeThatFits(in: CGSize(width: 390, height: 2000)).height == 100)
    }
}
}
