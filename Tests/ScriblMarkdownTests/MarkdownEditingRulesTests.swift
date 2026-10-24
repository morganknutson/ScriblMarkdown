import XCTest
@testable import ScriblMarkdown

final class MarkdownEditingRulesTests: XCTestCase {
    /// Applies `edit` and returns the text with the selection marked by `|`.
    private func result(_ edit: MarkdownEdit?, in source: String) throws -> String {
        let edit = try XCTUnwrap(edit)
        let text = edit.applied(to: source) as NSString
        let selection = edit.selection
        return text.replacingCharacters(in: selection, with: "|" + text.substring(with: selection) + (selection.length > 0 ? "|" : ""))
    }

    private func caret(_ marked: String) -> (String, NSRange) {
        let location = (marked as NSString).range(of: "|").location
        return (marked.replacingOccurrences(of: "|", with: ""), NSRange(location: location, length: 0))
    }

    private func newline(_ marked: String) throws -> String {
        let (source, selection) = caret(marked)
        return try result(MarkdownEditingRules.newline(in: source, selection: selection), in: source)
    }

    func testReturnContinuesBulletsChecklistsAndNumbers() throws {
        XCTAssertEqual(try newline("- one|"), "- one\n- |")
        XCTAssertEqual(try newline("* one|"), "* one\n* |")
        XCTAssertEqual(try newline("- [x] done|"), "- [x] done\n- [ ] |")
        XCTAssertEqual(try newline("1. one|\n2. two"), "1. one\n2. |\n3. two")
        XCTAssertEqual(try newline("    - nested|"), "    - nested\n    - |")
    }

    func testReturnOnAnEmptyItemStepsOutBeforeRemovingTheMarker() throws {
        XCTAssertEqual(try newline("- one\n    - |"), "- one\n- |")
        XCTAssertEqual(try newline("- one\n- |"), "- one\n|")
        XCTAssertEqual(try newline("1. one\n    1. |"), "1. one\n2. |")
    }

    func testReturnBeforeAnItemsTextOpensAnEmptyItemAbove() throws {
        XCTAssertEqual(try newline("- |one"), "- \n- |one")
    }

    func testReturnContinuesAndEndsQuotes() throws {
        XCTAssertEqual(try newline("> quoted|"), "> quoted\n> |")
        XCTAssertEqual(try newline("> > deep|"), "> > deep\n> > |")
        XCTAssertEqual(try newline("> quoted\n> |"), "> quoted\n|")
    }

    func testReturnAfterARuleKeepsItOnItsOwnLine() throws {
        XCTAssertEqual(try newline("Text\n---|"), "Text\n\n---\n\n|")
        XCTAssertEqual(try newline("***|"), "***\n\n|")
    }

    func testReturnElsewhereIsLeftToTheEditor() {
        XCTAssertNil(MarkdownEditingRules.newline(in: "Plain", selection: NSRange(location: 5, length: 0)))
    }

    func testTabIndentsAndOutdentsListItemsAndRenumbers() throws {
        let source = "1. one\n2. two\n3. three"
        let indented = try result(
            MarkdownEditingRules.indent(in: source, selection: NSRange(location: 10, length: 0), outdent: false),
            in: source
        )
        XCTAssertEqual(indented, "1. one\n    1. |two\n2. three")

        let (nested, selection) = caret("- one\n    - t|wo")
        XCTAssertEqual(try result(MarkdownEditingRules.indent(in: nested, selection: selection, outdent: true), in: nested), "- one\n- t|wo")
        XCTAssertNil(MarkdownEditingRules.indent(in: "Plain", selection: NSRange(location: 0, length: 0), outdent: false))
        XCTAssertEqual(
            MarkdownEditingRules.indent(in: "- top", selection: NSRange(location: 3, length: 0), outdent: true)?.changesText,
            false
        )
    }

    func testBackspaceAfterAMarkerOutdentsThenRemovesIt() throws {
        let (nested, nestedSelection) = caret("- one\n    - |two")
        XCTAssertEqual(
            try result(MarkdownEditingRules.deleteAtListMarker(in: nested, selection: nestedSelection, forward: false), in: nested),
            "- one\n- |two"
        )
        let (top, topSelection) = caret("1. one\n2. |two\n3. three")
        XCTAssertEqual(
            try result(MarkdownEditingRules.deleteAtListMarker(in: top, selection: topSelection, forward: false), in: top),
            // The rest is a list of its own, still starting where it was written.
            "1. one\n|two\n3. three"
        )
    }

