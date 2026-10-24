#if os(macOS)
import AppKit
import ScriblMarkdown
import ScriblMarkdownUI

/// How a rendered Markdown document looks. Hosts build one per surface (a chat message,
/// a plan card, a help page) from their own theme.
public struct MarkdownRenderStyle {
    /// How single newlines inside a paragraph render.
    public enum LineBreaks {
        /// Each newline starts a new line, as typed.
        case preserved
        /// Newlines join lines with a space, as in CommonMark.
        case collapsed
    }

    /// Which label an ordered list item shows.
    public enum OrderedListLabels {
        /// The number as written ("3.").
        case source
        /// The editor's hierarchy-aware label ("1.", "a.", "i.").
        case hierarchical
    }

    public var bodyFont: NSFont
    /// Heading fonts from level 1; deeper levels use the last font.
    public var headingFonts: [NSFont]
    public var codeFont: NSFont

    public var textColor: NSColor
    public var headingColor: NSColor
    /// Bold text's color; nil keeps the surrounding color.
    public var strongColor: NSColor?
    public var quoteTextColor: NSColor
    /// Footnote numbers, thematic breaks and image placeholders.
    public var mutedColor: NSColor
    public var linkColor: NSColor
    public var codeColor: NSColor
    public var codeBackgroundColor: NSColor?
    public var highlightColor: NSColor
    /// The bar beside block quotes, drawn by `MarkdownQuoteBarLayoutManager`; nil for none.
    public var quoteBarColor: NSColor?

    public var lineSpacing: CGFloat
    /// Space after a paragraph, heading, list or quote.
    public var blockSpacing: CGFloat
    /// Space between consecutive list items or quote lines.
    public var itemSpacing: CGFloat
    /// Extra space above a heading that follows other content.
    public var headingSpacingBefore: CGFloat
    public var listIndent: CGFloat
    public var listMarkerInset: CGFloat
    public var quoteIndent: CGFloat
    public var codeBlockIndent: CGFloat

    public var lineBreaks: LineBreaks
    public var orderedListLabels: OrderedListLabels
    /// Bullets by nesting depth; deeper levels use the last.
    public var bulletSymbols: [String]
    public var taskSymbols: (unchecked: String, checked: String)
    public var thematicBreakText: String
    /// Draws the shared look's markers with these colors: checklist boxes, rules, keycaps
    /// and disclosure chevrons, with accent footnote references. Nil draws checklists and
    /// rules with `taskSymbols` and `thematicBreakText`.
    public var markerPalette: MarkdownEditorPalette?
    /// Checked checklist items are struck through in this color; nil leaves them as is.
    public var completedTaskColor: NSColor?
    /// Keycaps and footnote numbers.
    public var keycapFont: NSFont
    /// How much the theme scales sizes designed for a 17pt body.
    public var scale: CGFloat

