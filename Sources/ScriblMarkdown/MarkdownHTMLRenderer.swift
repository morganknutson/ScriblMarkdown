import Foundation

/// Renders a `MarkdownDocument` as clean, semantic HTML, such as for pasting into rich
/// text editors. Platform-neutral.
public struct MarkdownHTMLRenderer {
    public init() {}

    public func html(for document: MarkdownDocument) -> String {
        var html = ""
        var openLists: [String] = []          // "ul"/"ol" per open depth
        var quoteDepth = 0
        var footnotes: [(ordinal: Int, text: String)] = []

        func closeLists(toDepth depth: Int) {
            while openLists.count > depth {
                html += "</li></\(openLists.removeLast())>\n"
            }
        }
        func closeQuotes(toDepth depth: Int) {
            while quoteDepth > depth {
                html += "</blockquote>\n"
                quoteDepth -= 1
            }
        }

        for block in document.blocks {
            if case .listItem = block {} else { closeLists(toDepth: 0) }
            if case .quote = block {} else { closeQuotes(toDepth: 0) }

            switch block {
            case .paragraph(let text):
                html += "<p>\(inline(text, document).replacingOccurrences(of: "\n", with: "<br>\n"))</p>\n"
            case .heading(let level, let text):
                html += "<h\(level)>\(inline(text, document))</h\(level)>\n"
            case .listItem(let item):
                // `openLists` holds one open list (each with an open <li>) per depth.
                let tag: String
                if case .ordered = item.marker { tag = "ol" } else { tag = "ul" }
                let depth = item.depth + 1
                closeLists(toDepth: depth)
                if openLists.count == depth {
                    if openLists[depth - 1] == tag {
                        html += "</li>\n"
                    } else {
                        closeLists(toDepth: depth - 1)
                    }
                }
                while openLists.count < depth {
                    // Levels skipped by over-indentation open as plain lists.
                    let levelTag = openLists.count == depth - 1 ? tag : "ul"
                    if levelTag == "ol", case .ordered(let number, _) = item.marker, number != 1 {
                        html += "<ol start=\"\(number)\">\n"
                    } else {
                        html += "<\(levelTag)>\n"
                    }
                    openLists.append(levelTag)
                }
                var content = inline(item.text, document)
                if case .task(let isChecked) = item.marker {
                    content = "<input type=\"checkbox\" disabled\(isChecked ? " checked" : "")> " + content
                }
                html += "<li>\(content)"
            case .quote(let depth, let text):
                closeQuotes(toDepth: depth)
                while quoteDepth < depth {
                    html += "<blockquote>\n"
                    quoteDepth += 1
                }
                html += "<p>\(inline(text, document))</p>\n"
            case .codeBlock(let code, let language):
                let languageClass = language.map { " class=\"language-\(escape($0))\"" } ?? ""
                html += "<pre><code\(languageClass)>\(escape(code))</code></pre>\n"
            case .table(let table):
                html += tableHTML(table, document)
            case .image(let source, let alternateText):
                html += "<p><img src=\"\(escape(source))\" alt=\"\(escape(alternateText))\"></p>\n"
            case .thematicBreak:
                html += "<hr>\n"
            case .footnote(_, let ordinal, let text):
                footnotes.append((ordinal, text))
            case .details(let summary, let body, let isExpanded):
                html += "<details\(isExpanded ? " open" : "")><summary>\(inline(summary, document))</summary>\n"
                html += self.html(for: body)
                html += "</details>\n"
            case .math(let source):
                html += "<div class=\"math\">\(escape(source))</div>\n"
            }
        }
        closeLists(toDepth: 0)
        closeQuotes(toDepth: 0)

        if !footnotes.isEmpty {
            html += "<section class=\"footnotes\">\n<ol>\n"
            for footnote in footnotes.sorted(by: { $0.ordinal < $1.ordinal }) {
                html += "<li id=\"fn\(footnote.ordinal)\">\(inline(footnote.text, document))</li>\n"
            }
            html += "</ol>\n</section>\n"
        }
        return html
    }

    private func tableHTML(_ table: MarkdownTableContent, _ document: MarkdownDocument) -> String {
        func cell(_ tag: String, _ text: String, _ column: Int) -> String {
            let alignment = table.alignments.indices.contains(column) ? table.alignments[column] : .leading
            let style: String
            switch alignment {
            case .leading: style = ""
            case .center: style = " style=\"text-align: center\""
            case .trailing: style = " style=\"text-align: right\""
            }
            return "<\(tag)\(style)>\(inline(text, document))</\(tag)>"
        }
        var html = "<table>\n<thead>\n<tr>"
        html += table.headers.enumerated().map { cell("th", $1, $0) }.joined()
        html += "</tr>\n</thead>\n<tbody>\n"
        for row in table.rows {
            html += "<tr>" + row.enumerated().map { cell("td", $1, $0) }.joined() + "</tr>\n"
        }
        return html + "</tbody>\n</table>\n"
    }

    private func inline(_ text: String, _ document: MarkdownDocument) -> String {
        MarkdownInlineParser.runs(in: text, footnoteOrdinals: document.footnoteOrdinals).map { run in
            if let ordinal = run.footnoteOrdinal {
                return "<sup><a href=\"#fn\(ordinal)\">\(ordinal)</a></sup>"
            }
            var html = escape(run.text)
            let tags: [(MarkdownInlineSpan.Style, String)] = [
                (.code, "code"), (.strikethrough, "del"), (.highlight, "mark"),
                (.subscript, "sub"), (.superscript, "sup"), (.emphasis, "em"), (.strong, "strong"),
            ]
            for (style, tag) in tags where run.styles.contains(style) {
                html = "<\(tag)>\(html)</\(tag)>"
            }
            if run.styles.contains(.strongEmphasis) {
                html = "<strong><em>\(html)</em></strong>"
            }
            if let link = run.link {
                html = "<a href=\"\(escape(link))\">\(html)</a>"
            }
            return html
        }.joined()
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
