#if os(macOS)
import AppKit

extension NSAttributedString.Key {
    /// Marks block quote text; the value is the bar's `NSColor`.
    public static let markdownQuoteBar = NSAttributedString.Key("scribl.markdownQuoteBar")
}

/// Draws one continuous bar beside each run of `.markdownQuoteBar` text, covering wrapped
/// lines and the gaps between them. Install it in any text view showing rendered quotes.
public final class MarkdownQuoteBarLayoutManager: NSLayoutManager {
    public static let barWidth: CGFloat = 3

    public override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let textStorage, textStorage.length > 0 else { return }
        let charsToShow = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        textStorage.enumerateAttribute(.markdownQuoteBar, in: charsToShow) { value, charRange, _ in
            guard let color = value as? NSColor else { return }
            let glyphRange = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
            var barRect = NSRect.null
            enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, _, _ in
                barRect = barRect.union(rect)
            }
            guard !barRect.isNull else { return }
            let bar = NSRect(
                x: origin.x + barRect.minX,
                y: origin.y + barRect.minY,
                width: Self.barWidth,
                height: barRect.height
            )
            color.setFill()
            NSBezierPath(roundedRect: bar, xRadius: Self.barWidth / 2, yRadius: Self.barWidth / 2).fill()
        }
    }
}
#endif