    public init(
        bodyFont: NSFont,
        headingFonts: [NSFont],
        codeFont: NSFont,
        textColor: NSColor,
        headingColor: NSColor? = nil,
        strongColor: NSColor? = nil,
        quoteTextColor: NSColor? = nil,
        mutedColor: NSColor? = nil,
        linkColor: NSColor = .linkColor,
        codeColor: NSColor? = nil,
        codeBackgroundColor: NSColor? = nil,
        highlightColor: NSColor = NSColor.systemYellow.withAlphaComponent(0.3),
        quoteBarColor: NSColor? = nil,
        lineSpacing: CGFloat = 0,
        blockSpacing: CGFloat = 8,
        itemSpacing: CGFloat = 2,
        headingSpacingBefore: CGFloat = 4,
        listIndent: CGFloat = 20,
        listMarkerInset: CGFloat = 6,
        quoteIndent: CGFloat = 14,
        codeBlockIndent: CGFloat = 12,
        lineBreaks: LineBreaks = .preserved,
        orderedListLabels: OrderedListLabels = .source,
        bulletSymbols: [String] = ["\u{2022}", "\u{25E6}", "\u{25AA}"],
        taskSymbols: (unchecked: String, checked: String) = ("\u{2610}", "\u{2611}"),
        thematicBreakText: String = String(repeating: "\u{2500}", count: 8)
    ) {
        self.bodyFont = bodyFont
        self.headingFonts = headingFonts.isEmpty ? [bodyFont] : headingFonts
        self.codeFont = codeFont
        self.textColor = textColor
        self.headingColor = headingColor ?? textColor
        self.strongColor = strongColor
        self.quoteTextColor = quoteTextColor ?? textColor
        self.mutedColor = mutedColor ?? textColor.withAlphaComponent(0.4)
        self.linkColor = linkColor
        self.codeColor = codeColor ?? textColor
        self.codeBackgroundColor = codeBackgroundColor
        self.highlightColor = highlightColor
        self.quoteBarColor = quoteBarColor
        self.lineSpacing = lineSpacing
        self.blockSpacing = blockSpacing
        self.itemSpacing = itemSpacing
        self.headingSpacingBefore = headingSpacingBefore
        self.listIndent = listIndent
        self.listMarkerInset = listMarkerInset
        self.quoteIndent = quoteIndent
        self.codeBlockIndent = codeBlockIndent
        self.lineBreaks = lineBreaks
        self.orderedListLabels = orderedListLabels
        self.bulletSymbols = bulletSymbols.isEmpty ? ["\u{2022}"] : bulletSymbols
        self.taskSymbols = taskSymbols
        self.thematicBreakText = thematicBreakText
        self.markerPalette = nil
        self.completedTaskColor = nil
        self.scale = bodyFont.pointSize / MarkdownVisualSpec.referenceBodySize
        self.keycapFont = NSFont.monospacedSystemFont(ofSize: 13 * scale, weight: .medium)
    }

    /// Spacing for a display surface.
    public enum Spacing {
        /// Long-form documents: paragraph spacing between blocks.
        case document
        /// Cards and short descriptions: tight spacing.
        case compact
    }

    /// The shared look in `theme`: headings 1–6 on the shared scale, depth bullets,
    /// hierarchical list labels, drawn checklists and rules, plain quotes with an accent
    /// bar, and the theme's inline code and highlight tokens.
    public init(theme: MarkdownTheme, spacing: Spacing = .document, lineBreaks: LineBreaks = .preserved) {
        let palette = theme.palette
        let isDocument = spacing == .document
        self.init(
            bodyFont: theme.bodyFont,
            headingFonts: (1...6).map(theme.headingFont(level:)),
            codeFont: theme.inlineCodeFont,
            textColor: palette.text,
            headingColor: palette.text,
            quoteTextColor: palette.text,
            mutedColor: palette.tertiaryText,
            linkColor: palette.link,
            codeColor: palette.inlineCodeText,
            codeBackgroundColor: palette.inlineCodeBackground,
            highlightColor: palette.highlightBackground,
            quoteBarColor: palette.accent,
            lineSpacing: theme.scaled(isDocument ? 3 : 1),
            blockSpacing: theme.scaled(isDocument ? 10 : 4),
            itemSpacing: theme.scaled(isDocument ? 3 : 1),
            headingSpacingBefore: theme.scaled(isDocument ? 8 : 4),
            listIndent: theme.scaled(isDocument ? 22 : 16),
            listMarkerInset: theme.scaled(isDocument ? 4 : 2),
            quoteIndent: theme.scaled(14),
            codeBlockIndent: theme.scaled(12),
            lineBreaks: lineBreaks,
            orderedListLabels: .hierarchical,
            bulletSymbols: MarkdownVisualSpec.bulletSymbols
        )
        markerPalette = palette
        completedTaskColor = palette.completedText
        scale = theme.scaled(1)
        keycapFont = theme.typeface.monospacedFont(ofSize: theme.scaled(13), weight: .medium)
    }

    func headingFont(level: Int) -> NSFont {
        headingFonts[min(max(level, 1), headingFonts.count) - 1]
    }

    func bulletSymbol(depth: Int) -> String {
        bulletSymbols[min(depth, bulletSymbols.count - 1)]
    }
}
#endif
