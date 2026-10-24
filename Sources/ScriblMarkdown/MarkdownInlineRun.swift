import Foundation

/// A stretch of inline Markdown with its markers removed: the visible text and how it is
/// styled. Platform renderers map runs to attributes; plain-text output joins their text.
public struct MarkdownInlineRun: Equatable, Sendable {
    public let text: String
    /// Emphasis, code and the other inline styles covering this text.
    public let styles: Set<MarkdownInlineSpan.Style>
    /// The destination of the link this text is the label of.
    public let link: String?
    /// Set for a footnote reference, whose text is the footnote's number.
    public let footnoteOrdinal: Int?

    public init(
        text: String,
        styles: Set<MarkdownInlineSpan.Style> = [],
        link: String? = nil,
        footnoteOrdinal: Int? = nil
    ) {
        self.text = text
        self.styles = styles
        self.link = link
        self.footnoteOrdinal = footnoteOrdinal
    }
}

/// Splits inline Markdown into `MarkdownInlineRun`s with the shared grammar
/// (`MarkdownInlineSyntax`, `MarkdownLinkPresentation`).
public enum MarkdownInlineParser {
    private static let footnoteReferencePattern = try! NSRegularExpression(pattern: #"\[\^([^\]\s]+)\]"#)
    private static let inlineImagePattern = try! NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\(([^)\n]+)\)"#)

    /// `footnoteOrdinals` numbers `[^label]` references; unknown labels stay literal.
    public static func runs(in text: String, footnoteOrdinals: [String: Int] = [:]) -> [MarkdownInlineRun] {
        let source = text as NSString
        let length = source.length
        guard length > 0 else { return [] }
        let fullRange = NSRange(location: 0, length: length)

        // Per UTF-16 unit: hidden (a marker), replaced (first unit of an escape/entity),
        // styles, link and footnote ordinal. Runs are then cut wherever these change.
        var hidden = [Bool](repeating: false, count: length)
        var replacement = [String?](repeating: nil, count: length)
        var styles = [Set<MarkdownInlineSpan.Style>](repeating: [], count: length)
        var links = [String?](repeating: nil, count: length)
        var footnotes = [Int?](repeating: nil, count: length)

        func hide(_ range: NSRange) {
            for index in range.location..<NSMaxRange(range) { hidden[index] = true }
        }

        // Code spans are literal: nothing else applies inside them.
        let codeSpans = MarkdownInlineSyntax.codeSpans(in: text)
        for span in codeSpans {
            span.markerRanges.forEach(hide)
            for index in span.contentRange.location..<NSMaxRange(span.contentRange) {
                styles[index].insert(.code)
            }
        }
        var literalRanges = codeSpans.map(\.range)

        // Inline images have no text to show inline; their alternate text stands in.
        for match in inlineImagePattern.matches(in: text, range: fullRange)
        where !intersects(match.range, literalRanges) {
            let alt = match.range(at: 1)
            hide(NSRange(location: match.range.location, length: alt.location - match.range.location))
            hide(NSRange(location: NSMaxRange(alt), length: NSMaxRange(match.range) - NSMaxRange(alt)))
            literalRanges.append(NSRange(location: NSMaxRange(alt), length: NSMaxRange(match.range) - NSMaxRange(alt)))
        }

        for match in footnoteReferencePattern.matches(in: text, range: fullRange)
        where !intersects(match.range, literalRanges) {
            let label = source.substring(with: match.range(at: 1))
            guard let ordinal = footnoteOrdinals[label] else { continue }
            hide(match.range)
            replacement[match.range.location] = String(ordinal)
            footnotes[match.range.location] = ordinal
            literalRanges.append(match.range)
        }

        let linkPresentation = MarkdownLinkPresentation.parse(in: text, excluding: literalRanges)
        for range in linkPresentation.definitionRanges { hide(range) }
        for link in linkPresentation.links {
            link.markerRanges.forEach(hide)
            for index in link.labelRange.location..<NSMaxRange(link.labelRange) {
                links[index] = link.destination
            }
        }
        // A link's destination is not prose: keep emphasis from matching inside URLs.
        let emphasisExclusions = literalRanges
            + linkPresentation.links.flatMap(\.markerRanges)
            + linkPresentation.definitionRanges

        for span in MarkdownInlineSyntax.emphasisSpans(in: text, excluding: emphasisExclusions) {
            span.markerRanges.forEach(hide)
            for index in span.contentRange.location..<NSMaxRange(span.contentRange) {
                styles[index].insert(span.style)
            }
        }

        for item in MarkdownInlineSyntax.replacements(in: text, excluding: literalRanges) {
            hide(item.range)
            replacement[item.range.location] = item.replacement
        }

        var runs: [MarkdownInlineRun] = []
        var buffer = ""
        var currentStyles: Set<MarkdownInlineSpan.Style> = []
        var currentLink: String?
        var currentFootnote: Int?
        func flush() {
            guard !buffer.isEmpty else { return }
            runs.append(MarkdownInlineRun(text: buffer, styles: currentStyles, link: currentLink, footnoteOrdinal: currentFootnote))
            buffer = ""
        }

        var index = 0
        while index < length {
            let visibleText: String?
            var advance = 1
            if let replaced = replacement[index] {
                visibleText = replaced
            } else if hidden[index] {
                visibleText = nil
            } else {
                // Keep surrogate pairs together.
                let composed = source.rangeOfComposedCharacterSequence(at: index)
                advance = composed.length
                visibleText = source.substring(with: composed)
            }
            if let visibleText {
                if styles[index] != currentStyles || links[index] != currentLink || footnotes[index] != currentFootnote {
                    flush()
                    currentStyles = styles[index]
                    currentLink = links[index]
                    currentFootnote = footnotes[index]
                }
                buffer += visibleText
            }
            index += advance
        }
        flush()
        return runs
    }

    /// The visible text of inline Markdown, markers removed.
    public static func plainText(of text: String, footnoteOrdinals: [String: Int] = [:]) -> String {
        runs(in: text, footnoteOrdinals: footnoteOrdinals).map(\.text).joined()
    }

    private static func intersects(_ range: NSRange, _ ranges: [NSRange]) -> Bool {
        ranges.contains { NSIntersectionRange(range, $0).length > 0 }
    }
}
