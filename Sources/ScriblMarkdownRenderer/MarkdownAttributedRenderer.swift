#if os(macOS)
import AppKit
import ScriblMarkdown
import ScriblMarkdownUI

/// A piece of a rendered document. Text blocks render into attributed strings; code,
/// tables and images are handed back for the host to show with its own views.
public enum MarkdownRenderedSegment {
    case text(NSAttributedString)
    case codeBlock(code: String, language: String?)
    case table(MarkdownTableContent)
    case image(source: String, alternateText: String)
    /// A paragraph that is only a web address or a document link, for the host to show as
    /// a `MarkdownLinkCardView`.
    case linkCard(MarkdownArtifactKind)
}

/// Renders a `MarkdownDocument` for display: markers removed, styled with a
/// `MarkdownRenderStyle`. Rendering is pure and per block, so callers can cache blocks.
public struct MarkdownAttributedRenderer {
    public var style: MarkdownRenderStyle
    /// Turns a link destination into the URL the link opens.
    public var resolveLink: (String) -> URL?

    public init(style: MarkdownRenderStyle, resolveLink: @escaping (String) -> URL? = { URL(string: $0) }) {
        self.style = style
        self.resolveLink = resolveLink
    }

    // MARK: - Documents

    /// The document as text segments, with code blocks, tables and images split out so
    /// the host can show each with its own view.
    /// Lone links become `.linkCard` segments as `linkCards` allows; see
    /// `MarkdownDocument.sections(linkCards:…)`.
    public func segments(
        for document: MarkdownDocument,
        cache: MarkdownRenderCache? = nil,
        linkCards: MarkdownLinkCardPolicy = .none,
        linkableDocumentExtensions: Set<String> = ["md", "markdown"],
        documentURL: URL? = nil,
        libraryURLs: [URL] = []
    ) -> [MarkdownRenderedSegment] {
        document.sections(
            linkCards: linkCards,
            linkableDocumentExtensions: linkableDocumentExtensions,
            documentURL: documentURL,
            libraryURLs: libraryURLs
        ).enumerated().map { sectionIndex, section in
            switch section {
            case .text(let text):
                return .text(render(text, imageAttachment: nil, cache: cache, scope: sectionIndex + 1))
            case .codeBlock(let code, let language): return .codeBlock(code: code, language: language)
            case .table(let table): return .table(table)
            case .image(let source, let alternateText): return .image(source: source, alternateText: alternateText)
            case .linkCard(let kind): return .linkCard(kind)
            }
        }
    }

    /// Renders table cells in this style, for `MarkdownTableView`: bold headers, the
    /// column's alignment, wrapping.
    public var tableCellRenderer: MarkdownTableView.CellRenderer {
        { text, isHeader, alignment in
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            switch alignment {
            case .leading: paragraph.alignment = .left
            case .center: paragraph.alignment = .center
            case .trailing: paragraph.alignment = .right
            }
            let font = isHeader ? NSFontManager.shared.convert(style.bodyFont, toHaveTrait: .boldFontMask) : style.bodyFont
            return attributedString(
                forInline: text,
                attributes: [
                    .font: font,
                    .foregroundColor: isHeader ? style.headingColor : style.textColor,
                    .paragraphStyle: paragraph,
                ]
            )
        }
    }

    /// The whole document in one attributed string, for a single text view or label:
    /// code blocks become indented monospaced paragraphs, tables tab-aligned rows, and
    /// images whatever `imageAttachment` returns (their alternate text when nil).
    public func attributedString(
        for document: MarkdownDocument,
        imageAttachment: ((_ source: String, _ alternateText: String) -> NSTextAttachment?)? = nil,
        cache: MarkdownRenderCache? = nil
    ) -> NSAttributedString {
        render(document, imageAttachment: imageAttachment, cache: cache, scope: 0)
    }

