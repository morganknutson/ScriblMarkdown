#if os(macOS)
import AppKit
import XCTest
import ScriblMarkdown
@testable import ScriblMarkdownEditor

/// The shared editing rules and look as the Mac editor applies them.
@MainActor
final class MarkdownSharedEditingTests: XCTestCase {
    private func makeEditor(_ text: String) -> (MarkdownEditorView, MarkdownEditorTextView) {
        let editor = MarkdownEditorView(text: text)
        editor.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        editor.layoutSubtreeIfNeeded()
        let textView = editor.textView as! MarkdownEditorTextView
        return (editor, textView)
    }

    private func command(_ selector: Selector, in editor: MarkdownEditorView) -> Bool {
        editor.controller.textView(editor.textView, doCommandBy: selector)
    }

    func testReturnOnAnEmptyNestedItemStepsOut() {
        let (editor, textView) = makeEditor("- one\n    - ")
        textView.setSelectedRange(NSRange(location: (editor.text as NSString).length, length: 0))
        XCTAssertTrue(command(#selector(NSResponder.insertNewline(_:)), in: editor))
        XCTAssertEqual(editor.text, "- one\n- ")
    }

    func testDeletingAnItemRenumbersTheList() {
        let (editor, textView) = makeEditor("1. one\n2. two\n3. three")
        let second = (editor.text as NSString).range(of: "2. two\n")
        textView.setSelectedRange(second)
        textView.insertText("", replacementRange: second)
        XCTAssertEqual(editor.text, "1. one\n2. three")
    }

    func testTypingTheChecklistShortcutMakesAnItem() {
        let (editor, textView) = makeEditor("[ ]")
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        textView.insertText(" ", replacementRange: textView.selectedRange())
        XCTAssertEqual(editor.text, "- [ ] ")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 0))
    }

    func testTabMovesBetweenTableCellsAndTypesTabsInCode() {
        let (editor, textView) = makeEditor("| a | b |\n|---|---|\n| 1 | 2 |\n\n```\ncode\n```")
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertTrue(command(#selector(NSResponder.insertTab(_:)), in: editor))
        XCTAssertEqual((editor.text as NSString).substring(with: textView.selectedRange()), "b")

        let code = (editor.text as NSString).range(of: "code")
        textView.setSelectedRange(NSRange(location: code.location, length: 0))
        XCTAssertFalse(command(#selector(NSResponder.insertTab(_:)), in: editor))
    }

    func testCodeBlocksGetAHeaderLineNumbersAndColoring() throws {
        let (editor, textView) = makeEditor("```swift\nlet value = 1\nreturn value\n```")
        let block = try XCTUnwrap(textView.renderedCodeBlocks.first)
        XCTAssertEqual(block.language, "swift")
        XCTAssertEqual(block.code, "let value = 1\nreturn value")
        XCTAssertNotNil(block.headerLineRange)
        XCTAssertGreaterThan(block.gutterWidth, MarkdownCodeBlockLayout.gutterPadding * 2)
        XCTAssertEqual(textView.subviews.compactMap { $0 as? MarkdownCodeBlockHeaderView }.count, 1)

        let keyword = (editor.text as NSString).range(of: "return")
        let colors = MarkdownSyntaxColors.derived(from: .system)
        XCTAssertEqual(textView.textStorage?.attribute(.foregroundColor, at: keyword.location, effectiveRange: nil) as? NSColor, colors.keyword)
    }

    func testTablesDrawAGridOverEditableSource() throws {
        let (editor, textView) = makeEditor("| Name | Value |\n|---|---|\n| a | 1 |")
        let table = try XCTUnwrap(textView.renderedTables.first)
        XCTAssertEqual(table.content.headers, ["Name", "Value"])
        XCTAssertEqual(table.rowLineRanges.count, 1)
        XCTAssertNotNil(textView.tableRect(for: table))
        XCTAssertEqual(editor.text, "| Name | Value |\n|---|---|\n| a | 1 |")
    }

    func testQuotesArePlainTextBesideAnAccentBar() throws {
        let (editor, textView) = makeEditor("> Quoted")
        let location = (editor.text as NSString).range(of: "Quoted").location
        let font = try XCTUnwrap(textView.textStorage?.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
        XCTAssertFalse(font.fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertFalse(textView.blockQuoteBarRects().isEmpty)
    }

    func testHeadingsUseTheSharedScaleForAllSixLevels() throws {
        let text = (1...6).map { String(repeating: "#", count: $0) + " H\($0)" }.joined(separator: "\n")
        let (editor, textView) = makeEditor(text)
        let theme = editor.style.theme
        for level in 1...6 {
            let location = (editor.text as NSString).range(of: "H\(level)").location
            let font = try XCTUnwrap(textView.textStorage?.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(font.pointSize, theme.headingFont(level: level).pointSize, accuracy: 0.01)
        }
    }

    func testShortcutsAreHandledByTheEditor() throws {
        let (editor, textView) = makeEditor("word")
        let window = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = editor
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 0, length: 4))
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "b",
            charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11
        ))
        XCTAssertTrue(textView.performKeyEquivalent(with: event))
        XCTAssertEqual(editor.text, "**word**")
    }

    func testRichTextPastesAsMarkdown() {
        let (editor, textView) = makeEditor("")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("<p>A <strong>bold</strong> idea</p>", forType: .html)
        pasteboard.setString("A bold idea", forType: .string)
        textView.paste(nil)
        XCTAssertEqual(editor.text, "A **bold** idea")
    }
}
#endif
