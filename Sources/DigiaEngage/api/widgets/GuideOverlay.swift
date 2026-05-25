import SwiftUI

/// Top-level overlay view. Renders a tooltip bubble or full spotlight depending
/// on `state.currentStep.widgetConfig.overlayVisible`.
struct GuideOverlay: View {
    let state: ActiveGuideState
    let anchorRect: CGRect
    let orchestrator: GuideOrchestrator

    var body: some View {
        let config = state.currentStep.widgetConfig
        if config.overlayVisible {
            SpotlightOverlay(state: state, anchorRect: anchorRect, orchestrator: orchestrator)
        } else {
            TooltipBubble(state: state, anchorRect: anchorRect, orchestrator: orchestrator)
                .allowsHitTesting(true)           // bubble captures its own touches
        }
    }
}

// ── Tooltip Bubble ────────────────────────────────────────────────────────────

struct TooltipBubble: View {
    let state: ActiveGuideState
    let anchorRect: CGRect
    let orchestrator: GuideOrchestrator

    @State private var bubbleSize: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let placement = computedPlacement(
                preferred: state.currentStep.widgetConfig.preferredDirection,
                anchorRect: anchorRect,
                screenSize: geo.size,
                bubbleSize: bubbleSize
            )
            let config = state.currentStep.widgetConfig

            ZStack(alignment: .topLeading) {
                bubbleContent(config: config, placement: placement)
                    .background(
                        RoundedRectangle(cornerRadius: config.cornerRadius)
                            .fill(Color(hex: config.bubbleBackgroundColor))
                            .shadow(radius: 6)
                    )
                    .overlay(arrowShape(placement: placement, color: Color(hex: config.bubbleBackgroundColor)))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: config.maxWidth)
                    .background(
                        GeometryReader { g in
                            Color.clear.onAppear { bubbleSize = g.size }
                                .onChange(of: g.size) { _, s in bubbleSize = s }
                        }
                    )
                    .position(bubblePosition(placement: placement, anchorRect: anchorRect,
                                             bubbleSize: bubbleSize, screenSize: geo.size))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(true)
        // Auto-advance timer
        .task(id: state.stepIndex) {
            guard state.currentStep.advanceTrigger == "auto",
                  let ms = state.currentStep.autoDelayMs else { return }
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            if state.hasNext { orchestrator.advance() } else { orchestrator.dismiss() }
        }
    }

    // MARK: Bubble content

    @ViewBuilder
    private func bubbleContent(config: GuideWidgetConfig, placement: Edge) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                if let title = config.titleText, !title.isEmpty {
                    Text(title)
                        .font(.system(size: config.titleFontSize, weight: .semibold))
                        .foregroundColor(Color(hex: config.titleColor))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
                Button(action: { orchestrator.dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
            }

            if let body = config.bodyText, !body.isEmpty {
                Text(body)
                    .font(.system(size: config.bodyFontSize))
                    .foregroundColor(Color(hex: config.bodyColor))
            }

            if config.showStepIndicator && state.totalSteps > 1 {
                Text("\(state.stepIndex + 1) / \(state.totalSteps)")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: config.stepIndicatorColor))
            }

            if !config.actions.isEmpty {
                HStack(spacing: 8) {
                    Spacer()
                    ForEach(config.actions) { action in
                        actionButton(action: action, config: config)
                    }
                }
            }
        }
        .padding(.horizontal, config.paddingH)
        .padding(.vertical, config.paddingV)
    }

    @ViewBuilder
    private func actionButton(action: GuideActionConfig, config: GuideWidgetConfig) -> some View {
        Button(action: {
            switch action.actionType {
            case .dismiss: orchestrator.dismiss()
            case .next:    if state.hasNext { orchestrator.advance() } else { orchestrator.dismiss() }
            case .prev:    break
            }
        }) {
            Text(action.label)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(hex: action.textColor))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: action.cornerRadius)
                        .fill(action.style == "ghost"
                              ? Color.clear
                              : Color(hex: action.backgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: action.cornerRadius)
                                .stroke(Color(hex: action.backgroundColor), lineWidth: action.style == "ghost" ? 1 : 0)
                        )
                )
        }
    }

    // MARK: Arrow shape

    @ViewBuilder
    private func arrowShape(placement: Edge, color: Color) -> some View {
        GeometryReader { geo in
            let arrowW: CGFloat = 12
            let arrowH: CGFloat = 8
            switch placement {
            case .bottom: // arrow on top pointing up into anchor
                Path { p in
                    let midX = geo.size.width / 2
                    p.move(to: CGPoint(x: midX - arrowW / 2, y: 0))
                    p.addLine(to: CGPoint(x: midX + arrowW / 2, y: 0))
                    p.addLine(to: CGPoint(x: midX, y: -arrowH))
                    p.closeSubpath()
                }.fill(color)
            case .top: // arrow on bottom pointing down toward anchor
                Path { p in
                    let midX = geo.size.width / 2
                    let baseY = geo.size.height
                    p.move(to: CGPoint(x: midX - arrowW / 2, y: baseY))
                    p.addLine(to: CGPoint(x: midX + arrowW / 2, y: baseY))
                    p.addLine(to: CGPoint(x: midX, y: baseY + arrowH))
                    p.closeSubpath()
                }.fill(color)
            case .trailing: // arrow on leading edge
                Path { p in
                    let midY = geo.size.height / 2
                    p.move(to: CGPoint(x: 0, y: midY - arrowW / 2))
                    p.addLine(to: CGPoint(x: 0, y: midY + arrowW / 2))
                    p.addLine(to: CGPoint(x: -arrowH, y: midY))
                    p.closeSubpath()
                }.fill(color)
            case .leading: // arrow on trailing edge
                Path { p in
                    let midY = geo.size.height / 2
                    let baseX = geo.size.width
                    p.move(to: CGPoint(x: baseX, y: midY - arrowW / 2))
                    p.addLine(to: CGPoint(x: baseX, y: midY + arrowW / 2))
                    p.addLine(to: CGPoint(x: baseX + arrowH, y: midY))
                    p.closeSubpath()
                }.fill(color)
            }
        }
    }

    // MARK: Placement helpers

    private func computedPlacement(
        preferred: String,
        anchorRect: CGRect,
        screenSize: CGSize,
        bubbleSize: CGSize
    ) -> Edge {
        let spaceAbove    = anchorRect.minY
        let spaceBelow    = screenSize.height - anchorRect.maxY
        let spaceLeading  = anchorRect.minX
        let spaceTrailing = screenSize.width - anchorRect.maxX
        let bh = max(bubbleSize.height, 80)
        let bw = max(bubbleSize.width, 200)

        switch preferred {
        case "top":
            return spaceAbove >= bh ? .bottom : (spaceBelow >= bh ? .top : .bottom)
        case "bottom":
            return spaceBelow >= bh ? .top : (spaceAbove >= bh ? .bottom : .top)
        case "start":
            return spaceLeading >= bw ? .trailing : .leading
        case "end":
            return spaceTrailing >= bw ? .leading : .trailing
        default: // "auto" — pick side with most space
            let spaces: [(CGFloat, Edge)] = [
                (spaceAbove, .bottom), (spaceBelow, .top),
                (spaceLeading, .trailing), (spaceTrailing, .leading)
            ]
            return spaces.max(by: { $0.0 < $1.0 })?.1 ?? .top
        }
    }

    private func bubblePosition(
        placement: Edge,
        anchorRect: CGRect,
        bubbleSize: CGSize,
        screenSize: CGSize
    ) -> CGPoint {
        let margin: CGFloat = 8
        let arrowOffset: CGFloat = 10
        let bw = bubbleSize.width > 0 ? bubbleSize.width : 200
        let bh = bubbleSize.height > 0 ? bubbleSize.height : 80

        var x: CGFloat
        var y: CGFloat

        switch placement {
        case .top:   // bubble below anchor
            x = anchorRect.midX
            y = anchorRect.maxY + arrowOffset + bh / 2
        case .bottom: // bubble above anchor
            x = anchorRect.midX
            y = anchorRect.minY - arrowOffset - bh / 2
        case .leading: // bubble to the right
            x = anchorRect.maxX + arrowOffset + bw / 2
            y = anchorRect.midY
        case .trailing: // bubble to the left
            x = anchorRect.minX - arrowOffset - bw / 2
            y = anchorRect.midY
        }

        // Clamp to screen
        x = x.clamped(to: bw / 2 + margin ... screenSize.width - bw / 2 - margin)
        y = y.clamped(to: bh / 2 + margin ... screenSize.height - bh / 2 - margin)
        return CGPoint(x: x, y: y)
    }
}

