#if canImport(UIKit)
import ScriblMarkdown
@testable import ScriblMarkdownUIKit
import UIKit
import XCTest

@MainActor
final class UIKitMarkdownBlockViewTests: XCTestCase {
    func testCodeOverlayPassesSourceTouchesThroughButReceivesControls() {
        let view = UIKitMarkdownCodeBlockView(theme: .system)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 120)
        view.configure(code: "return 1", language: "swift")
        view.layoutIfNeeded()

        XCTAssertEqual(view.languageLabel.text, "SWIFT")
        XCTAssertEqual(view.code, "return 1")
        XCTAssertNil(view.hitTest(CGPoint(x: 100, y: 70), with: nil))
        XCTAssertTrue(view.hitTest(view.copyButton.center, with: nil) === view.copyButton)
        XCTAssertTrue(view.hitTest(view.expandButton.center, with: nil) === view.expandButton)
    }

    func testTableOverlayKeepsGridAndExpandControl() {
        let view = UIKitMarkdownTableView(theme: .system)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 120)
        view.configure(rowDividers: [30, 60], columnDividers: [160])
        view.layoutIfNeeded()

        XCTAssertEqual(view.rowDividers, [30, 60])
        XCTAssertEqual(view.columnDividers, [160])
        XCTAssertNil(view.hitTest(CGPoint(x: 100, y: 70), with: nil))
        XCTAssertTrue(view.hitTest(view.expandButton.center, with: nil) === view.expandButton)
    }

    func testPreviewNumbersLinesAndColorsCodeTokens() {
        var theme = UIKitMarkdownTheme.system
        theme.syntaxKeyword = .magenta
        let preview = UIKitMarkdownBlockPreviewController(
            content: .code("return 1\nlet value = 2", "swift"),
            theme: theme
        )
        let attributed = preview.highlightedCode("return 1\nlet value = 2", language: "swift")

        XCTAssertTrue(attributed.string.hasPrefix("  1  return 1\n  2  let value = 2"))
        let keywordRange = (attributed.string as NSString).range(of: "return")
        XCTAssertEqual(attributed.attribute(.foregroundColor, at: keywordRange.location, effectiveRange: nil) as? UIColor, .magenta)
        preview.loadViewIfNeeded()
        XCTAssertTrue(preview.view.subviews.contains { $0 is UITextView })
    }

    func testPreviewUsesParsedTableCellsAndTheme() {
        let source = "| Name | Value |\n| --- | --- |\n| A | 1 |\n"
        let table = try! XCTUnwrap(MarkdownTable.tables(in: source, excluding: []).first)
        var theme = UIKitMarkdownTheme.system
        theme.cornerRadius = 13
        let preview = UIKitMarkdownBlockPreviewController(content: .table(table, source), theme: theme)
        let grid = try! XCTUnwrap(preview.tableGrid(table, source: source) as? UIStackView)

        XCTAssertEqual(grid.arrangedSubviews.count, 2)
        XCTAssertEqual(grid.layer.cornerRadius, 13)
        let firstRow = try! XCTUnwrap(grid.arrangedSubviews.first as? UIStackView)
        let firstCell = try! XCTUnwrap(firstRow.arrangedSubviews.first)
        XCTAssertEqual((firstCell.subviews.first as? UILabel)?.text, "Name")
        preview.loadViewIfNeeded()
        XCTAssertTrue(preview.view.subviews.contains { $0 is UIScrollView })
    }
}
#endif
