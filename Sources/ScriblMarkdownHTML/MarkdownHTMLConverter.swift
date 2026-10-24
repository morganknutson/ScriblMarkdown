import Foundation
import ScriblMarkdown
import SwiftSoup

/// A file an HTML `cid:` reference stands for, such as an Apple Notes attachment.
public struct MarkdownHTMLAssetReference: Sendable, Equatable {
    public let relativePath: String
    public let isImage: Bool

    public init(relativePath: String, isImage: Bool) {
        self.relativePath = relativePath
        self.isImage = isImage
    }
}

public struct MarkdownHTMLConversion: Sendable, Equatable {
    public let markdown: String
    /// Elements that couldn't be represented and how they were handled.
    public let warnings: [String]
    public let usedPlaintextFallback: Bool

    public init(markdown: String, warnings: [String], usedPlaintextFallback: Bool) {
        self.markdown = markdown
        self.warnings = warnings
        self.usedPlaintextFallback = usedPlaintextFallback
    }
}

/// Converts rich text HTML (web pages, Apple Notes, Pages) to the Markdown the editors
/// write: `-` bullets, four-space nesting, `- [ ]` checklists, pipe tables and fenced code.
/// Pure and thread-safe, so large pastes can convert off the main thread.
public struct MarkdownHTMLConverter: Sendable {
    /// Elements that carry Markdown meaning. HTML without any of them (syntax-colored code
    /// from an editor, styled plain text) pastes better as its plain text.
    private static let semanticSelector = "h1, h2, h3, h4, h5, h6, strong, b, em, i, a[href], ul, ol, li, table, blockquote, pre, code, img, hr, del, s, strike, mark, kbd"

    public init() {}

    public func convert(
        html: String?,
        plaintext: String?,
        contentIDMap: [String: MarkdownHTMLAssetReference] = [:]
    ) -> MarkdownHTMLConversion {
        guard let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return plaintextFallback(plaintext, reason: "The source did not provide an HTML body.")
        }

