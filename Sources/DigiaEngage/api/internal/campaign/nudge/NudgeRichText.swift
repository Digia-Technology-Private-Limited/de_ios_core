import SwiftUI
import UIKit
import CoreText

// Custom attributes carrying a run's decoration colour + thickness. NSAttributedString
// has `underlineColor`/`strikethroughColor` but no thickness, so we draw both
// ourselves in the layout manager below for full control.
extension NSAttributedString.Key {
    static let digiaDecorationColor = NSAttributedString.Key("digiaDecorationColor")
    static let digiaDecorationThickness = NSAttributedString.Key("digiaDecorationThickness")
}

/// TextKit-1 layout manager that draws underline / strikethrough with a per-run
/// colour and thickness. When a run carries no custom decoration attribute it
/// defers to the system drawing (which underlines in the text colour).
final class DigiaDecorationLayoutManager: NSLayoutManager {
    override func drawUnderline(
        forGlyphRange glyphRange: NSRange, underlineType: NSUnderlineStyle,
        baselineOffset: CGFloat, lineFragmentRect: CGRect,
        lineFragmentGlyphRange: NSRange, containerOrigin: CGPoint
    ) {
        // TextKit groups adjacent runs sharing `.underlineStyle` into a single call,
        // even when their custom thickness/colour differ — so split the range back
        // into its attribute runs and draw each at its own thickness instead of the
        // whole span inheriting the first run's. Runs without a custom thickness
        // fall through to the system, which draws per run as before.
        enumerateDecorationRuns(in: glyphRange) { runGlyphRange in
            if self.drawCustomLine(runGlyphRange, lineFragmentRect, baselineOffset, containerOrigin, false) {
                return
            }
            super.drawUnderline(
                forGlyphRange: runGlyphRange, underlineType: underlineType,
                baselineOffset: baselineOffset, lineFragmentRect: lineFragmentRect,
                lineFragmentGlyphRange: lineFragmentGlyphRange, containerOrigin: containerOrigin
            )
        }
    }

    override func drawStrikethrough(
        forGlyphRange glyphRange: NSRange, strikethroughType: NSUnderlineStyle,
        baselineOffset: CGFloat, lineFragmentRect: CGRect,
        lineFragmentGlyphRange: NSRange, containerOrigin: CGPoint
    ) {
        // See drawUnderline: split the merged range so each run keeps its own thickness.
        enumerateDecorationRuns(in: glyphRange) { runGlyphRange in
            if self.drawCustomLine(runGlyphRange, lineFragmentRect, baselineOffset, containerOrigin, true) {
                return
            }
            super.drawStrikethrough(
                forGlyphRange: runGlyphRange, strikethroughType: strikethroughType,
                baselineOffset: baselineOffset, lineFragmentRect: lineFragmentRect,
                lineFragmentGlyphRange: lineFragmentGlyphRange, containerOrigin: containerOrigin
            )
        }
    }

    /// Splits `glyphRange` into maximal sub-ranges of constant attributes and calls
    /// `body` for each. This undoes TextKit's merging of adjacent decorated runs, so
    /// `drawCustomLine` (which reads thickness/colour from each sub-range's first
    /// character) applies the right value to each run rather than to the whole span.
    private func enumerateDecorationRuns(in glyphRange: NSRange, _ body: (NSRange) -> Void) {
        guard let textStorage else { body(glyphRange); return }
        let charRange = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard charRange.length > 0 else { body(glyphRange); return }
        textStorage.enumerateAttributes(in: charRange, options: []) { _, runCharRange, _ in
            let runGlyphRange = self.glyphRange(forCharacterRange: runCharRange, actualCharacterRange: nil)
            if runGlyphRange.length > 0 { body(runGlyphRange) }
        }
    }

    /// Returns true when it drew a custom line (so the caller skips the default).
    private func drawCustomLine(
        _ glyphRange: NSRange, _ lineFragmentRect: CGRect, _ baselineOffset: CGFloat,
        _ containerOrigin: CGPoint, _ strikethrough: Bool
    ) -> Bool {
        guard let textStorage, let container = textContainers.first else { return false }
        let charRange = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard charRange.location < textStorage.length else { return false }
        let attrs = textStorage.attributes(at: charRange.location, effectiveRange: nil)
        // Only take over drawing for a custom thickness — colour is handled natively
        // (underlineColor / strikethroughColor), which positions exactly like the
        // system and matches Flutter/CSS. No custom thickness → let `super` draw.
        guard let thickness = attrs[.digiaDecorationThickness] as? CGFloat else { return false }
        let customColor = attrs[.digiaDecorationColor] as? UIColor

        let font = (attrs[.font] as? UIFont) ?? .systemFont(ofSize: UIFont.systemFontSize)
        let ctFont = font as CTFont
        let rect = boundingRect(forGlyphRange: glyphRange, in: container)
        let baselineY = lineFragmentRect.minY + baselineOffset + containerOrigin.y
        // Position off the font metrics so it matches Flutter/CSS: underline just
        // below the baseline (the font's underline position is negative = below in
        // CoreText's y-up space, so subtract); strikethrough through the x-height.
        let y = strikethrough
            ? baselineY - font.xHeight / 2
            : baselineY - CTFontGetUnderlinePosition(ctFont)
        let color = customColor ?? (attrs[.foregroundColor] as? UIColor) ?? .label

        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.minX + containerOrigin.x, y: y))
        path.addLine(to: CGPoint(x: rect.maxX + containerOrigin.x, y: y))
        path.lineWidth = thickness
        color.setStroke()
        path.stroke()
        return true
    }
}

/// Renders an `NSAttributedString` through a non-scrolling `UITextView` backed by
/// `DigiaDecorationLayoutManager` (TextKit 1), so rich text can carry decoration
/// colour/thickness and a block-level line height (paragraph style) that SwiftUI
/// `Text` can't express.
struct NudgeRichText: UIViewRepresentable {
    let attributed: NSAttributedString
    let fillWidth: Bool

    func makeUIView(context: Context) -> UITextView {
        let storage = NSTextStorage()
        let manager = DigiaDecorationLayoutManager()
        let container = NSTextContainer(size: .zero)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)

        let textView = UITextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.setContentHuggingPriority(.required, for: .vertical)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.textStorage.setAttributedString(attributed)
        textView.invalidateIntrinsicContentSize()
    }

    // This `UIViewRepresentable` sizing hook needs iOS 16; below that, SwiftUI falls
    // back to the view's intrinsic content size (set via `setContentHuggingPriority` above).
    @available(iOS 16, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: fillWidth ? width : ceil(fit.width), height: ceil(fit.height))
    }
}
