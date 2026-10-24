import Foundation

/// A list item: its nesting depth, its marker, and its inline Markdown.
public struct MarkdownListItem: Equatable, Sendable {
    public enum Marker: Equatable, Sendable {
        case bullet
        /// `number` is as written in the source; `label` is the hierarchy-aware label the
        /// editor shows ("1.", "a.", "i.").
        case ordered(number: Int, label: String)
        case task(isChecked: Bool)
    }

    public let depth: Int
    public let marker: Marker
    public let text: String

    public init(depth: Int, marker: Marker, text: String) {
        self.depth = depth
        self.marker = marker
        self.text = text
    }
}

public enum MarkdownTableAlignment: Equatable, Sendable {
    case leading
    case center
    case trailing
}

/// A table's cells as inline Markdown. Every row has one cell per column.
public struct MarkdownTableContent: Equatable, Sendable {
    public let headers: [String]
    public let alignments: [MarkdownTableAlignment]
    public let rows: [[String]]

    public init(headers: [String], alignments: [MarkdownTableAlignment], rows: [[String]]) {
        self.headers = headers
        self.alignments = alignments
        self.rows = rows
    }

    public var columnCount: Int { headers.count }
}

/// One block of a Markdown document. Text-bearing cases hold inline Markdown; parse it
/// with `MarkdownInlineParser` (passing the document's `footnoteOrdinals`).
public enum MarkdownBlock: Equatable, Sendable {
    /// Lines of a paragraph, joined by "\n" as written.
    case paragraph(String)
    case heading(level: Int, text: String)
    case listItem(MarkdownListItem)
    case quote(depth: Int, text: String)
    case codeBlock(code: String, language: String?)
    case table(MarkdownTableContent)
    /// An image alone on its line.
    case image(source: String, alternateText: String)
    case thematicBreak
    case footnote(label: String, ordinal: Int, text: String)
}

/// A display section of a `MarkdownDocument`; see `MarkdownDocument.sections`.
public enum MarkdownDocumentSection: Equatable, Sendable {
    case text(MarkdownDocument)
    case codeBlock(code: String, language: String?)
    case table(MarkdownTableContent)
    case image(source: String, alternateText: String)
}

/// Markdown parsed into display blocks with the same parsers the live editor uses, so a
/// document reads the same in Scribl's editor, Addy's views and any other renderer.
///
/// Display semantics: HTML comments are dropped. `<details>` and `$$` math are not given
/// their own blocks yet and read as paragraphs.
public struct MarkdownDocument: Equatable, Sendable {
    public let blocks: [MarkdownBlock]
    /// Footnote labels mapped to their display numbers, for `MarkdownInlineParser`.
    public let footnoteOrdinals: [String: Int]

    public init(blocks: [MarkdownBlock], footnoteOrdinals: [String: Int] = [:]) {
        self.blocks = blocks
        self.footnoteOrdinals = footnoteOrdinals
    }

    public init(parsing markdown: String) {
        self = MarkdownDocumentParser(markdown: markdown).parse()
    }

    /// The document split for display: runs of text blocks, and the code blocks, tables
    /// and images between them, which hosts usually show with their own views. Each text
    /// section is a document of its own, sharing this document's footnote numbers.
    public var sections: [MarkdownDocumentSection] {
        var sections: [MarkdownDocumentSection] = []
        var text: [MarkdownBlock] = []
        func flushText() {
            guard !text.isEmpty else { return }
            sections.append(.text(MarkdownDocument(blocks: text, footnoteOrdinals: footnoteOrdinals)))
            text = []
        }
        for block in blocks {
            switch block {
            case .codeBlock(let code, let language):
                flushText()
                sections.append(.codeBlock(code: code, language: language))
            case .table(let table):
                flushText()
                sections.append(.table(table))
            case .image(let source, let alternateText):
                flushText()
                sections.append(.image(source: source, alternateText: alternateText))
            default:
                text.append(block)
            }
        }
        flushText()
        return sections
    }

