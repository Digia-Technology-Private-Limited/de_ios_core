import Foundation
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

// A classic nudge image, Lottie or carousel whose URL is blank or an unresolved `{{variable}}` goes
// through the media wrapper like any other failure: one `invalid_url` for the campaign, and the
// node keeps the height it would have had, so the dialog does not collapse.

extension RenderedUITests {
@MainActor
@Suite("Classic nudge media with an unusable url", .serialized, .tags(.media, .component, .nudge))
struct MediaNudgeUnresolvedTests {
    private static let image = NudgeNode.image(NudgeImage(
        box: NudgeBox(), url: "{{hero}}", aspectRatio: 0, fit: .cover, placeholder: nil))
    private static let lottie = NudgeNode.lottie(NudgeLottie(
        box: NudgeBox(), url: "", height: 90, loop: true, autoplay: true, fit: .cover, aspectRatio: 0))
    // The second slide is never built: a paged carousel builds the page on screen.
    private static let carousel = NudgeNode.carousel(NudgeCarousel(
        box: NudgeBox(), images: ["{{first}}", "{{second}}"], height: 100, autoPlay: false,
        autoPlayIntervalMs: 3000, loop: false, showIndicator: false))

    private static func column(_ node: NudgeNode) -> NudgeColumn {
        NudgeColumn(crossAxisAlignment: .start, mainAxisAlignment: .start, children: [node])
    }

    @Test("an unusable url reports invalid_url once for the campaign and keeps the node's height", arguments: [
        (0, HealthMediaKind.image, CGFloat(120)),
        (1, HealthMediaKind.lottie, CGFloat(90)),
        (2, HealthMediaKind.image, CGFloat(100)),
    ])
    func unusableURLReportsAndKeepsSize(index: Int, kind: HealthMediaKind, height: CGFloat) async {
        let node = [Self.image, Self.lottie, Self.carousel][index]
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
}
}
