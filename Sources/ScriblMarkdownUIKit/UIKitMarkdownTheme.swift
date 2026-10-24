#if canImport(UIKit)
import ScriblMarkdown
import UIKit

/// UIKit values supplied by a host for Markdown editing and block previews.
/// Semantic system colors in `.system` continue to follow the current appearance.
public struct UIKitMarkdownTheme {
    public var inlineCodeBackground: UIColor
    public var highlightBackground: UIColor
    public var codeBlockBackground: UIColor
    public var codeBlockBorder: UIColor
    public var tableHeaderBackground: UIColor
    public var tableBorder: UIColor
    public var quoteBar: UIColor
    public var syntaxKeyword: UIColor
    public var syntaxString: UIColor
    public var syntaxComment: UIColor
    public var syntaxNumber: UIColor
    public var syntaxType: UIColor
    public var syntaxFunction: UIColor
    public var syntaxProperty: UIColor
    public var syntaxPunctuation: UIColor
    public var syntaxOperator: UIColor
    public var text: UIColor
    public var secondaryText: UIColor
    public var tertiaryText: UIColor
    public var link: UIColor
    public var accent: UIColor
    public var separator: UIColor
    public var onAccent: UIColor
    public var keycapBackground: UIColor
    public var keycapBorder: UIColor
    public var footnoteRule: UIColor
    public var previewBackground: UIColor
    public var codeFont: UIFont
    public var headerFont: UIFont
    public var tableFont: UIFont
    public var tableHeaderFont: UIFont
    public var cornerRadius: CGFloat
    public var imageCornerRadius: CGFloat
    public var borderWidth: CGFloat

    public init(
        inlineCodeBackground: UIColor,
        highlightBackground: UIColor,
        codeBlockBackground: UIColor,
        codeBlockBorder: UIColor,
        tableHeaderBackground: UIColor,
        tableBorder: UIColor,
        quoteBar: UIColor,
        syntaxKeyword: UIColor,
        syntaxString: UIColor,
        syntaxComment: UIColor,
        syntaxNumber: UIColor,
        syntaxType: UIColor,
        syntaxFunction: UIColor,
        syntaxProperty: UIColor,
        syntaxPunctuation: UIColor,
        syntaxOperator: UIColor,
        text: UIColor = .label,
        secondaryText: UIColor = .secondaryLabel,
        tertiaryText: UIColor = .tertiaryLabel,
        link: UIColor = .link,
        accent: UIColor = .tintColor,
        separator: UIColor = .separator,
        onAccent: UIColor = .white,
        keycapBackground: UIColor = UIColor.label.withAlphaComponent(0.10),
        keycapBorder: UIColor = UIColor.separator.withAlphaComponent(0.72),
        footnoteRule: UIColor = UIColor.separator.withAlphaComponent(0.65),
        previewBackground: UIColor = .systemBackground,
        codeFont: UIFont = .monospacedSystemFont(ofSize: MarkdownVisualSpec.referenceCodeSize, weight: .regular),
        headerFont: UIFont = .systemFont(ofSize: 11, weight: .medium),
        tableFont: UIFont = .systemFont(ofSize: 14),
        tableHeaderFont: UIFont = .systemFont(ofSize: 14, weight: .semibold),
        cornerRadius: CGFloat = 8,
        imageCornerRadius: CGFloat = 10,
        borderWidth: CGFloat = 1
    ) {
        self.inlineCodeBackground = inlineCodeBackground
        self.highlightBackground = highlightBackground
        self.codeBlockBackground = codeBlockBackground
        self.codeBlockBorder = codeBlockBorder
        self.tableHeaderBackground = tableHeaderBackground
        self.tableBorder = tableBorder
        self.quoteBar = quoteBar
        self.syntaxKeyword = syntaxKeyword
        self.syntaxString = syntaxString
        self.syntaxComment = syntaxComment
        self.syntaxNumber = syntaxNumber
        self.syntaxType = syntaxType
        self.syntaxFunction = syntaxFunction
        self.syntaxProperty = syntaxProperty
        self.syntaxPunctuation = syntaxPunctuation
        self.syntaxOperator = syntaxOperator
        self.text = text
        self.secondaryText = secondaryText
        self.tertiaryText = tertiaryText
        self.link = link
        self.accent = accent
        self.separator = separator
        self.onAccent = onAccent
        self.keycapBackground = keycapBackground
        self.keycapBorder = keycapBorder
        self.footnoteRule = footnoteRule
        self.previewBackground = previewBackground
        self.codeFont = codeFont
        self.headerFont = headerFont
        self.tableFont = tableFont
        self.tableHeaderFont = tableHeaderFont
        self.cornerRadius = cornerRadius
        self.imageCornerRadius = imageCornerRadius
        self.borderWidth = borderWidth
    }

    public func color(for kind: MarkdownCodeToken.Kind) -> UIColor {
        switch kind {
        case .keyword: syntaxKeyword
        case .string: syntaxString
        case .comment: syntaxComment
        case .number: syntaxNumber
        case .type: syntaxType
        case .function: syntaxFunction
        case .property: syntaxProperty
        case .punctuation: syntaxPunctuation
        case .operator: syntaxOperator
        }
    }

    public static let system = UIKitMarkdownTheme(
        inlineCodeBackground: UIColor.label.withAlphaComponent(0.07),
        highlightBackground: UIColor.systemYellow.withAlphaComponent(0.24),
        codeBlockBackground: .secondarySystemBackground,
        codeBlockBorder: .separator,
        tableHeaderBackground: .tertiarySystemFill,
        tableBorder: .separator,
        quoteBar: UIColor.tintColor.withAlphaComponent(0.65),
        syntaxKeyword: .systemPurple,
        syntaxString: .systemRed,
        syntaxComment: .secondaryLabel,
        syntaxNumber: .systemOrange,
        syntaxType: .systemTeal,
        syntaxFunction: .systemBlue,
        syntaxProperty: .systemIndigo,
        syntaxPunctuation: .secondaryLabel,
        syntaxOperator: .systemPink
    )
}
#endif
