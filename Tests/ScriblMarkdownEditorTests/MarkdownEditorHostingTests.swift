import AppKit
import XCTest
import ScriblMarkdown
@testable import ScriblMarkdownEditor

@MainActor
final class MarkdownEditorHostingTests: XCTestCase {
    func testLinkInsertionLabelsWithTitleSelectionOrDestination() {
        let source = "See docs here"
        let selection = NSRange(location: 4, length: 4)

        let fromSelection = MarkdownInsertion.link(title: nil, destination: "https://a.dev", in: source, selection: selection)
        XCTAssertEqual(fromSelection.replacement, "[docs](https://a.dev)")
        XCTAssertEqual(fromSelection.selection, NSRange(location: 4 + 21, length: 0))

        let titled = MarkdownInsertion.link(title: "A [b]", destination: "My File.md", in: source, selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(titled.replacement, #"[A \[b\]](<My File.md>)"#)

        let bare = MarkdownInsertion.link(title: "  ", destination: "https://a.dev", in: source, selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(bare.replacement, "[https://a.dev](https://a.dev)")
    }

    func testHorizontalRuleIsPaddedSoItNeverBecomesASetextHeading() {
        let midLine = MarkdownInsertion.horizontalRule(in: "Text", selection: NSRange(location: 4, length: 0))
        XCTAssertEqual(midLine.replacement, "\n\n---\n\n")
        XCTAssertEqual(midLine.selection.location, 4 + 7)

        let betweenParagraphs = MarkdownInsertion.horizontalRule(
            in: "One\n\nTwo",
            selection: NSRange(location: 5, length: 0)
        )
        XCTAssertEqual(betweenParagraphs.replacement, "---\n\n")

        let beforeNewline = MarkdownInsertion.horizontalRule(in: "One\nTwo", selection: NSRange(location: 4, length: 0))
        XCTAssertEqual(beforeNewline.replacement, "\n---\n\n")
    }

    func testLinkAndRuleCommandsEditTheSourceThroughTheTextView() {
        let editor = MarkdownEditorView(text: "Read this")
        var reported = ""
        editor.controller.onTextChange = { reported = $0 }
        editor.textView.setSelectedRange(NSRange(location: 5, length: 4))

        editor.perform(.link(title: nil, destination: "https://scribl.ing"))
        XCTAssertEqual(editor.text, "Read [this](https://scribl.ing)")
        XCTAssertEqual(reported, editor.text)

        editor.perform(.horizontalRule)
        XCTAssertEqual(editor.text, "Read [this](https://scribl.ing)\n\n---\n\n")

    }

    func testCodeHighlighterColorsFencedCodeAndReceivesItsLanguage() throws {
        let highlighter = RecordingHighlighter()
        let host = TestMarkdownEditorHost()
        host.codeHighlighterOverride = highlighter
        let markdown = "```swift\nlet x = 1\n```\n"
        let editor = MarkdownEditorView(
            controller: MarkdownEditorController(host: host),
            text: markdown
        )

        XCTAssertEqual(highlighter.requests.last?.code, "let x = 1\n")
        XCTAssertEqual(highlighter.requests.last?.language, "swift")
        let keywordLocation = (markdown as NSString).range(of: "let").location
        let color = editor.textView.textStorage?.attribute(.foregroundColor, at: keywordLocation, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, .systemPink)
    }

    func testHostCanRejectSourceEditsBeforeTheyChangeText() {
        let host = TestMarkdownEditorHost()
        host.shouldChangeTextOverride = { textView, range, replacement in
            let proposed = (textView.string as NSString).replacingCharacters(in: range, with: replacement ?? "")
            return proposed.count <= 5
        }
        let editor = MarkdownEditorView(controller: MarkdownEditorController(host: host), text: "Hello")

        editor.textView.insertText("!", replacementRange: NSRange(location: 5, length: 0))
        XCTAssertEqual(editor.text, "Hello")

        editor.textView.insertText("i", replacementRange: NSRange(location: 4, length: 1))
        XCTAssertEqual(editor.text, "Helli")
    }

    func testFormattingReflectsTheCaretLine() {
        let editor = MarkdownEditorView(text: "## Heading\n> Quote\n**bold** and *it*\n```\ncode\n```\n")
        let source = editor.text as NSString

        editor.textView.setSelectedRange(NSRange(location: 4, length: 0))
        XCTAssertEqual(editor.formatting.headingLevel, 2)
        XCTAssertFalse(editor.formatting.isBold)

        editor.textView.setSelectedRange(NSRange(location: source.range(of: "Quote").location, length: 0))
        XCTAssertTrue(editor.formatting.isQuote)

        editor.textView.setSelectedRange(NSRange(location: source.range(of: "bold").location + 2, length: 0))
        XCTAssertTrue(editor.formatting.isBold)
        XCTAssertNil(editor.formatting.headingLevel)

        editor.textView.setSelectedRange(NSRange(location: source.range(of: "code\n").location + 2, length: 0))
        XCTAssertTrue(editor.formatting.isCodeBlock)
        XCTAssertFalse(editor.formatting.isInlineCode)
    }

    func testPaletteReachesTextAndRenderedObjects() throws {
        var palette = MarkdownEditorPalette.system
        palette.text = .systemTeal
        palette.link = .systemPurple
        let editor = MarkdownEditorView(
            controller: MarkdownEditorController(style: MarkdownEditorStyle(palette: palette)),
            text: "Plain [link](https://scribl.ing)"
        )
        let storage = try XCTUnwrap(editor.textView.textStorage)

        XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .systemTeal)
        let linkLocation = (editor.text as NSString).range(of: "link").location
        XCTAssertEqual(storage.attribute(.foregroundColor, at: linkLocation, effectiveRange: nil) as? NSColor, .systemPurple)
        XCTAssertEqual((editor.textView as? MarkdownEditorTextView)?.palette, palette)
    }

    func testUntitledPolicyDoesNotProtectALeadingHeading() {
        let editor = MarkdownEditorView(text: "# Heading\nBody")
        editor.textView.setSelectedRange(NSRange(location: 0, length: 9))
        editor.textView.insertText("Plain", replacementRange: editor.textView.selectedRange())
        XCTAssertEqual(editor.text, "Plain\nBody")
    }
}

private final class RecordingHighlighter: MarkdownCodeHighlighting {
    private(set) var requests: [(code: String, language: String?)] = []

    func colorRuns(forCode code: String, language: String?) -> [MarkdownCodeColorRun] {
        requests.append((code, language))
        return [MarkdownCodeColorRun(range: NSRange(location: 0, length: 3), color: .systemPink)]
    }
}
