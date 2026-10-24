#if os(macOS)
import AppKit
import ScriblMarkdown

/// The colors Markdown text is drawn with. `.system` follows AppKit's semantic colors;
/// hosts with their own theme supply resolved colors and reapply on theme change.
public struct MarkdownEditorPalette: Equatable {
    public var text: NSColor
    public var secondaryText: NSColor
    public var tertiaryText: NSColor
    public var quaternaryText: NSColor
    /// Quote bars, checked checklists, footnote references and selection outlines.
    public var accent: NSColor
    public var link: NSColor
    public var separator: NSColor
    /// `==highlighted==` text's background.
    public var highlight: NSColor
    public var warning: NSColor
    /// Drawn on top of `accent`, such as a checked checklist's checkmark.
    public var onAccent: NSColor
    /// Inline `code` text.
    public var inlineCodeText: NSColor
    /// Inline `code` background.
    public var inlineCodeBackground: NSColor

    public init(
        text: NSColor,
        secondaryText: NSColor,
        tertiaryText: NSColor,
        quaternaryText: NSColor,
        accent: NSColor,
        link: NSColor,
        separator: NSColor,
        highlight: NSColor,
        warning: NSColor,
        onAccent: NSColor,
        inlineCodeText: NSColor? = nil,
        inlineCodeBackground: NSColor? = nil
    ) {
        self.text = text
        self.secondaryText = secondaryText
        self.tertiaryText = tertiaryText
        self.quaternaryText = quaternaryText
        self.accent = accent
        self.link = link
        self.separator = separator
        self.highlight = highlight
        self.warning = warning
        self.onAccent = onAccent
        self.inlineCodeText = inlineCodeText ?? text
        self.inlineCodeBackground = inlineCodeBackground ?? quaternaryText.withAlphaComponent(0.35)
    }

    public static let system = MarkdownEditorPalette(
        text: .labelColor,
        secondaryText: .secondaryLabelColor,
        tertiaryText: .tertiaryLabelColor,
        quaternaryText: .quaternaryLabelColor,
        accent: .controlAccentColor,
        link: .linkColor,
        separator: .separatorColor,
        highlight: .systemYellow,
        warning: .systemOrange,
        onAccent: .white
    )

    /// `==highlighted==` text's background as drawn: the highlight token, translucent.
    public var highlightBackground: NSColor { highlight.withAlphaComponent(0.24) }
    /// Checked checklist items and other finished text: struck through in this color.
    public var completedText: NSColor { secondaryText }
}

/// Supplies the fonts styled Markdown is set in: proportional for prose, monospaced for
/// code and source presentation.
public protocol MarkdownEditorTypeface {
    func font(ofSize size: CGFloat, trait: NSFontTraitMask?) -> NSFont
    func monospacedFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont
}

public extension MarkdownEditorTypeface {
    func font(ofSize size: CGFloat) -> NSFont {
        font(ofSize: size, trait: nil)
    }

    func monospacedFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}

/// The platform system font.
public struct SystemMarkdownEditorTypeface: MarkdownEditorTypeface {
    public init() {}

    public func font(ofSize size: CGFloat, trait: NSFontTraitMask?) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        guard let trait else { return base }
        return NSFontManager.shared.convert(base, toHaveTrait: trait)
    }
}

