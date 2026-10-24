#if os(macOS)
import AppKit
import XCTest
import ScriblMarkdown
@testable import ScriblMarkdownUI

@MainActor
final class MarkdownBlockViewTests: XCTestCase {
    func testThemeDerivesHeadingsFromTheSharedScale() {
        let theme = MarkdownTheme(bodyFontSize: 14)
        XCTAssertEqual(theme.headingFont(level: 1).pointSize, 32 * 14 / 17, accuracy: 0.01)
        XCTAssertEqual(theme.headingFont(level: 6).pointSize, 14 * 14 / 17, accuracy: 0.01)
        XCTAssertTrue(theme.headingFont(level: 3).fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testLongCodeCollapsesAndPreviewsShowEverything() {
        let code = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let view = MarkdownCodeBlockView(theme: MarkdownTheme())
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        view.configure(code: code, language: "swift")
        let collapsedHeight = view.intrinsicContentSize.height

        let preview = MarkdownCodeBlockView(theme: MarkdownTheme())
        preview.isInPreview = true
        preview.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        preview.configure(code: code, language: "swift")

        XCTAssertGreaterThan(preview.intrinsicContentSize.height, collapsedHeight * 2)
        XCTAssertEqual(view.code, code)
    }

    func testTableSizesToItsContent() {
        let table = MarkdownTableContent(headers: ["Name", "Value"], alignments: [.leading, .trailing], rows: [["a", "1"], ["b", "2"]])
        let view = MarkdownTableView(table: table, theme: MarkdownTheme()) { text, _, _ in NSAttributedString(string: text) }
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 10)
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.intrinsicContentSize.height, 60)
    }

    func testHighlighterMapsTokensToThemeColors() {
        let colors = MarkdownSyntaxColors.derived(from: .system)
        let highlighter = MarkdownSyntaxHighlighter(colors: colors)
        let runs = highlighter.colorRuns(forCode: "return 1", language: "swift")
        XCTAssertTrue(runs.contains { $0.range == NSRange(location: 0, length: 6) && $0.color == colors.keyword })
    }

    func testImageSourcesResolveAgainstTheDocument() {
        let base = URL(fileURLWithPath: "/Notes/Doc.md")
        XCTAssertEqual(MarkdownImageBlockView.imageURL(from: "img/a%20b.png", relativeTo: base)?.path, "/Notes/img/a b.png")
        XCTAssertEqual(MarkdownImageBlockView.imageURL(from: "https://x.dev/a.png")?.host, "x.dev")
        XCTAssertNil(MarkdownImageBlockView.imageURL(from: "rel.png"))
    }

    func testDetailsCanExpandWithoutLosingTheirBody() {
        let body = NSTextField(labelWithString: "Hidden text")
        let view = MarkdownDetailsView(
            summary: NSAttributedString(string: "More"),
            body: body,
            theme: MarkdownTheme(),
            isExpanded: false
        )
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 100)
        view.layoutSubtreeIfNeeded()
        let collapsed = view.fittingSize.height

        view.isExpanded = true
        view.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(view.fittingSize.height, collapsed)
        XCTAssertTrue(view.subviews.contains { $0.subviews.contains(body) })
    }
}
#endif