    private func render(
        _ document: MarkdownDocument,
        imageAttachment: ((_ source: String, _ alternateText: String) -> NSTextAttachment?)?,
        cache: MarkdownRenderCache?,
        scope: Int
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var previous: MarkdownBlock?
        for (index, block) in document.blocks.enumerated() {
            let next = document.blocks.indices.contains(index + 1) ? document.blocks[index + 1] : nil
            if case .image(let source, let alternateText) = block,
               let attachment = imageAttachment?(source, alternateText) {
                appendSeparator(after: previous, to: result)
                let image = NSMutableAttributedString(attachment: attachment)
                image.addAttribute(.paragraphStyle, value: paragraphStyle(spacingAfter: style.blockSpacing), range: NSRange(location: 0, length: image.length))
                result.append(image)
            } else if imageAttachment == nil, let cache {
                appendSeparator(after: previous, to: result)
                if let cached = cache.value(
                    at: index, scope: scope, block: block, previous: previous, next: next,
                    footnoteOrdinals: document.footnoteOrdinals
                ) {
                    result.append(cached)
                } else {
                    let rendered = NSMutableAttributedString()
                    append(block, previous: previous, next: next, document: document, to: rendered)
                    cache.store(
                        rendered, at: index, scope: scope, block: block, previous: previous, next: next,
                        footnoteOrdinals: document.footnoteOrdinals
                    )
                    result.append(rendered)
                }
            } else {
                append(block, previous: previous, next: next, document: document, to: result)
            }
            previous = block
        }
        return result
    }

    // MARK: - Inline

    /// Inline Markdown (no blocks) in the body style, such as a single line of copy.
    public func attributedString(forInline markdown: String) -> NSAttributedString {
        inline(markdown, attributes: baseAttributes(font: style.bodyFont, color: style.textColor), footnoteOrdinals: [:])
    }

    /// Inline Markdown on top of the caller's attributes (font, color, paragraph style),
    /// such as a table cell.
    public func attributedString(
        forInline markdown: String,
        attributes: [NSAttributedString.Key: Any],
        footnoteOrdinals: [String: Int] = [:]
    ) -> NSAttributedString {
        inline(markdown, attributes: attributes, footnoteOrdinals: footnoteOrdinals)
    }

    // MARK: - Blocks

