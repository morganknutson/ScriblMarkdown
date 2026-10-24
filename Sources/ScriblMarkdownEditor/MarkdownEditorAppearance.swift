import AppKit

/// The colors the editor draws with. `.system` follows AppKit's semantic colors;
/// hosts with their own theme supply resolved colors and reapply on theme change.
public struct MarkdownEditorPalette: Equatable {
    public var text: NSColor
    public var secondaryText: NSColor
    public var tertiaryText: NSColor
    public var quaternaryText: NSColor
    public var accent: NSColor
    public var link: NSColor
    public var separator: NSColor
    public var highlight: NSColor
    public var warning: NSColor
    /// Drawn on top of `accent`, such as a checked checklist's checkmark.
    public var onAccent: NSColor

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
        onAccent: NSColor
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
}

/// Supplies the proportional fonts styled Markdown is set in.
public protocol MarkdownEditorTypeface {
    func font(ofSize size: CGFloat, trait: NSFontTraitMask?) -> NSFont
}

public extension MarkdownEditorTypeface {
    func font(ofSize size: CGFloat) -> NSFont {
        font(ofSize: size, trait: nil)
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

/// Everything that decides how the editor looks.
public struct MarkdownEditorStyle {
    /// The body size every other size is designed against; `bodyFontSize` scales them all.
    public static let referenceBodyFontSize: CGFloat = 17

    public var palette: MarkdownEditorPalette
    public var typeface: any MarkdownEditorTypeface
    public var bodyFontSize: CGFloat
    public var textContainerInset: NSSize

    public init(
        palette: MarkdownEditorPalette = .system,
        typeface: any MarkdownEditorTypeface = SystemMarkdownEditorTypeface(),
        bodyFontSize: CGFloat = MarkdownEditorStyle.referenceBodyFontSize,
        textContainerInset: NSSize = NSSize(width: 28, height: 22)
    ) {
        self.palette = palette
        self.typeface = typeface
        self.bodyFontSize = bodyFontSize
        self.textContainerInset = textContainerInset
    }

    /// Scales a size designed against `referenceBodyFontSize` to the configured body size.
    public func scaled(_ referenceSize: CGFloat) -> CGFloat {
        referenceSize * bodyFontSize / Self.referenceBodyFontSize
    }
}