    /// The document as plain text, as for speech: markers, link destinations and images
    /// removed, one block per line.
    public func plainText(includingCode: Bool = false) -> String {
        var lines: [String] = []
        for block in blocks {
            switch block {
            case .paragraph(let text), .heading(_, let text), .quote(_, let text):
                lines.append(inlinePlainText(text))
            case .listItem(let item):
                lines.append(inlinePlainText(item.text))
            case .codeBlock(let code, _):
                if includingCode { lines.append(code) }
            case .table(let table):
                for row in [table.headers] + table.rows {
                    lines.append(row.map(inlinePlainText).joined(separator: ", "))
                }
            case .footnote(_, let ordinal, let text):
                lines.append("\(ordinal). " + inlinePlainText(text))
            case .image, .thematicBreak:
                continue
            }
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func inlinePlainText(_ text: String) -> String {
        MarkdownInlineParser.runs(in: text, footnoteOrdinals: footnoteOrdinals)
            .filter { !$0.styles.contains(.code) }
            .map(\.text)
            .joined()
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Builds a `MarkdownDocument`: claims code blocks, tables and footnote definitions with
/// the shared block parsers, then classifies the remaining lines.
private struct MarkdownDocumentParser {
    private static let commentPattern = try! NSRegularExpression(pattern: #"<!--[\s\S]*?-->"#)
    private static let headingPattern = try! NSRegularExpression(pattern: #"^[ \t]{0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t]*#*[ \t]*$"#)
    private static let quotePattern = try! NSRegularExpression(pattern: #"^[ \t]{0,3}((?:>[ \t]?)+)(.*)$"#)
    private static let bulletPattern = try! NSRegularExpression(pattern: #"^([ \t]*)[-*+][ \t]+(.*)$"#)

    private let source: NSString

    init(markdown: String) {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let withoutComments = Self.commentPattern.stringByReplacingMatches(
            in: normalized,
            range: NSRange(location: 0, length: (normalized as NSString).length),
            withTemplate: ""
        )
        source = withoutComments as NSString
    }

    func parse() -> MarkdownDocument {
        let text = source as String
        let codeBlocks = MarkdownCodeBlock.blocks(in: text)
        let codeRanges = codeBlocks.map(\.sourceRange)
        let tables = MarkdownTable.tables(in: text, excluding: codeRanges)
        let footnotes = MarkdownFootnotePresentation.parse(in: text, excluding: codeRanges)

        // Claimed blocks, keyed by where they start.
        var claims: [Int: (block: MarkdownBlock, end: Int)] = [:]
        for block in codeBlocks {
            claims[block.sourceRange.location] = (codeBlock(block), NSMaxRange(block.sourceRange))
        }
        for table in tables {
            claims[table.sourceRange.location] = (.table(tableContent(table)), NSMaxRange(table.sourceRange))
        }
        var footnoteOrdinals: [String: Int] = [:]
        for definition in footnotes.definitions {
            footnoteOrdinals[definition.label] = definition.ordinal
            claims[definition.lineRange.location] = (
                .footnote(
                    label: definition.label,
                    ordinal: definition.ordinal,
                    text: source.substring(with: definition.contentRange)
                ),
                NSMaxRange(definition.lineRange)
            )
        }
        let orderedItems = Dictionary(
            MarkdownOrderedListItem.items(in: text).map { ($0.markerRange.location, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let checklistItems = Dictionary(
            MarkdownChecklistItem.items(in: text).map { ($0.indentationRange.location, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        var location = 0
        while location < source.length {
            if let claim = claims[location] {
                flushParagraph()
                blocks.append(claim.block)
                location = claim.end
                continue
            }
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let line = source.substring(with: lineRange).trimmingCharacters(in: .newlines)
            location = NSMaxRange(lineRange)

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
            } else if let heading = heading(in: line) {
                flushParagraph()
                blocks.append(heading)
            } else if MarkdownInlineSyntax.isThematicBreak(line) {
                flushParagraph()
                blocks.append(.thematicBreak)
            } else if let image = standaloneImage(in: line) {
                flushParagraph()
                blocks.append(image)
            } else if let quote = quote(in: line) {
                flushParagraph()
                blocks.append(quote)
            } else if let item = checklistItems[lineRange.location] {
                flushParagraph()
                blocks.append(.listItem(MarkdownListItem(
                    depth: depth(ofIndentation: source.substring(with: item.indentationRange)),
                    marker: .task(isChecked: item.isChecked),
                    text: source.substring(with: item.contentRange)
                )))
            } else if let item = orderedItems[lineRange.location] {
                flushParagraph()
                blocks.append(.listItem(MarkdownListItem(
                    depth: item.indentationLevel,
                    marker: .ordered(number: item.rawNumber, label: item.displayLabel),
                    text: source.substring(with: item.contentRange)
                )))
            } else if let bullet = bullet(in: line) {
                flushParagraph()
                blocks.append(bullet)
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        return MarkdownDocument(blocks: blocks, footnoteOrdinals: footnoteOrdinals)
    }

    private func codeBlock(_ block: MarkdownCodeBlock) -> MarkdownBlock {
        var code = source.substring(with: block.contentRange)
        if code.hasSuffix("\n") { code.removeLast() }
        let language = block.openingRange.flatMap { range -> String? in
            let info = source.substring(with: range)
                .trimmingCharacters(in: CharacterSet(charactersIn: "`~").union(.whitespacesAndNewlines))
            return info.split(whereSeparator: \.isWhitespace).first.map(String.init)
        }
        return .codeBlock(code: code, language: language)
    }

    private func tableContent(_ table: MarkdownTable) -> MarkdownTableContent {
        func cells(_ row: MarkdownTable.Row) -> [String] {
            row.cells.map { source.substring(with: $0).replacingOccurrences(of: "\\|", with: "|") }
        }
        let headers = cells(table.header)
        let delimiterCells = source.substring(with: table.delimiterRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let alignments = headers.indices.map { index -> MarkdownTableAlignment in
            guard index < delimiterCells.count else { return .leading }
            let cell = delimiterCells[index]
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): return .center
            case (false, true): return .trailing
            default: return .leading
            }
        }
        return MarkdownTableContent(headers: headers, alignments: alignments, rows: table.rows.map(cells))
    }

    private func heading(in line: String) -> MarkdownBlock? {
        let range = NSRange(location: 0, length: (line as NSString).length)
        guard let match = Self.headingPattern.firstMatch(in: line, range: range) else { return nil }
        let text = match.range(at: 2).location == NSNotFound ? "" : (line as NSString).substring(with: match.range(at: 2))
        return .heading(level: match.range(at: 1).length, text: text)
    }

    private func standaloneImage(in line: String) -> MarkdownBlock? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let reference = MarkdownImageReference.references(in: trimmed).first,
              reference.range == NSRange(location: 0, length: (trimmed as NSString).length) else { return nil }
        return .image(source: reference.destination, alternateText: reference.alternateText)
    }

    private func quote(in line: String) -> MarkdownBlock? {
        let nsLine = line as NSString
        guard let match = Self.quotePattern.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) else {
            return nil
        }
        let depth = nsLine.substring(with: match.range(at: 1)).filter { $0 == ">" }.count
        return .quote(depth: depth, text: nsLine.substring(with: match.range(at: 2)))
    }

    private func bullet(in line: String) -> MarkdownBlock? {
        let nsLine = line as NSString
        guard let match = Self.bulletPattern.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) else {
            return nil
        }
        return .listItem(MarkdownListItem(
            depth: depth(ofIndentation: nsLine.substring(with: match.range(at: 1))),
            marker: .bullet,
            text: nsLine.substring(with: match.range(at: 2))
        ))
    }

    /// The editor's nesting rule: any indentation up to four columns is one level deeper.
    private func depth(ofIndentation indentation: String) -> Int {
        let columns = indentation.reduce(into: 0) { columns, character in
            columns += character == "\t" ? 4 - (columns % 4) : 1
        }
        return columns == 0 ? 0 : (columns + 3) / 4
    }
}
