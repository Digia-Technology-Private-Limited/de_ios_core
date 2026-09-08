import Foundation

/// Space between an inline card and the edges of its slot, in logical pixels.
struct InlineCanvasMargin: Equatable {
    var top: Double = 0
    var right: Double = 0
    var bottom: Double = 0
    var left: Double = 0

    var horizontal: Double { left + right }
    var vertical: Double { top + bottom }
}

/// A free-form inline campaign: an authored Canvas rendered inside a slot.
///
/// The `canvas` block is byte-identical to the one a canvas nudge carries, so it
/// goes through the shared `CampaignCanvasParser` with no inline-specific branch.
/// What is inline-specific is everything around it: which slot it lands in, and
/// the card chrome the host draws.
struct InlineCanvasConfig: Equatable {
    let slotKey: String
    /// The logical width the canvas was authored against. Runtime scale is
    /// `slotWidth / designWidth`, so this is the only number relating authored
    /// coordinates to real ones.
    let designWidth: Double
    var cornerRadius: Double = 0
    var margin: InlineCanvasMargin = .init()
    let canvas: CampaignCanvas
    var variableSchemas: [VariableSchema] = []

    /// Returns nil when the payload is not a usable inline canvas, so the
    /// campaign parser can skip it rather than render a broken card.
    static func fromJson(
        _ json: [String: Any],
        designTokens: DesignTokenCatalog = .empty
    ) -> InlineCanvasConfig? {
        guard let slotKey = json.nonBlankString("slotKey"),
              let canvasJson = json.object("canvas")
        else { return nil }

        // A canvas version this build cannot read. Collapsing the slot is the
        // right failure: the app shows its own content instead of a
        // half-understood card.
        guard let canvas = try? CampaignCanvasParser(designTokens: designTokens).parse(canvasJson)
        else { return nil }

        let marginJson = json.object("layout")?.object("margin") ?? [:]
        let authoredDesignWidth = json.double("designWidth", default: 0).finiteOrZero

        return InlineCanvasConfig(
            slotKey: slotKey,
            // The authored canvas spans the design frame, so its own width is the
            // right fallback when an older payload omits `designWidth`.
            designWidth: authoredDesignWidth > 0 ? authoredDesignWidth : Double(canvas.width),
            cornerRadius: json.double("cornerRadius", default: 0).finiteOrZero,
            margin: InlineCanvasMargin(
                top: marginJson.double("top", default: 0).finiteOrZero,
                right: marginJson.double("right", default: 0).finiteOrZero,
                bottom: marginJson.double("bottom", default: 0).finiteOrZero,
                left: marginJson.double("left", default: 0).finiteOrZero
            ),
            canvas: canvas
        )
    }
}

private extension Double {
    var finiteOrZero: Double { isFinite ? self : 0 }
}
