#if os(macOS)
import AppKit
import ScriblMarkdown

/// A foreground color for a range of a code block's content.
public struct MarkdownCodeColorRun: Equatable {
    public let range: NSRange
    public let color: NSColor

    public init(range: NSRange, color: NSColor) {
        self.range = range
        self.color = color
    }
}

/// Syntax-colors fenced code. The live editor calls it on the main thread on every restyle,
/// so implementations should be fast or cache by input.
public protocol MarkdownCodeHighlighting: AnyObject {
    /// Color runs for `code`, with ranges relative to `code`.
    func colorRuns(forCode code: String, language: String?) -> [MarkdownCodeColorRun]
}

/// Colors `MarkdownCodeTokenizer`'s tokens with a theme's syntax colors. Every code block
/// (display, editors, pop-outs) colors with it.
public final class MarkdownSyntaxHighlighter: MarkdownCodeHighlighting {
    public let colors: MarkdownSyntaxColors

    public init(colors: MarkdownSyntaxColors) {
        self.colors = colors
    }

    /// `code` set in `font` and the plain color, with token colors applied.
    public func highlight(_ code: String, language: String?, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: code, attributes: [
            .font: font,
            .foregroundColor: colors.plain,
        ])
        for run in colorRuns(forCode: code, language: language) {
            result.addAttribute(.foregroundColor, value: run.color, range: run.range)
        }
        return result
    }

    public func colorRuns(forCode code: String, language: String?) -> [MarkdownCodeColorRun] {
        MarkdownCodeTokenizer.tokens(in: code, language: language).map {
            MarkdownCodeColorRun(range: $0.range, color: color(for: $0.kind))
        }
    }

    public func color(for kind: MarkdownCodeToken.Kind) -> NSColor {
        switch kind {
        case .keyword: colors.keyword
        case .string: colors.string
        case .comment: colors.comment
        case .number: colors.number
        case .type: colors.type
        case .function: colors.function
        case .property: colors.property
        case .punctuation: colors.punctuation
        case .operator: colors.operator
        }
    }
}
#endif