    private func append(
        _ block: MarkdownBlock,
        previous: MarkdownBlock?,
        next: MarkdownBlock?,
        document: MarkdownDocument,
        to result: NSMutableAttributedString
    ) {
        appendSeparator(after: previous, to: result)
        let spacingAfter = spacing(after: block, next: next)
        let ordinals = document.footnoteOrdinals
        let content: NSMutableAttributedString
        let paragraph: NSMutableParagraphStyle

        switch block {
        case .paragraph(let text):
            paragraph = paragraphStyle(spacingAfter: spacingAfter)
            content = inline(paragraphText(text), attributes: baseAttributes(font: style.bodyFont, color: style.textColor), footnoteOrdinals: ordinals)

        case .heading(let level, let text):
            paragraph = paragraphStyle(spacingAfter: spacingAfter)
            if previous != nil { paragraph.paragraphSpacingBefore = style.headingSpacingBefore }
            content = inline(text, attributes: baseAttributes(font: style.headingFont(level: level), color: style.headingColor), footnoteOrdinals: ordinals)

        case .listItem(let item):
            let indent = style.listIndent * CGFloat(item.depth + 1)
            paragraph = paragraphStyle(spacingAfter: spacingAfter)
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            paragraph.defaultTabInterval = style.listIndent
            paragraph.headIndent = indent
            paragraph.firstLineHeadIndent = indent - style.listIndent + style.listMarkerInset
            let markerAttributes = baseAttributes(font: style.bodyFont, color: style.textColor)
            if case .task(let isChecked) = item.marker, let palette = style.markerPalette {
                content = MarkdownMarkerAttachmentCell.string(
                    .checklist(isChecked: isChecked),
                    palette: palette,
                    textFont: style.bodyFont,
                    scale: style.scale,
                    attributes: markerAttributes
                )
                content.append(NSAttributedString(string: "\t", attributes: markerAttributes))
            } else {
                content = NSMutableAttributedString(string: marker(for: item) + "\t", attributes: markerAttributes)
            }
            var itemAttributes = baseAttributes(font: style.bodyFont, color: style.textColor)
            if case .task(true) = item.marker, let completed = style.completedTaskColor {
                itemAttributes[.foregroundColor] = completed
                itemAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            content.append(inline(item.text, attributes: itemAttributes, footnoteOrdinals: ordinals))

        case .quote(let depth, let text):
            let indent = style.quoteIndent * CGFloat(depth)
            paragraph = paragraphStyle(spacingAfter: spacingAfter)
            paragraph.headIndent = indent
            paragraph.firstLineHeadIndent = indent
            var attributes = baseAttributes(font: style.bodyFont, color: style.quoteTextColor)
            if let bar = style.quoteBarColor { attributes[.markdownQuoteBar] = bar }
            // A zero-width space gives an empty quote line something to draw the bar beside.
            content = text.isEmpty
                ? NSMutableAttributedString(string: "\u{200B}", attributes: attributes)
                : inline(text, attributes: attributes, footnoteOrdinals: ordinals)

        case .codeBlock(let code, _):
            paragraph = paragraphStyle(spacingAfter: spacingAfter)
            paragraph.headIndent = style.codeBlockIndent
            paragraph.firstLineHeadIndent = style.codeBlockIndent
            var attributes: [NSAttributedString.Key: Any] = [.font: style.codeFont, .foregroundColor: style.codeColor]
            if let background = style.codeBackgroundColor { attributes[.backgroundColor] = background }
            content = NSMutableAttributedString(string: code, attributes: attributes)

        case .table(let table):
            paragraph = paragraphStyle(spacingAfter: spacingAfter)
            content = tableText(table, ordinals: ordinals, paragraph: paragraph)

        case .image(let source, let alternateText):
            paragraph = paragraphStyle(spacingAfter: spacingAfter)
            content = NSMutableAttributedString(
                string: alternateText.isEmpty ? source : alternateText,
                attributes: baseAttributes(font: style.bodyFont, color: style.mutedColor)
            )

        case .thematicBreak:
            paragraph = paragraphStyle(spacingAfter: spacingAfter)
            if let palette = style.markerPalette {
                // A zero-width line that `MarkdownDecorationLayoutManager` draws the rule across.
                var attributes = baseAttributes(font: style.bodyFont, color: style.mutedColor)
                attributes[.markdownRule] = palette.separator
                content = NSMutableAttributedString(string: "\u{200B}", attributes: attributes)
            } else {
                content = NSMutableAttributedString(
                    string: style.thematicBreakText,
                    attributes: baseAttributes(font: style.bodyFont, color: style.mutedColor)
                )
            }

        case .footnote(_, let ordinal, let text):
            paragraph = paragraphStyle(spacingAfter: spacingAfter)
            if let palette = style.markerPalette {
                // The editor's footnotes: a bold number, smaller secondary text, set apart
                // from the body above.
                let size = MarkdownVisualSpec.referenceFootnoteSize * style.scale
                let font = NSFont(descriptor: style.bodyFont.fontDescriptor, size: size) ?? style.bodyFont
                if case .footnote? = previous {} else { paragraph.paragraphSpacingBefore = 18 * style.scale }
                content = NSMutableAttributedString(
                    string: "\(ordinal)  ",
                    attributes: baseAttributes(font: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), color: palette.secondaryText)
                )
                content.append(inline(text, attributes: baseAttributes(font: font, color: palette.secondaryText), footnoteOrdinals: ordinals))
            } else {
                content = NSMutableAttributedString(
                    string: "\(ordinal). ",
                    attributes: baseAttributes(font: style.bodyFont, color: style.mutedColor)
                )
                content.append(inline(text, attributes: baseAttributes(font: style.bodyFont, color: style.textColor), footnoteOrdinals: ordinals))
            }

        case .details(let summary, let body, _):
            paragraph = paragraphStyle(spacingAfter: spacingAfter)
            let summaryFont = NSFontManager.shared.convert(style.bodyFont, toHaveTrait: .boldFontMask)
            content = NSMutableAttributedString()
            if let palette = style.markerPalette {
                // Display surfaces show the whole body, so the chevron reads as open.
                content.append(MarkdownMarkerAttachmentCell.string(
                    .disclosure(isExpanded: true),
                    palette: palette,
                    textFont: summaryFont,
                    scale: style.scale,
                    attributes: baseAttributes(font: summaryFont, color: style.textColor)
                ))
            }
            content.append(inline(summary, attributes: baseAttributes(font: summaryFont, color: style.textColor), footnoteOrdinals: ordinals))
            let summaryParagraph = paragraphStyle(spacingAfter: style.itemSpacing)
            applyParagraphStyle(summaryParagraph, to: content)
            let bodyText = NSMutableAttributedString(attributedString: attributedString(for: body))
            if bodyText.length > 0 {
                content.append(NSAttributedString(string: "\n", attributes: baseAttributes(font: summaryFont, color: style.textColor)))
                var bodyParagraphs: [(NSRange, NSParagraphStyle?)] = []
                bodyText.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: bodyText.length)) { value, range, _ in
                    bodyParagraphs.append((range, value as? NSParagraphStyle))
                }
                for (range, value) in bodyParagraphs {
                    let indented = (value?.mutableCopy() as? NSMutableParagraphStyle)
                        ?? paragraphStyle(spacingAfter: spacingAfter)
                    indented.headIndent += style.listIndent
                    indented.firstLineHeadIndent += style.listIndent
                    bodyText.addAttribute(.paragraphStyle, value: indented, range: range)
                }
                content.append(bodyText)
            }

