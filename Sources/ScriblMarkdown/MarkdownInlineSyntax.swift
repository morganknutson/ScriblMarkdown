import Foundation

/// An inline construct whose content sits between two markers, such as `**bold**`.
public struct MarkdownInlineSpan: Equatable, Sendable {
    public enum Style: Equatable, Sendable, CaseIterable {
        case strongEmphasis
        case strong
        case emphasis
        case strikethrough
        case highlight
        case `subscript`
        case superscript
        case code
    }

    public let style: Style
    /// The whole construct, markers included.
    public let range: NSRange
    /// The text between the markers.
    public let contentRange: NSRange

    public init(style: Style, range: NSRange, contentRange: NSRange) {
        self.style = style
        self.range = range
        self.contentRange = contentRange
    }

    /// The opening and closing markers.
    public var markerRanges: [NSRange] {
        [
            NSRange(location: range.location, length: contentRange.location - range.location),
            NSRange(location: NSMaxRange(contentRange), length: NSMaxRange(range) - NSMaxRange(contentRange))
        ]
    }
}

/// A backslash escape (`\*`) or an HTML entity (`&amp;`) and the text it stands for.
public struct MarkdownInlineReplacement: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case escape
        case entity
    }

    public let kind: Kind
    public let range: NSRange
    public let replacement: String

    public init(kind: Kind, range: NSRange, replacement: String) {
        self.kind = kind
        self.range = range
        self.replacement = replacement
    }
}

/// The inline Markdown grammar shared by the live editor and every renderer, so a
/// construct styles the same way wherever it is shown.
public enum MarkdownInlineSyntax {
    /// Emphasis-family patterns in the order they must be applied: triple markers before
    /// double before single, so `***x***` is not read as `**` around `*x*`.
    private static let emphasisPatterns: [(MarkdownInlineSpan.Style, NSRegularExpression)] = ([
        (.strongEmphasis, #"(?<![\\*])\*\*\*(?!\*)(?=\S)(.+?)(?<=\S)(?<!\*)\*\*\*(?!\*)"#),
        (.strongEmphasis, #"(?<![\\_\p{L}\p{N}])___(?!_)(?=\S)(.+?)(?<=\S)(?<!_)___(?![_\p{L}\p{N}])"#),
        (.strong, #"(?<![\\*])\*\*(?!\*)(?=\S)(.+?)(?<=\S)(?<!\*)\*\*(?!\*)"#),
        (.strong, #"(?<![\\_\p{L}\p{N}])__(?!_)(?=\S)(.+?)(?<=\S)(?<!_)__(?![_\p{L}\p{N}])"#),
        (.emphasis, #"(?<![\\*])\*(?!\*)(?=\S)(.+?)(?<=\S)(?<!\*)\*(?!\*)"#),
        (.emphasis, #"(?<![\\_\p{L}\p{N}])_(?!_)(?=\S)(.+?)(?<=\S)(?<!_)_(?![_\p{L}\p{N}])"#),
        (.strikethrough, #"(?<![\\~])~~(?!~)(?=\S)(.+?)(?<=\S)(?<!~)~~(?!~)"#),
        (.highlight, #"(?<![\\=])==(?!\=)(?=\S)(.+?)(?<=\S)(?<!\=)==(?!\=)"#),
        (.subscript, #"(?<![\\~])~(?!~)([^~\s\r\n]+)(?<!~)~(?!~)"#),
        (.superscript, #"(?<![\\^])\^([^\^\s\[\]\r\n]+)\^(?!\^)"#),
    ] as [(MarkdownInlineSpan.Style, String)]).map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    private static let codePattern = try! NSRegularExpression(pattern: #"`([^`\n]+)`"#)
    private static let escapePattern = try! NSRegularExpression(
        pattern: #"\\([\\`*{}\[\]()#+\-.!_|>~^=&])"#
    )
    private static let entityPattern = try! NSRegularExpression(
        pattern: #"&(?:[A-Za-z][A-Za-z0-9]+|#[0-9]+|#[xX][0-9A-Fa-f]+);"#
    )
    private static let thematicBreakPattern = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]{0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$"#
    )

    /// Emphasis, strikethrough, highlight, subscript and superscript spans, in application
    /// order. Spans may nest (`**bold *and italic***`); apply them in sequence.
    public static func emphasisSpans(in text: String, excluding excludedRanges: [NSRange] = []) -> [MarkdownInlineSpan] {
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        return emphasisPatterns.flatMap { style, expression in
            expression.matches(in: text, range: fullRange)
                .filter { !intersects($0.range, excludedRanges) }
                .map { MarkdownInlineSpan(style: style, range: $0.range, contentRange: $0.range(at: 1)) }
        }
    }

    /// Single-backtick code spans. Their content is literal, so callers exclude these
    /// ranges from every other inline construct.
    public static func codeSpans(in text: String, excluding excludedRanges: [NSRange] = []) -> [MarkdownInlineSpan] {
        codePattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            .filter { !intersects($0.range, excludedRanges) }
            .map { MarkdownInlineSpan(style: .code, range: $0.range, contentRange: $0.range(at: 1)) }
    }

    /// Backslash escapes and decodable HTML entities, in source order.
    public static func replacements(in text: String, excluding excludedRanges: [NSRange] = []) -> [MarkdownInlineReplacement] {
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let escapes = escapePattern.matches(in: text, range: fullRange)
            .filter { !intersects($0.range, excludedRanges) }
            .map { MarkdownInlineReplacement(kind: .escape, range: $0.range, replacement: source.substring(with: $0.range(at: 1))) }
        let entities = entityPattern.matches(in: text, range: fullRange)
            .filter { !intersects($0.range, excludedRanges) }
            .compactMap { match -> MarkdownInlineReplacement? in
                guard let value = MarkdownEntityDecoder.value(for: source.substring(with: match.range)) else { return nil }
                return MarkdownInlineReplacement(kind: .entity, range: match.range, replacement: value)
            }
        return (escapes + entities).sorted { $0.range.location < $1.range.location }
    }

    /// Lines that are thematic breaks (`---`, `***`, `___`).
    public static func thematicBreakRanges(in text: String, excluding excludedRanges: [NSRange] = []) -> [NSRange] {
        thematicBreakPattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            .map(\.range)
            .filter { !intersects($0, excludedRanges) }
    }

    /// Whether a single line is a thematic break.
    public static func isThematicBreak(_ line: String) -> Bool {
        let range = NSRange(location: 0, length: (line as NSString).length)
        return thematicBreakPattern.firstMatch(in: line, range: range).map { $0.range == range } ?? false
    }

    private static func intersects(_ range: NSRange, _ excludedRanges: [NSRange]) -> Bool {
        excludedRanges.contains { NSIntersectionRange(range, $0).length > 0 }
    }
}