/// The surface code blocks, tables and images sit on: their fills, borders, header and
/// gutter text, fonts and radii.
public struct MarkdownSurfaceTheme {
    public var background: NSColor
    public var border: NSColor
    /// A code block's language label.
    public var headerText: NSColor
    public var filePathText: NSColor
    /// Header buttons (copy, pop out).
    public var controlTint: NSColor
    /// "Show N more lines".
    public var toggleText: NSColor
    /// Line numbers.
    public var gutterText: NSColor
    public var tableHeaderBackground: NSColor
    public var tableBodyBackground: NSColor
    public var tableBorder: NSColor
    public var tableRowDivider: NSColor
    public var tableHeaderText: NSColor
    public var tableBodyText: NSColor
    /// An image's loading placeholder.
    public var placeholderBackground: NSColor
    /// The pop-out panel behind a previewed code block or table.
    public var previewBackground: NSColor
    public var codeFont: NSFont
    public var headerFont: NSFont
    public var filePathFont: NSFont
    /// "Show N more lines".
    public var labelFont: NSFont
    /// Image captions.
    public var captionFont: NSFont
    public var cornerRadius: CGFloat
    public var borderWidth: CGFloat
    public var imageCornerRadius: CGFloat
    /// Attaches a tooltip to a header button; hosts with their own tooltips replace it.
    public var installTooltip: (NSView, String) -> Void

    public init(
        background: NSColor,
        border: NSColor,
        headerText: NSColor,
        filePathText: NSColor,
        controlTint: NSColor,
        toggleText: NSColor,
        gutterText: NSColor,
        tableHeaderBackground: NSColor,
        tableBodyBackground: NSColor,
        tableBorder: NSColor,
        tableRowDivider: NSColor,
        tableHeaderText: NSColor,
        tableBodyText: NSColor,
        placeholderBackground: NSColor,
        previewBackground: NSColor,
        codeFont: NSFont,
        headerFont: NSFont,
        filePathFont: NSFont,
        labelFont: NSFont,
        captionFont: NSFont,
        cornerRadius: CGFloat = 8,
        borderWidth: CGFloat = 1,
        imageCornerRadius: CGFloat = 8,
        installTooltip: @escaping (NSView, String) -> Void = { $0.toolTip = $1 }
    ) {
        self.background = background
        self.border = border
        self.headerText = headerText
        self.filePathText = filePathText
        self.controlTint = controlTint
        self.toggleText = toggleText
        self.gutterText = gutterText
        self.tableHeaderBackground = tableHeaderBackground
        self.tableBodyBackground = tableBodyBackground
        self.tableBorder = tableBorder
        self.tableRowDivider = tableRowDivider
        self.tableHeaderText = tableHeaderText
        self.tableBodyText = tableBodyText
        self.placeholderBackground = placeholderBackground
        self.previewBackground = previewBackground
        self.codeFont = codeFont
        self.headerFont = headerFont
        self.filePathFont = filePathFont
        self.labelFont = labelFont
        self.captionFont = captionFont
        self.cornerRadius = cornerRadius
        self.borderWidth = borderWidth
        self.imageCornerRadius = imageCornerRadius
        self.installTooltip = installTooltip
    }

    /// The surface every host gets unless it supplies its own: translucent fills of the
    /// text color, so it reads on any background.
    public static func derived(
        palette: MarkdownEditorPalette,
        typeface: any MarkdownEditorTypeface,
        bodyFontSize: CGFloat
    ) -> MarkdownSurfaceTheme {
        let scale = bodyFontSize / MarkdownVisualSpec.referenceBodySize
        let fill = palette.text.withAlphaComponent(0.055)
        return MarkdownSurfaceTheme(
            background: fill,
            border: palette.separator,
            headerText: palette.secondaryText,
            filePathText: palette.tertiaryText,
            controlTint: palette.secondaryText,
            toggleText: palette.link,
            gutterText: palette.tertiaryText,
            tableHeaderBackground: palette.text.withAlphaComponent(0.06),
            tableBodyBackground: .clear,
            tableBorder: palette.separator,
            tableRowDivider: palette.separator.withAlphaComponent(0.7),
            tableHeaderText: palette.text,
            tableBodyText: palette.text,
            placeholderBackground: fill,
            previewBackground: .textBackgroundColor,
            codeFont: typeface.monospacedFont(ofSize: MarkdownVisualSpec.referenceCodeSize * scale, weight: .regular),
            headerFont: typeface.font(ofSize: 11 * scale, trait: .boldFontMask),
            filePathFont: typeface.font(ofSize: 11 * scale),
            labelFont: typeface.font(ofSize: 12 * scale),
            captionFont: typeface.font(ofSize: 12 * scale)
        )
    }
}