        case .math(let expression):
            paragraph = paragraphStyle(spacingAfter: spacingAfter)
            paragraph.alignment = .center
            content = NSMutableAttributedString(
                string: MarkdownMathDisplay.text(for: expression),
                attributes: baseAttributes(font: MarkdownDrawnMarkers.mathFont(ofSize: 20 * style.scale), color: style.textColor)
            )
        }

        if case .details = block {
            result.append(content)
        } else {
            applyParagraphStyle(paragraph, to: content)
            result.append(content)
        }
    }

    /// Ends the previous block's last paragraph. The newline keeps that paragraph's
    /// paragraph-level attributes (spacing, font for line height, quote bar) but not
    /// run styling, so a trailing code span's background doesn't run to the line end.
    private func appendSeparator(after previous: MarkdownBlock?, to result: NSMutableAttributedString) {
        guard previous != nil, result.length > 0 else { return }
        let last = result.attributes(at: result.length - 1, effectiveRange: nil)
        let paragraphKeys: [NSAttributedString.Key] = [.paragraphStyle, .font, .foregroundColor, .markdownQuoteBar]
        let attributes = last.filter { paragraphKeys.contains($0.key) }
        result.append(NSAttributedString(string: "\n", attributes: attributes))
    }

    /// Lines inside a block sit `itemSpacing` apart; the block's last line gets the
    /// spacing that separates it from the next block.
    private func applyParagraphStyle(_ paragraph: NSParagraphStyle, to content: NSMutableAttributedString) {
        let length = content.length
        guard length > 0 else { return }
        let lastLineStart = ((content.string as NSString).range(of: "\n", options: .backwards).location)
        if lastLineStart == NSNotFound {
            content.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: length))
            return
        }
        let inner = (paragraph.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        inner.paragraphSpacing = 0
        let last = (paragraph.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        last.paragraphSpacingBefore = 0
        content.addAttribute(.paragraphStyle, value: inner, range: NSRange(location: 0, length: lastLineStart + 1))
        content.addAttribute(.paragraphStyle, value: last, range: NSRange(location: lastLineStart + 1, length: length - lastLineStart - 1))
    }

    private func spacing(after block: MarkdownBlock, next: MarkdownBlock?) -> CGFloat {
        switch (block, next) {
        case (.listItem, .listItem?), (.quote, .quote?), (.footnote, .footnote?):
            return style.itemSpacing
        default:
            return style.blockSpacing
        }
    }

    private func paragraphStyle(spacingAfter: CGFloat) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.lineSpacing
        paragraph.paragraphSpacing = spacingAfter
        return paragraph
    }

    private func paragraphText(_ text: String) -> String {
        switch style.lineBreaks {
        case .preserved:
            return text
        case .collapsed:
            let lines = text.components(separatedBy: "\n")
            var joined = ""
            for (index, line) in lines.enumerated() {
                guard index < lines.count - 1 else { joined += line; break }
                // Two trailing spaces or a backslash are a hard break.
                if line.hasSuffix("  ") {
                    joined += line.trimmingCharacters(in: .whitespaces) + "\n"
                } else if line.hasSuffix("\\") {
                    joined += String(line.dropLast()) + "\n"
                } else {
                    joined += line + " "
                }
            }
            return joined
        }
    }

    private func marker(for item: MarkdownListItem) -> String {
        switch item.marker {
        case .bullet:
            return style.bulletSymbol(depth: item.depth)
        case .ordered(let number, let label):
            switch style.orderedListLabels {
            case .source: return "\(number)."
            case .hierarchical: return label
            }
        case .task(let isChecked):
            return isChecked ? style.taskSymbols.checked : style.taskSymbols.unchecked
        }
    }

    /// Tab-aligned rows with a bold header, for one-string output.
    private func tableText(
        _ table: MarkdownTableContent,
        ordinals: [String: Int],
        paragraph: NSMutableParagraphStyle
    ) -> NSMutableAttributedString {
        let bodyAttributes = baseAttributes(font: style.bodyFont, color: style.textColor)
        let headerFont = NSFontManager.shared.convert(style.bodyFont, toHaveTrait: .boldFontMask)
        let headerAttributes = baseAttributes(font: headerFont, color: style.headingColor)
        let rows = [table.headers] + table.rows
        let rendered = rows.enumerated().map { rowIndex, row in
            row.map { inline($0, attributes: rowIndex == 0 ? headerAttributes : bodyAttributes, footnoteOrdinals: ordinals) }
        }
        let gap: CGFloat = 16
        var stops: [NSTextTab] = []
        var position: CGFloat = 0
        for column in 0..<max(0, table.columnCount - 1) {
            let width = rendered.map { $0.indices.contains(column) ? ceil($0[column].size().width) : 0 }.max() ?? 0
            position += width + gap
            stops.append(NSTextTab(textAlignment: .left, location: position))
        }
        paragraph.tabStops = stops

        let result = NSMutableAttributedString()
        for (rowIndex, row) in rendered.enumerated() {
            if rowIndex > 0 { result.append(NSAttributedString(string: "\n", attributes: bodyAttributes)) }
            for (column, cell) in row.enumerated() {
                if column > 0 { result.append(NSAttributedString(string: "\t", attributes: bodyAttributes)) }
                result.append(cell)
            }
        }
        return result
    }

    // MARK: - Inline runs

    private func baseAttributes(font: NSFont, color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color]
    }

    private func inline(
        _ markdown: String,
        attributes base: [NSAttributedString.Key: Any],
        footnoteOrdinals: [String: Int]
    ) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let baseFont = (base[.font] as? NSFont) ?? style.bodyFont
        for run in MarkdownInlineParser.runs(in: markdown, footnoteOrdinals: footnoteOrdinals) {
            let runAttributes = attributes(for: run, base: base, baseFont: baseFont)
            if run.isKeycap, let palette = style.markerPalette {
                result.append(MarkdownMarkerAttachmentCell.string(
                    .keycap(run.text, font: style.keycapFont),
                    palette: palette,
                    textFont: baseFont,
                    scale: style.scale,
                    attributes: runAttributes
                ))
            } else {
                result.append(NSAttributedString(string: run.text, attributes: runAttributes))
            }
        }
        return result
    }

    private func attributes(
        for run: MarkdownInlineRun,
        base: [NSAttributedString.Key: Any],
        baseFont: NSFont
    ) -> [NSAttributedString.Key: Any] {
        var attributes = base
        var font = baseFont
        let styles = run.styles

        if styles.contains(.code) {
            // Code keeps its own family but follows the surrounding size, so code in a
            // heading is heading-sized.
            let scale = baseFont.pointSize / max(style.bodyFont.pointSize, 1)
            font = NSFont(descriptor: style.codeFont.fontDescriptor, size: style.codeFont.pointSize * scale) ?? style.codeFont
            attributes[.foregroundColor] = style.codeColor
            if let background = style.codeBackgroundColor { attributes[.backgroundColor] = background }
        }
        if styles.contains(.strong) || styles.contains(.strongEmphasis) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            if let strongColor = style.strongColor { attributes[.foregroundColor] = strongColor }
        }
        if styles.contains(.emphasis) || styles.contains(.strongEmphasis) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        if styles.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if styles.contains(.highlight) {
            attributes[.backgroundColor] = style.highlightColor
        }
        if styles.contains(.subscript) || styles.contains(.superscript) || run.footnoteOrdinal != nil {
            let size = font.pointSize
            font = NSFont(descriptor: font.fontDescriptor, size: size * 0.75) ?? font
            attributes[.baselineOffset] = styles.contains(.subscript) ? -size * 0.2 : size * 0.35
        }
        if run.footnoteOrdinal != nil {
            if let palette = style.markerPalette {
                attributes[.foregroundColor] = palette.accent
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            } else {
                attributes[.foregroundColor] = style.mutedColor
            }
        }
        if run.isMath {
            font = MarkdownDrawnMarkers.mathFont(ofSize: font.pointSize)
        }
        if run.isKeycap, style.markerPalette == nil {
            font = NSFont(descriptor: style.codeFont.fontDescriptor, size: font.pointSize) ?? style.codeFont
        }
        if let destination = run.link {
            attributes[.foregroundColor] = style.linkColor
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            if let url = resolveLink(destination) { attributes[.link] = url }
        }
        attributes[.font] = font
        return attributes
    }
}
#endif
