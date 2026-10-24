#if os(macOS)
import AppKit

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
    }

    func headingFont(level: Int) -> NSFont {
        headingFonts[min(max(level, 1), headingFonts.count) - 1]
    }

    func bulletSymbol(depth: Int) -> String {
        bulletSymbols[min(depth, bulletSymbols.count - 1)]
    }
}
#endif
