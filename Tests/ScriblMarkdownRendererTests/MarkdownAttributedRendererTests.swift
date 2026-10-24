#if os(macOS)
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

    func testRendersDetailsMathAndAutolinks() throws {
        let document = MarkdownDocument(parsing: """
        <details><summary>**More** info</summary>
        Body with https://a.dev.
        </details>

        $$
        x^2
        $$
        """)
        let text = renderer.attributedString(for: document)
        XCTAssertEqual(text.string, "More info\nBody with https://a.dev.\nx²")
        let ns = text.string as NSString
        let summaryFont = try XCTUnwrap(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(summaryFont.fontDescriptor.symbolicTraits.contains(.bold))
        let bodyStart = ns.range(of: "Body").location
        let bodyStyle = try XCTUnwrap(text.attribute(.paragraphStyle, at: bodyStart, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertGreaterThan(bodyStyle.headIndent, 0)
        let linkStart = ns.range(of: "https://a.dev").location
        XCTAssertEqual(text.attribute(.link, at: linkStart, effectiveRange: nil) as? URL, URL(string: "https://a.dev"))
        let mathStart = ns.range(of: "x²").location
        let mathStyle = try XCTUnwrap(text.attribute(.paragraphStyle, at: mathStart, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(mathStyle.alignment, .center)
    }

    func testCacheTracksNeighborsAndCanBeInvalidated() {
        let cache = MarkdownRenderCache()
        let first = MarkdownDocument(parsing: "# Heading\n\nOne")
        let cold = renderer.attributedString(for: first, cache: cache)
        let warm = renderer.attributedString(for: first, cache: cache)
        XCTAssertEqual(cold, warm)
        let grown = MarkdownDocument(parsing: "# Heading\n\nOne\n\nTwo")
        XCTAssertEqual(renderer.attributedString(for: grown, cache: cache),
                       renderer.attributedString(for: grown))
        cache.invalidate()
        var newStyle = renderer.style
        newStyle.textColor = .systemRed
        let changed = MarkdownAttributedRenderer(style: newStyle).attributedString(for: grown, cache: cache)
        XCTAssertEqual(changed.attribute(.foregroundColor, at: (changed.string as NSString).range(of: "One").location, effectiveRange: nil) as? NSColor, .systemRed)
    }

    func testCacheKeepsSeparateTextSections() {
        let document = MarkdownDocument(parsing: "Before\n\n```\ncode\n```\n\nAfter")
        let cache = MarkdownRenderCache()
        let segments = renderer.segments(for: document, cache: cache)
        XCTAssertEqual(segments.count, 3)
        guard case .text(let first) = segments[0],
              case .text(let last) = segments[2] else {
            return XCTFail("Expected text sections")
        }
        XCTAssertEqual(first.string, "Before")
        XCTAssertEqual(last.string, "After")
        XCTAssertNotNil(cache.value(at: 0, scope: 1, block: .paragraph("Before"),
                                    previous: nil, next: nil, footnoteOrdinals: [:]))
        XCTAssertNotNil(cache.value(at: 0, scope: 3, block: .paragraph("After"),
                                    previous: nil, next: nil, footnoteOrdinals: [:]))
    }

    func testUncachedRenderPerformance() {
        let document = performanceDocument()
        measure { _ = renderer.attributedString(for: document) }
    }

    func testCachedRenderPerformance() {
        let document = performanceDocument()
        let cache = MarkdownRenderCache()
        _ = renderer.attributedString(for: document, cache: cache)
        measure { _ = renderer.attributedString(for: document, cache: cache) }
    }

    private func performanceDocument() -> MarkdownDocument {
        let markdown = Array(repeating: "# Heading\nParagraph **bold** with https://a.dev.\n- Item", count:500)
            .joined(separator: "\n\n")
        return MarkdownDocument(parsing: markdown)
    }

    func testLargeDocumentParseAndRenderPerformance() {
        let sample = """
        # Heading
        Paragraph with **strong** and https://example.com.
        - Bullet
        1. Ordered
        - [x] Task
        > Quote
        Note[^n].
        [^n]: Footnote.
        ---
        ![Image](image.png)
        | A | B |
        |---|---|
        | one | two |
        ```swift
        print("hi")
        ```
        <details><summary>Summary</summary>
        Body.
        </details>
        $$
        x^2
        $$
        """
        let markdown = Array(repeating: sample, count: 100).joined(separator: "\n\n")
        measure {
            let document = MarkdownDocument(parsing: markdown)
            _ = renderer.attributedString(for: document)
        }
    }

    func testSegmentsSplitOutCodeTablesAndImages() {
        let document = MarkdownDocument(parsing: "Intro\n\n```\ncode\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n![x](x.png)\n\nOutro")
        let kinds = renderer.segments(for: document).map { segment -> String in
            switch segment {
            case .text(let text): return "text:\(text.string)"
            case .codeBlock(let code, _): return "code:\(code)"
            case .table(let table): return "table:\(table.headers.joined(separator: ","))"
            case .image(let source, _): return "image:\(source)"
            case .linkCard: return "card"
            case .details: return "details"
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
#endif