/// Syntax colors for fenced code.
public struct MarkdownSyntaxColors: Equatable {
    public var plain: NSColor
    public var keyword: NSColor
    public var string: NSColor
    public var comment: NSColor
    public var number: NSColor
    public var type: NSColor
    public var function: NSColor
    public var property: NSColor
    public var punctuation: NSColor
    public var `operator`: NSColor

    public init(
        plain: NSColor,
        keyword: NSColor,
        string: NSColor,
        comment: NSColor,
        number: NSColor,
        type: NSColor,
        function: NSColor,
        property: NSColor,
        punctuation: NSColor,
        operator: NSColor
    ) {
        self.plain = plain
        self.keyword = keyword
        self.string = string
        self.comment = comment
        self.number = number
        self.type = type
        self.function = function
        self.property = property
        self.punctuation = punctuation
        self.operator = `operator`
    }

    /// System accent hues for tokens, the palette's text tones for everything else.
    public static func derived(from palette: MarkdownEditorPalette) -> MarkdownSyntaxColors {
        MarkdownSyntaxColors(
            plain: palette.text,
            keyword: .systemPink,
            string: .systemRed,
            comment: palette.tertiaryText,
            number: .systemOrange,
            type: .systemTeal,
            function: .systemBlue,
            property: .systemIndigo,
            punctuation: palette.secondaryText,
            operator: palette.secondaryText
        )
    }
}

/// Everything that decides how Markdown looks on one surface: the shared visual spec
/// (`MarkdownVisualSpec`) set in this theme's colors, fonts and body size.
public struct MarkdownTheme {
    public var palette: MarkdownEditorPalette
    public var typeface: any MarkdownEditorTypeface
    public var bodyFontSize: CGFloat
    public var surface: MarkdownSurfaceTheme
    public var syntax: MarkdownSyntaxColors

    /// A nil `surface` or `syntax` is derived from the palette and typeface.
    public init(
        palette: MarkdownEditorPalette = .system,
        typeface: any MarkdownEditorTypeface = SystemMarkdownEditorTypeface(),
        bodyFontSize: CGFloat = MarkdownVisualSpec.referenceBodySize,
        surface: MarkdownSurfaceTheme? = nil,
        syntax: MarkdownSyntaxColors? = nil
    ) {
        self.palette = palette
        self.typeface = typeface
        self.bodyFontSize = bodyFontSize
        self.surface = surface ?? .derived(palette: palette, typeface: typeface, bodyFontSize: bodyFontSize)
        self.syntax = syntax ?? .derived(from: palette)
    }

    /// Scales a size designed against `MarkdownVisualSpec.referenceBodySize` to this
    /// theme's body size.
    public func scaled(_ referenceSize: CGFloat) -> CGFloat {
        referenceSize * bodyFontSize / MarkdownVisualSpec.referenceBodySize
    }

    public var bodyFont: NSFont {
        typeface.font(ofSize: bodyFontSize)
    }

    /// Inline code, sized to sit in body text.
    public var inlineCodeFont: NSFont {
        typeface.monospacedFont(ofSize: scaled(MarkdownVisualSpec.referenceCodeSize), weight: .regular)
    }

    /// Headings 1–6 on the shared scale, bold.
    public func headingFont(level: Int) -> NSFont {
        typeface.font(ofSize: MarkdownVisualSpec.headingSize(level: level, bodySize: bodyFontSize), trait: .boldFontMask)
    }
}
#endif

#if os(macOS)
public extension MarkdownEditorShortcut.Modifiers {
    /// The shortcut modifiers in AppKit event flags.
    init(_ flags: NSEvent.ModifierFlags) {
        var modifiers: Self = []
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        self = modifiers
    }

    /// The modifiers as AppKit flags, for `NSMenuItem.keyEquivalentModifierMask`.
    var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }
}
#endif
