#if os(macOS)
import AppKit
import ScriblMarkdownUI

extension NSAttributedString.Key {
    /// Marks block quote text; the value is the bar's `NSColor`.
    public static let markdownQuoteBar = NSAttributedString.Key("scribl.markdownQuoteBar")
    /// Marks a horizontal rule's line; the value is the rule's `NSColor`.
    public static let markdownRule = NSAttributedString.Key("scribl.markdownRule")
}

/// Draws the rendered decorations that span lines: one continuous bar beside each run of
/// `.markdownQuoteBar` text (covering wrapped lines and the gaps between them), and a
/// hairline across the text container for each `.markdownRule`. Install it in any text view
/// showing rendered Markdown.
public final class MarkdownDecorationLayoutManager: NSLayoutManager {
    public static let barWidth: CGFloat = 3

    public override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let textStorage, textStorage.length > 0 else { return }
        let charsToShow = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        textStorage.enumerateAttribute(.markdownQuoteBar, in: charsToShow) { value, charRange, _ in
            guard let color = value as? NSColor else { return }
            let barRect = lineFragmentsRect(forCharacterRange: charRange)
            guard !barRect.isNull else { return }
            let bar = NSRect(x: origin.x + barRect.minX, y: origin.y + barRect.minY, width: Self.barWidth, height: barRect.height)
            color.setFill()
            NSBezierPath(roundedRect: bar, xRadius: Self.barWidth / 2, yRadius: Self.barWidth / 2).fill()
        }
        textStorage.enumerateAttribute(.markdownRule, in: charsToShow) { value, charRange, _ in
            guard let color = value as? NSColor else { return }
            let glyphRange = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
            enumerateLineFragments(forGlyphRange: glyphRange) { rect, usedRect, container, _, _ in
                // The rule's line, without the paragraph spacing below it.
                let lineRect = NSRect(x: rect.minX, y: rect.minY, width: container.size.width - container.lineFragmentPadding * 2, height: usedRect.height)
                color.setFill()
                NSRect(x: origin.x + lineRect.minX, y: origin.y + lineRect.midY - 0.5, width: lineRect.width, height: 1).fill()
            }
        }
    }

    private func lineFragmentsRect(forCharacterRange charRange: NSRange) -> NSRect {
        let glyphRange = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        var rect = NSRect.null
        enumerateLineFragments(forGlyphRange: glyphRange) { fragment, _, _, _, _ in
            rect = rect.union(fragment)
        }
        return rect
    }
}

@available(*, deprecated, renamed: "MarkdownDecorationLayoutManager")
public typealias MarkdownQuoteBarLayoutManager = MarkdownDecorationLayoutManager
#endif
