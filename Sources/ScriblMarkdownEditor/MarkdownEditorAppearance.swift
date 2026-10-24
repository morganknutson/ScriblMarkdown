#if os(macOS)
import AppKit
@_exported import ScriblMarkdownUI
import ScriblMarkdown

/// Everything that decides how the editor looks: the shared Markdown theme and the
/// editor's own margins.
public struct MarkdownEditorStyle {
    /// The body size every other size is designed against; `bodyFontSize` scales them all.
    public static let referenceBodyFontSize: CGFloat = MarkdownVisualSpec.referenceBodySize

    public var theme: MarkdownTheme
    public var textContainerInset: NSSize

    public init(
        theme: MarkdownTheme,
        textContainerInset: NSSize = NSSize(width: 28, height: 22)
    ) {
        self.theme = theme
        self.textContainerInset = textContainerInset
    }

    /// A theme derived from `palette`, `typeface` and `bodyFontSize`.
    public init(
        palette: MarkdownEditorPalette = .system,
        typeface: any MarkdownEditorTypeface = SystemMarkdownEditorTypeface(),
        bodyFontSize: CGFloat = MarkdownEditorStyle.referenceBodyFontSize,
        textContainerInset: NSSize = NSSize(width: 28, height: 22)
    ) {
        self.init(
            theme: MarkdownTheme(palette: palette, typeface: typeface, bodyFontSize: bodyFontSize),
            textContainerInset: textContainerInset
        )
    }

    public var palette: MarkdownEditorPalette { theme.palette }

    public var typeface: any MarkdownEditorTypeface { theme.typeface }

    public var bodyFontSize: CGFloat { theme.bodyFontSize }

    /// Scales a size designed against `referenceBodyFontSize` to the configured body size.
    public func scaled(_ referenceSize: CGFloat) -> CGFloat {
        theme.scaled(referenceSize)
    }
}

/// The formatting at the editor's caret, for reflecting in a toolbar.
public struct MarkdownEditorFormatting: Equatable {
    /// 1 for `#` through 6 for `######`; nil for body text.
    public let headingLevel: Int?
    public let isBold: Bool
    public let isItalic: Bool
    public let isInlineCode: Bool
    public let isQuote: Bool
    public let isCodeBlock: Bool

    public init(
        headingLevel: Int?,
        isBold: Bool,
        isItalic: Bool,
        isInlineCode: Bool,
        isQuote: Bool,
        isCodeBlock: Bool
    ) {
        self.headingLevel = headingLevel
        self.isBold = isBold
        self.isItalic = isItalic
        self.isInlineCode = isInlineCode
        self.isQuote = isQuote
        self.isCodeBlock = isCodeBlock
    }
}
#endif