        do {
            let document = try SwiftSoup.parseBodyFragment(html)
            guard let body = document.body() else {
                return plaintextFallback(plaintext, reason: "The HTML body was empty.")
            }
            var renderer = Renderer(contentIDMap: contentIDMap)
            let rendered = try renderer.renderChildren(of: body, context: .block)
            let markdown = Self.normalize(rendered)
            if markdown.isEmpty, let plaintext, !plaintext.isEmpty {
                return plaintextFallback(plaintext, reason: "The HTML body contained no readable content.")
            }
            return MarkdownHTMLConversion(
                markdown: markdown,
                warnings: renderer.warnings,
                usedPlaintextFallback: false
            )
        } catch {
            return plaintextFallback(
                plaintext,
                reason: "HTML conversion failed and plaintext was used: \(error.localizedDescription)"
            )
        }
    }

    /// The Markdown to paste for a rich text clipboard, or nil when its plain text is the
    /// better paste: the HTML has no Markdown-bearing elements (syntax-colored code from an
    /// editor or terminal), or it converts to exactly the plain text.
    public func markdownForPaste(html: String, plainText: String?) -> String? {
        guard let document = try? SwiftSoup.parseBodyFragment(html),
              let body = document.body(),
              let semantic = try? body.select(Self.semanticSelector),
              !semantic.isEmpty() else { return nil }
        let conversion = convert(html: html, plaintext: plainText)
        guard !conversion.usedPlaintextFallback else { return nil }
        let markdown = conversion.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty else { return nil }
        if let plainText, markdown == plainText.trimmingCharacters(in: .whitespacesAndNewlines) {
            return nil
        }
        return markdown
    }

    private func plaintextFallback(_ plaintext: String?, reason: String) -> MarkdownHTMLConversion {
        MarkdownHTMLConversion(
            markdown: Self.normalize(Self.escapePlaintext(plaintext ?? "")),
            warnings: [reason],
            usedPlaintextFallback: true
        )
    }

    private static func escapePlaintext(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: #"([`*_{}\[\]<>#+.!|>-])"#, with: #"\\$1"#, options: .regularExpression)
    }

    private static func normalize(_ value: String) -> String {
        var output = value
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty { output += "\n" }
        return output
    }

    private struct Renderer {
        enum Context {
            case block
            case inline
            case code
        }

        let contentIDMap: [String: MarkdownHTMLAssetReference]
        var warnings: [String] = []

        mutating func renderChildren(of node: Node, context: Context) throws -> String {
            var result = ""
            for child in node.getChildNodes() {
                result += try render(child, context: context)
            }
            return result
        }

        mutating func render(_ node: Node, context: Context) throws -> String {
            if let text = node as? TextNode {
                return renderText(text.getWholeText(), context: context)
            }
            guard let element = node as? Element else {
                return try renderChildren(of: node, context: context)
            }

            let tag = element.tagName().lowercased()
            switch tag {
            case "head", "meta", "title", "link", "style", "script", "noscript", "template":
                return ""
            case "html", "body", "section", "article", "main", "header", "footer", "nav", "aside",
                 "figure", "figcaption", "div", "span", "font", "u", "small", "label", "abbr", "cite",
                 "dl", "dt", "dd", "thead", "tbody", "tfoot", "center":
                return try renderChildren(of: element, context: context)
            case "p":
                return try renderChildren(of: element, context: .inline).trimmed + "\n\n"
            case "br":
                return context == .code ? "\n" : "  \n"
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let level = Int(tag.dropFirst()) ?? 1
                return String(repeating: "#", count: level) + " "
                    + (try renderChildren(of: element, context: .inline).trimmed) + "\n\n"
            case "strong", "b":
                return wrap(try renderChildren(of: element, context: .inline), with: "**")
            case "em", "i":
                return wrap(try renderChildren(of: element, context: .inline), with: "*")
            case "s", "strike", "del":
                return wrap(try renderChildren(of: element, context: .inline), with: "~~")
            case "mark":
                return wrap(try renderChildren(of: element, context: .inline), with: "==")
            case "sup":
                return wrap(try renderChildren(of: element, context: .inline), with: "^")
            case "sub":
                return wrap(try renderChildren(of: element, context: .inline), with: "~")
            case "kbd":
                return "<kbd>" + (try renderChildren(of: element, context: .code)).trimmed + "</kbd>"
            case "code":
                if context == .code { return try renderChildren(of: element, context: .code) }
                let content = try renderChildren(of: element, context: .code)
                let delimiter = content.contains("`") ? "``" : "`"
                return delimiter + content + delimiter
            case "pre":
                let content = try renderChildren(of: element, context: .code)
                    .trimmingCharacters(in: .newlines)
                return "```\(language(of: element))\n\(content)\n```\n\n"
            case "a":
                let label = try renderChildren(of: element, context: .inline).trimmed
                let href = try element.attr("href")
                if href.isEmpty || href.hasPrefix("javascript:") { return label }
                return "[\(label.isEmpty ? href : label)](\(escapeDestination(href)))"
            case "img":
                return try renderImage(element)
            case "ul":
                return try renderList(element, ordered: false, depth: 0) + "\n\n"
            case "ol":
                return try renderList(element, ordered: true, depth: 0) + "\n\n"
            case "li":
                return try renderChildren(of: element, context: .inline)
            case "blockquote":
                let content = try renderChildren(of: element, context: .block).trimmed
                return content.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.isEmpty ? ">" : "> " + $0 }
                    .joined(separator: "\n") + "\n\n"
            case "table":
                return try renderTable(element) + "\n\n"
            case "hr":
                return "---\n\n"
            case "input":
                return ""
            case "object", "embed", "iframe", "canvas", "svg", "math", "video", "audio":
                let readable = try renderChildren(of: element, context: context).trimmed
                warnings.append("Unsupported embedded object <\(tag)> was preserved as a visible marker.")
                return readable + (readable.isEmpty ? "" : " ") + "[Unsupported object: \(tag)]"
            default:
                warnings.append("Unrecognized HTML element <\(tag)> was flattened.")
                return try renderChildren(of: element, context: context)
            }
        }

        /// Wraps inline content in a Markdown marker, keeping surrounding spaces outside it
        /// so `<b>bold </b>text` stays valid emphasis.
        private func wrap(_ content: String, with marker: String) -> String {
            let trimmed = content.trimmed
            guard !trimmed.isEmpty else { return content }
            let leading = content.prefix { $0.isWhitespace }.isEmpty ? "" : " "
            let trailing = content.reversed().prefix { $0.isWhitespace }.isEmpty ? "" : " "
            return leading + marker + trimmed + marker + trailing
        }

        /// The fence info string from a `language-…` class on `<pre>` or its `<code>`.
        private func language(of pre: Element) -> String {
            let classes = ((try? pre.className()) ?? "") + " "
                + ((try? pre.select("code").first()?.className()) ?? "")
            return classes.split(separator: " ")
                .first { $0.hasPrefix("language-") || $0.hasPrefix("lang-") }
                .map { String($0.drop { $0 != "-" }.dropFirst()) } ?? ""
        }

        private mutating func renderImage(_ element: Element) throws -> String {
            let source = try element.attr("src")
            let alternate = try element.attr("alt")
            if source.lowercased().hasPrefix("cid:") {
                let contentID = String(source.dropFirst(4))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                if let reference = contentIDMap[contentID] {
                    let label = alternate.isEmpty ? "Attachment" : alternate
                    return reference.isImage
                        ? "![\(escapeInline(label))](\(escapeDestination(reference.relativePath)))"
                        : "[\(escapeInline(label))](\(escapeDestination(reference.relativePath)))"
                }
                warnings.append("The embedded attachment \(contentID) was not available.")
                return "[Missing attachment: \(escapeInline(alternate.isEmpty ? contentID : alternate))]"
            }
            guard !source.isEmpty, !source.lowercased().hasPrefix("data:") else { return "" }
            return "![\(escapeInline(alternate))](\(escapeDestination(source)))"
        }

        private mutating func renderList(_ element: Element, ordered: Bool, depth: Int) throws -> String {
            var lines: [String] = []
            var itemNumber = Int((try? element.attr("start")) ?? "") ?? 1
            for child in element.children() where child.tagName().lowercased() == "li" {
                var inline = ""
                var nested: [String] = []
                var isChecklist = false
                var isChecked = false
                for node in child.getChildNodes() {
                    if let nestedList = node as? Element,
                       ["ul", "ol"].contains(nestedList.tagName().lowercased()) {
                        nested.append(try renderList(
                            nestedList,
                            ordered: nestedList.tagName().lowercased() == "ol",
                            depth: depth + 1
                        ))
                    } else if let input = node as? Element,
                              input.tagName().lowercased() == "input",
                              (try input.attr("type")).lowercased() == "checkbox" {
                        isChecklist = true
                        isChecked = input.hasAttr("checked")
                    } else {
                        inline += try render(node, context: .inline)
                    }
                }
                let marker: String
                if isChecklist {
                    marker = isChecked ? "- [x] " : "- [ ] "
                } else {
                    marker = ordered ? "\(itemNumber). " : "- "
                }
                let indent = String(repeating: " ", count: depth * MarkdownVisualSpec.listIndentColumns)
                lines.append(indent + marker + inline.trimmed.replacingOccurrences(of: "\n", with: " "))
                lines.append(contentsOf: nested.filter { !$0.isEmpty })
                itemNumber += 1
            }
            return lines.joined(separator: "\n")
        }

        private mutating func renderTable(_ table: Element) throws -> String {
            let rows = try table.select("tr").array()
            guard !rows.isEmpty else { return "" }
            var renderedRows: [[String]] = []
            for row in rows {
                let cells = try row.select("th, td").array()
                renderedRows.append(try cells.map {
                    try renderChildren(of: $0, context: .inline)
                        .trimmed
                        .replacingOccurrences(of: "|", with: "\\|")
                        .replacingOccurrences(of: "\n", with: " ")
                })
            }
            let width = renderedRows.map(\.count).max() ?? 0
            guard width > 0 else { return "" }
            renderedRows = renderedRows.map { $0 + Array(repeating: "", count: width - $0.count) }
            let header = "| " + renderedRows[0].joined(separator: " | ") + " |"
            let separator = "| " + Array(repeating: "---", count: width).joined(separator: " | ") + " |"
            let body = renderedRows.dropFirst().map { "| " + $0.joined(separator: " | ") + " |" }
            return ([header, separator] + body).joined(separator: "\n")
        }

        private func renderText(_ value: String, context: Context) -> String {
            let normalized = value.replacingOccurrences(of: "\u{00A0}", with: " ")
            if context == .code { return normalized }
            if context == .block,
               normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ""
            }
            let collapsed = normalized.replacingOccurrences(
                of: #"[\t\n\r ]+"#,
                with: " ",
                options: .regularExpression
            )
            return escapeInline(collapsed)
        }

        private func escapeInline(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: #"([`*_{}\[\]<>|])"#, with: #"\\$1"#, options: .regularExpression)
        }

        private func escapeDestination(_ value: String) -> String {
            value.replacingOccurrences(of: " ", with: "%20")
                .replacingOccurrences(of: "(", with: "%28")
                .replacingOccurrences(of: ")", with: "%29")
        }
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
