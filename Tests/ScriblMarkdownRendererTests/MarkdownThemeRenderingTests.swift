#if os(macOS)
import AppKit
import XCTest
import ScriblMarkdown
import ScriblMarkdownUI
@testable import ScriblMarkdownRenderer

/// The display renderer in the shared look.
final class MarkdownThemeRenderingTests: XCTestCase {
    private let theme = MarkdownTheme()
    private var renderer: MarkdownAttributedRenderer { MarkdownAttributedRenderer(style: MarkdownRenderStyle(theme: theme)) }

    private func render(_ markdown: String) -> NSAttributedString {
        renderer.attributedString(for: MarkdownDocument(parsing: markdown))
    }

    func testChecklistsDrawBoxesAndCheckedItemsAreStruckAndDimmed() {
        let rendered = render("- [ ] Open\n- [x] Done")
        var cells: [NSTextAttachmentCell] = []
        rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            if let cell = (value as? NSTextAttachment)?.attachmentCell as? NSTextAttachmentCell { cells.append(cell) }
        }
        XCTAssertEqual(cells.count, 2)
        let done = (rendered.string as NSString).range(of: "Done")
        XCTAssertNotNil(rendered.attribute(.strikethroughStyle, at: done.location, effectiveRange: nil))
        XCTAssertEqual(rendered.attribute(.foregroundColor, at: done.location, effectiveRange: nil) as? NSColor, theme.palette.completedText)
        let open = (rendered.string as NSString).range(of: "Open")
        XCTAssertNil(rendered.attribute(.strikethroughStyle, at: open.location, effectiveRange: nil))
    }

    func testListsUseDepthBulletsAndHierarchicalLabels() {
        let bullets = render("- a\n    - b\n        - c").string
        XCTAssertTrue(bullets.contains("\u{2022}\ta") && bullets.contains("\u{25E6}\tb") && bullets.contains("\u{25AA}\tc"))
        let numbers = render("1. a\n    1. b\n        1. c").string
        XCTAssertTrue(numbers.contains("1.\ta") && numbers.contains("a.\tb") && numbers.contains("i.\tc"))
    }

    func testRulesAreDrawnAndQuotesArePlain() throws {
        let rendered = render("Above\n\n---\n\n> Quote")
        var ruleColor: NSColor?
        rendered.enumerateAttribute(.markdownRule, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            ruleColor = ruleColor ?? value as? NSColor
        }
        XCTAssertEqual(ruleColor, theme.palette.separator)
        let quote = (rendered.string as NSString).range(of: "Quote")
        let font = try XCTUnwrap(rendered.attribute(.font, at: quote.location, effectiveRange: nil) as? NSFont)
        XCTAssertFalse(font.fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertEqual(rendered.attribute(.markdownQuoteBar, at: quote.location, effectiveRange: nil) as? NSColor, theme.palette.accent)
    }

    func testHeadingsAndInlineTokensFollowTheTheme() throws {
        let rendered = render("###### Small\n\nUse `code` and ==mark==")
        let heading = try XCTUnwrap(rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(heading.pointSize, theme.headingFont(level: 6).pointSize, accuracy: 0.01)
        let code = (rendered.string as NSString).range(of: "code")
        XCTAssertEqual(rendered.attribute(.backgroundColor, at: code.location, effectiveRange: nil) as? NSColor, theme.palette.inlineCodeBackground)
        let mark = (rendered.string as NSString).range(of: "mark")
        XCTAssertEqual(rendered.attribute(.backgroundColor, at: mark.location, effectiveRange: nil) as? NSColor, theme.palette.highlightBackground)
    }

    func testKeycapsRenderAsDrawnCaps() {
        let rendered = render("Press <kbd>⌘K</kbd>")
        XCTAssertFalse(rendered.string.contains("<kbd>"))
        var hasAttachment = false
        rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            hasAttachment = hasAttachment || value != nil
        }
        XCTAssertTrue(hasAttachment)
    }

    func testTableCellsRenderWithHeaderWeightAndAlignment() throws {
        let cell = renderer.tableCellRenderer("**x**", true, .trailing)
        let paragraph = try XCTUnwrap(cell.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.alignment, .right)
        XCTAssertEqual(cell.string, "x")
    }
}
#endif