// ── Spotlight Overlay ─────────────────────────────────────────────────────────

struct SpotlightOverlay: View {
    let state: ActiveGuideState
    let anchorRect: CGRect
    let orchestrator: GuideOrchestrator

    var body: some View {
        let config = state.currentStep.widgetConfig
        let overlayAlpha = config.overlayAlpha
        let cutoutPad = config.cutoutPadding

        ZStack {
            // Dim layer with cutout
            Canvas { ctx, size in
                // Full dim
                ctx.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(Color(hex: config.overlayColor).opacity(overlayAlpha))
                )
                // Cutout punch-out via destinationOut
                let padded = anchorRect.insetBy(dx: -cutoutPad, dy: -cutoutPad)
                let cutoutPath: Path
                switch config.cutoutShape {
                case "circle":
                    cutoutPath = Path(ellipseIn: padded)
                case "rect":
                    cutoutPath = Path(padded)
                default: // "rounded_rect"
                    cutoutPath = Path(roundedRect: padded, cornerRadius: config.cutoutCornerRadius)
                }
                ctx.blendMode = .destinationOut
                ctx.fill(cutoutPath, with: .color(.white))
            }
            .compositingGroup()
            .ignoresSafeArea()
            .onTapGesture {
                if config.dismissOnTap { orchestrator.dismiss() }
            }

            // Tooltip bubble on top
            TooltipBubble(state: state, anchorRect: anchorRect, orchestrator: orchestrator)
        }
        .task(id: state.stepIndex) {
            guard state.currentStep.advanceTrigger == "auto",
                  let ms = state.currentStep.autoDelayMs else { return }
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            if state.hasNext { orchestrator.advance() } else { orchestrator.dismiss() }
        }
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension Color {
    init(hex: String) {
        var h = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        if h.count == 6 { h += "FF" }
        guard h.count == 8, let val = UInt64(h, radix: 16) else {
            self = .white; return
        }
        let r = Double((val >> 24) & 0xFF) / 255
        let g = Double((val >> 16) & 0xFF) / 255
        let b = Double((val >>  8) & 0xFF) / 255
        let a = Double( val        & 0xFF) / 255
        self.init(red: r, green: g, blue: b, opacity: a)
    }
}