    func testRenumberingFollowsEachListsFirstNumber() throws {
        let source = "3. a\n7. b\n\nText\n\n1. c\n1. d"
        let renumbered = try XCTUnwrap(MarkdownEditingRules.renumberOrderedLists(in: source, selection: NSRange(location: 0, length: 0)))
        XCTAssertEqual(renumbered.applied(to: source), "3. a\n4. b\n\nText\n\n1. c\n2. d")
        XCTAssertNil(MarkdownEditingRules.renumberOrderedLists(in: "1. a\n2. b", selection: NSRange(location: 0, length: 0)))
    }

    func testTypedChecklistShortcut() throws {
        let (source, selection) = caret("[ ]|")
        XCTAssertEqual(
            try result(MarkdownEditingRules.typingShortcut(in: source, selection: selection, replacement: " "), in: source),
            "- [ ] |"
        )
        let (nested, nestedSelection) = caret("- item\n    []|")
        XCTAssertEqual(
            try result(MarkdownEditingRules.typingShortcut(in: nested, selection: nestedSelection, replacement: " "), in: nested),
            "- item\n    - [ ] |"
        )
    }

    func testThirdBacktickClosesTheFence() throws {
        let (source, selection) = caret("Intro\n``|")
        XCTAssertEqual(
            try result(MarkdownEditingRules.typingShortcut(in: source, selection: selection, replacement: "`"), in: source),
            "Intro\n```|\n```"
        )
        // Closing an open fence doesn't add another.
        let (open, openSelection) = caret("```\ncode\n``|")
        XCTAssertNil(MarkdownEditingRules.typingShortcut(in: open, selection: openSelection, replacement: "`"))
    }

    func testTabMovesBetweenTableCells() throws {
        let source = "| a | b |\n|---|---|\n| 1 | 2 |"
        let text = source as NSString
        let next = try XCTUnwrap(MarkdownEditingRules.tableCellSelection(in: source, selection: NSRange(location: 2, length: 0), forward: true))
        XCTAssertEqual(text.substring(with: next), "b")
        let wrapped = try XCTUnwrap(MarkdownEditingRules.tableCellSelection(in: source, selection: next, forward: true))
        XCTAssertEqual(text.substring(with: wrapped), "1")
        let back = try XCTUnwrap(MarkdownEditingRules.tableCellSelection(in: source, selection: wrapped, forward: false))
        XCTAssertEqual(text.substring(with: back), "b")
        XCTAssertNil(MarkdownEditingRules.tableCellSelection(in: "Plain", selection: NSRange(location: 0, length: 0), forward: true))
    }

    func testCodeBlocksAreDetectedForTabs() {
        let source = "```\nlet x = 1\n```\nAfter"
        XCTAssertTrue(MarkdownEditingRules.isInsideCodeBlock(6, in: source))
        XCTAssertFalse(MarkdownEditingRules.isInsideCodeBlock((source as NSString).length, in: source))
    }

    func testMinimalEditKeepsSurrogatePairsWhole() {
        let edit = MarkdownEdit(replacing: "a😀b", with: "a😃b", selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(edit.range, NSRange(location: 1, length: 2))
        XCTAssertEqual(edit.replacement, "😃")
        XCTAssertEqual(edit.applied(to: "a😀b"), "a😃b")
    }

    func testOrderedLabelsAndBulletsFollowTheVisualSpec() {
        XCTAssertEqual(MarkdownVisualSpec.orderedLabel(number: 4, depth: 0), "4.")
        XCTAssertEqual(MarkdownVisualSpec.orderedLabel(number: 28, depth: 1), "ab.")
        XCTAssertEqual(MarkdownVisualSpec.orderedLabel(number: 9, depth: 2), "ix.")
        XCTAssertEqual(MarkdownVisualSpec.bulletSymbol(depth: 5), "\u{25AA}")
        XCTAssertEqual(MarkdownVisualSpec.headingSize(level: 2, bodySize: 8.5), 12)
    }

    func testShortcutsMatchUnshiftedKeys() {
        XCTAssertEqual(MarkdownEditorShortcut.matching(key: "B", modifiers: .command)?.action, .bold)
        XCTAssertEqual(MarkdownEditorShortcut.matching(key: "8", modifiers: [.command, .shift])?.action, .numberedList)
        XCTAssertNil(MarkdownEditorShortcut.matching(key: "8", modifiers: .command))
        XCTAssertEqual(MarkdownEditorShortcut.shortcut(for: .editLink)?.key, "k")
    }
}
