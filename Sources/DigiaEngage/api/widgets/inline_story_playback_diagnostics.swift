import QuartzCore
import SwiftUI
import UIKit

enum StoryThumbnailPlaybackDiagnostics {
    static func log(_ message: String) {
        DigiaLog.log(message, tag: "DigiaStoryPerf")
    }
}

struct StoryThumbnailJankMonitor: UIViewRepresentable {
    let slotKey: String

    func makeUIView(context: Context) -> StoryThumbnailJankMonitorView {
        StoryThumbnailJankMonitorView(slotKey: slotKey)
    }

    func updateUIView(_ uiView: StoryThumbnailJankMonitorView, context: Context) {
        uiView.slotKey = slotKey
    }

    static func dismantleUIView(_ uiView: StoryThumbnailJankMonitorView, coordinator: ()) {
        uiView.stop()
    }
}

final class StoryThumbnailJankMonitorView: UIView {
    var slotKey: String
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var reportStartedAt = CACurrentMediaTime()
    private var frameIntervals: [CFTimeInterval] = []

    init(slotKey: String) {
        self.slotKey = slotKey
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stop()
        } else {
            start()
        }
    }

    private func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(frameTick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        reportStartedAt = CACurrentMediaTime()
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = 0
        StoryThumbnailPlaybackDiagnostics.log("jank_monitor_disposed slot=\(slotKey)")
    }

    @objc private func frameTick(_ link: CADisplayLink) {
        if lastTimestamp != 0 {
            let elapsed = link.timestamp - lastTimestamp
            if elapsed > 0, elapsed < 1 {
                frameIntervals.append(elapsed)
            }
        }
        lastTimestamp = link.timestamp

        let now = CACurrentMediaTime()
        guard now - reportStartedAt >= 5 else { return }
        let sorted = frameIntervals.sorted()
        let frameBudget = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let jankIntervals = sorted.filter { $0 > frameBudget * 1.5 }
        let observedRefreshRate = frameBudget > 0 ? 1 / frameBudget : 0
        StoryThumbnailPlaybackDiagnostics.log(
            "frame_summary slot=\(slotKey) hz=\(String(format: "%.1f", observedRefreshRate)) "
                + "frames=\(sorted.count) jank=\(jankIntervals.count) "
                + "worstMs=\(String(format: "%.1f", (jankIntervals.last ?? 0) * 1_000))"
        )
        reportStartedAt = now
        frameIntervals.removeAll(keepingCapacity: true)
    }
}
