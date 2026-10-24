import AppKit
import XCTest
import ScriblMarkdown
@testable import ScriblMarkdownRenderer

final class MarkdownAttributedRendererTests: XCTestCase {
    private let renderer = MarkdownAttributedRenderer(style: MarkdownRenderStyle(
        bodyFont: .systemFont(ofSize: 13),
        headingFonts: [.boldSystemFont(ofSize: 20), .boldSystemFont(ofSize: 16)],
        codeFont: .monospacedSystemFont(ofSize: 12, weight: .regular),
        textColor: .labelColor,
        quoteBarColor: .systemBlue
    ))

    func testSegmentsSplitOutCodeTablesAndImages() {
        let document = MarkdownDocument(parsing: "Intro\n\n```\ncode\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n![x](x.png)\n\nOutro")
        let kinds = renderer.segments(for: document).map { segment -> String in
            switch segment {
            case .text(let text): return "text:\(text.string)"
            case .codeBlock(let code, _): return "code:\(code)"
            case .table(let table): return "table:\(table.headers.joined(separator: ","))"
            case .image(let source, _): return "image:\(source)"
            }
        }
        XCTAssertEqual(kinds, ["text:Intro", "code:code", "table:a,b", "image:x.png", "text:Outro"])
    }

    func testRenderedTextHasNoMarkersAndStylesRuns() throws {
        let text = renderer.attributedString(for: MarkdownDocument(parsing: "## Head\n\nSome **bold** and [link](https://a.dev)\n\n- Item\n> Quote"))
        XCTAssertEqual(text.string, "Head\nSome bold and link\n\u{2022}\tItem\nQuote")

        let ns = text.string as NSString
        let headFont = try XCTUnwrap(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(headFont.pointSize, 16)
        let boldFont = try XCTUnwrap(text.attribute(.font, at: ns.range(of: "bold").location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(boldFont.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(text.attribute(.link, at: ns.range(of: "link").location, effectiveRange: nil) as? URL, URL(string: "https://a.dev"))
        XCTAssertEqual(text.attribute(.markdownQuoteBar, at: ns.range(of: "Quote").location, effectiveRange: nil) as? NSColor, .systemBlue)
    }

    func testBlocksAreSeparatedBySpacingNotBlankLines() throws {
        let text = renderer.attributedString(for: MarkdownDocument(parsing: "One\n\n\n\nTwo\n\n- a\n- b"))
        XCTAssertEqual(text.string, "One\nTwo\n\u{2022}\ta\n\u{2022}\tb")
        let first = try XCTUnwrap(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(first.paragraphSpacing, renderer.style.blockSpacing)
        let item = try XCTUnwrap(text.attribute(.paragraphStyle, at: (text.string as NSString).range(of: "a").location, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(item.paragraphSpacing, renderer.style.itemSpacing)
    }

    func testCollapsedLineBreaksJoinParagraphLinesButKeepHardBreaks() {
        var style = renderer.style
        style.lineBreaks = .collapsed
        let text = MarkdownAttributedRenderer(style: style)
            .attributedString(for: MarkdownDocument(parsing: "one\ntwo  \nthree"))
        XCTAssertEqual(text.string, "one two\nthree")
    }

    func testHierarchicalOrderedLabelsAreOptIn() {
        let document = MarkdownDocument(parsing: "1. Parent\n    1. Child")
        XCTAssertEqual(renderer.attributedString(for: document).string, "1.\tParent\n1.\tChild")
        var style = renderer.style
        style.orderedListLabels = .hierarchical
        XCTAssertEqual(MarkdownAttributedRenderer(style: style).attributedString(for: document).string, "1.\tParent\na.\tChild")
    }
}

extension MarkdownAttributedRendererTests {
    func testLineEndsDoNotCarryRunStyling() {
        var style = renderer.style
        style.codeBackgroundColor = .systemGray
        let text = MarkdownAttributedRenderer(style: style)
            .attributedString(for: MarkdownDocument(parsing: "- Audit `Views`\n- [link](https://a.dev)\n\nNext"))
        let ns = text.string as NSString
        var location = 0
        while true {
            let newline = ns.range(of: "\n", range: NSRange(location: location, length: ns.length - location))
            guard newline.location != NSNotFound else { break }
            XCTAssertNil(text.attribute(.backgroundColor, at: newline.location, effectiveRange: nil))
            XCTAssertNil(text.attribute(.link, at: newline.location, effectiveRange: nil))
            location = NSMaxRange(newline)
        }
    }
}
