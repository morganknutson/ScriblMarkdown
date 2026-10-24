#if os(macOS)
import AppKit
import XCTest
import ScriblMarkdown
@testable import ScriblMarkdownEditor

final class MarkdownEditorBehaviorTests: XCTestCase {
    @MainActor
    func testInitialMarkdownScrollResetHappensBeforeFirstDraw() {
        let scrollView = MarkdownEditorView(text: String(repeating: "Line\n", count: 400))
        scrollView.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        scrollView.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 600))
        scrollView.prepareForInitialDisplay()

        XCTAssertGreaterThan(scrollView.contentView.bounds.minY, 0)
        scrollView.viewWillDraw()
        XCTAssertEqual(scrollView.contentView.bounds.minY, 0)
    }

    @MainActor
    func testSwitchingMarkdownNotesResetsScrollPosition() {
        let scrollView = MarkdownEditorView(text: String(repeating: "Line\n", count: 400))
        scrollView.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        scrollView.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 600))

        scrollView.scrollToTop()

        XCTAssertEqual(scrollView.contentView.bounds.minY, 0)
    }

    @MainActor
    func testStyledEditorProtectsTheTitleMarkerWhenTitleIsDeleted() {
        var text = "# Title\n\nBody"
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { text = $0 }
        )
        let textView = NSTextView()
        textView.string = text
        textView.setSelectedRange(NSRange(location: 0, length: 7))

        XCTAssertTrue(coordinator.textView(
            textView,
            doCommandBy: #selector(NSResponder.deleteBackward(_:))
        ))
        XCTAssertEqual(textView.string, "# \n\nBody")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))
        XCTAssertTrue(coordinator.hasEmptyTitle(in: textView))

        XCTAssertTrue(coordinator.textView(
            textView,
            doCommandBy: #selector(NSResponder.deleteBackward(_:))
        ))
        XCTAssertEqual(textView.string, "# \n\nBody")
    }

    @MainActor
    func testSelectAllDeletionRestoresEmptyNoteStructure() {
        var text = "# Title\n\nBody"
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { text = $0 }
        )
        let textView = NSTextView()
        textView.string = text
        textView.setSelectedRange(
            NSRange(location: 0, length: (text as NSString).length)
        )

        XCTAssertTrue(coordinator.textView(
            textView,
            doCommandBy: #selector(NSResponder.deleteBackward(_:))
        ))
        XCTAssertEqual(textView.string, "# \n\n")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))
        XCTAssertTrue(coordinator.hasEmptyTitle(in: textView))

        textView.insertText("Replacement", replacementRange: textView.selectedRange())
        XCTAssertEqual(textView.string, "# Replacement\n\n")
    }

    @MainActor
    func testDeletingTheWholeTitleLineDoesNotPromoteBodyIntoTitle() {
        var text = "# Title\n\nBody"
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { text = $0 }
        )
        let textView = NSTextView()
        textView.delegate = coordinator
        textView.string = text
        let titleLine = (text as NSString).lineRange(for: NSRange(location: 0, length: 0))
        textView.setSelectedRange(titleLine)

        textView.deleteBackward(nil)

        XCTAssertEqual(textView.string, "# \n\nBody")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))
        XCTAssertTrue(coordinator.hasEmptyTitle(in: textView))
    }

    @MainActor
    func testTitleActionRestoresFormattingToAnEmptyFirstLine() {
        var text = "\n\nBody"
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { text = $0 }
        )
        let textView = NSTextView()
        textView.delegate = coordinator
        textView.string = text
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        coordinator.apply(.title, to: textView)

        XCTAssertEqual(textView.string, "# \n\nBody")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))
        XCTAssertTrue(coordinator.hasEmptyTitle(in: textView))
    }

    @MainActor
    func testLeavingAnEmptyTitleSolidifiesUntitledNoteAndMovesToBody() {
        for command in [
            #selector(NSResponder.insertNewline(_:)),
            #selector(NSResponder.moveDown(_:))
        ] {
            var text = "# \n\n"
            let coordinator = MarkdownEditorController(
                presentation: .styled,
                titlePolicy: .note,
                onTextChange: { text = $0 }
            )
            let textView = NSTextView()
            textView.delegate = coordinator
            textView.string = text
            textView.setSelectedRange(NSRange(location: 2, length: 0))

            XCTAssertTrue(coordinator.textView(textView, doCommandBy: command))
            XCTAssertEqual(textView.string, "# Untitled Note\n\n")
            XCTAssertEqual(textView.selectedRange(), NSRange(location: 16, length: 0))
        }
    }

    @MainActor
    func testEmptyTitleFocusPlacesCaretBeforePlaceholderText() {
        var text = "# \n\n"
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { text = $0 }
        )
        let textView = NSTextView()
        textView.string = text
        textView.setSelectedRange(NSRange(location: text.utf16.count, length: 0))

        coordinator.focusEmptyTitle(in: textView)

        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))
        textView.insertText("Project", replacementRange: textView.selectedRange())
        XCTAssertEqual(textView.string, "# Project\n\n")
    }

    @MainActor
    func testEmptyTitleFocusRequiresAnExplicitOneShotRequest() async {
        var text = "# \n\n"
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { text = $0 }
        )
        let textView = NSTextView()
        textView.string = text
        let unfocusedSelection = NSRange(location: text.utf16.count, length: 0)
        textView.setSelectedRange(unfocusedSelection)
        var handledRequests: [UUID] = []
        let handled = expectation(description: "Focus request handled")
        coordinator.onFocusRequestHandled = {
            handledRequests.append($0)
            handled.fulfill()
        }

        coordinator.handleFocusRequest(nil, in: textView)
        XCTAssertEqual(textView.selectedRange(), unfocusedSelection)

        let requestID = UUID()
        coordinator.handleFocusRequest(requestID, in: textView)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))

        textView.setSelectedRange(unfocusedSelection)
        coordinator.handleFocusRequest(requestID, in: textView)
        XCTAssertEqual(textView.selectedRange(), unfocusedSelection)

        await fulfillment(of: [handled], timeout: 1)
        XCTAssertEqual(handledRequests, [requestID])
    }

    @MainActor
    func testEmptyTitleCaretUsesTitleFontHeight() {
        let textView = MarkdownEditorTextView()
        textView.string = "# \n\n"
        textView.titlePlaceholder = .init(
            text: "Untitled Note",
            font: .systemFont(ofSize: 32, weight: .bold),
            color: .tertiaryLabelColor
        )
        textView.setSelectedRange(NSRange(location: 2, length: 0))

        let adjusted = textView.insertionPointRect(
            for: NSRect(x: 10, y: 12, width: 1, height: 1)
        )

        XCTAssertEqual(adjusted.origin, NSPoint(x: 10, y: 12))
        XCTAssertEqual(adjusted.width, 2)
        XCTAssertGreaterThan(adjusted.height, 30)
    }

    @MainActor
    func testKeyboardNavigationCannotLeaveCaretInsideTitleMarker() {
        var text = "# \n\nBody"
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { text = $0 }
        )
        let textView = NSTextView()
        textView.string = text
        textView.setSelectedRange(NSRange(location: 1, length: 0))

        coordinator.protectTitlePrefixSelection(in: textView)

        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))
        textView.insertText("Project", replacementRange: textView.selectedRange())
        XCTAssertEqual(textView.string, "# Project\n\nBody")
    }

    @MainActor
    func testEmptyTitleReservesFullTitleLineAboveBody() throws {
        var text = "# \n\nBody"
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { text = $0 }
        )
        let textView = MarkdownEditorTextView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 300)
        )
        textView.string = text

        coordinator.applyPresentation(to: textView)

        let storage = try XCTUnwrap(textView.textStorage)
        let emptyTitleNewlineFont = try XCTUnwrap(
            storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        )
        let bodyFont = try XCTUnwrap(
            storage.attribute(.font, at: 4, effectiveRange: nil) as? NSFont
        )
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let titleGlyph = layoutManager.glyphIndexForCharacter(at: 2)
        let bodyGlyph = layoutManager.glyphIndexForCharacter(at: 4)
        let titleLine = layoutManager.lineFragmentRect(
            forGlyphAt: titleGlyph,
            effectiveRange: nil
        )
        let bodyLine = layoutManager.lineFragmentRect(
            forGlyphAt: bodyGlyph,
            effectiveRange: nil
        )

        XCTAssertEqual(emptyTitleNewlineFont.pointSize, bodyFont.pointSize)
        XCTAssertGreaterThan(titleLine.height, 30)
        XCTAssertGreaterThanOrEqual(bodyLine.minY, titleLine.maxY)
    }

    @MainActor
    func testStyledEditorDrawsBulletsByDepthOverHiddenMarkers() throws {
        let text = "- One\n    * Two\n        + Three\n            - Four\n- [ ] Task"
        let coordinator = MarkdownEditorController(presentation: .styled)
        let textView = MarkdownEditorTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        textView.string = text
        textView.layoutManager?.delegate = coordinator

        coordinator.applyPresentation(to: textView)

        XCTAssertEqual(textView.renderedBullets.map(\.symbol), ["\u{2022}", "\u{25E6}", "\u{25AA}", "\u{25AA}"])
        let marker = try XCTUnwrap(textView.renderedBullets.first?.markerLocation)
        XCTAssertEqual(textView.textStorage?.attribute(.foregroundColor, at: marker, effectiveRange: nil) as? NSColor, .clear)
        XCTAssertEqual(textView.string, text)
    }

    @MainActor
    func testListCommandsInsertMarkersOnAnEmptyLine() {
        let cases: [(MarkdownEditorCommand.Action, String)] = [
            (.bulletedList, "- "),
            (.numberedList, "1. "),
            (.checklist, "- [ ] ")
        ]

        for (action, expected) in cases {
            var text = ""
            let coordinator = MarkdownEditorController(
                presentation: .styled,
                titlePolicy: .note,
                onTextChange: { text = $0 }
            )
            let textView = NSTextView()
            textView.string = text
            textView.setSelectedRange(NSRange(location: 0, length: 0))

            coordinator.apply(action, to: textView)

            XCTAssertEqual(textView.string, expected)
            XCTAssertEqual(textView.selectedRange(), NSRange(location: expected.utf16.count, length: 0))
        }
    }

    @MainActor
    func testInlineFormattingDoesNotWrapMarkdownListMarker() {
        let cases = [
            ("- search fixes", "- **search fixes**"),
            ("3. numbered item", "3. **numbered item**"),
            ("- [ ] checklist item", "- [ ] **checklist item**")
        ]

        for (source, expected) in cases {
            var text = source
            let coordinator = MarkdownEditorController(
                presentation: .styled,
                titlePolicy: .note,
                onTextChange: { text = $0 }
            )
            let textView = NSTextView()
            textView.string = source
            textView.setSelectedRange(NSRange(location: 0, length: (source as NSString).length))

            coordinator.apply(.bold, to: textView)

            XCTAssertEqual(textView.string, expected)
        }
    }

    @MainActor
    func testStyledListsUseHangingIndentForWrappedLines() throws {
        var text = "- A long list item that wraps\n  - Nested item"
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { text = $0 }
        )
        let textView = NSTextView()
        textView.string = text

        coordinator.applyPresentation(to: textView)

        let topLevel = try XCTUnwrap(
            textView.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                as? NSParagraphStyle
        )
        let nestedLocation = (text as NSString).range(of: "  - Nested").location
        let nested = try XCTUnwrap(
            textView.textStorage?.attribute(.paragraphStyle, at: nestedLocation, effectiveRange: nil)
                as? NSParagraphStyle
        )
        XCTAssertEqual(topLevel.firstLineHeadIndent, 0)
        XCTAssertGreaterThan(topLevel.headIndent, 0)
        XCTAssertGreaterThan(nested.headIndent, topLevel.headIndent)
        XCTAssertEqual(topLevel.lineSpacing, 2)
        XCTAssertEqual(topLevel.paragraphSpacing, 7)
    }

    func testLiteralBulletCharactersBecomeCanonicalMarkdownLists() {
        let source = """
        • Parent
          • Child
        Text • stays inline
        ```text
        • stays literal in code
        ```
        """

        XCTAssertEqual(
            MarkdownListNormalizer.canonicalizingLiteralBullets(in: source),
            """
            - Parent
              - Child
            Text • stays inline
            ```text
            • stays literal in code
            ```
            """
        )
    }

    @MainActor
    func testTypingLiteralBulletCreatesAStyledMarkdownList() {
        var text = "• Item"
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { text = $0 }
        )
        let textView = NSTextView()
        textView.string = text

        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        XCTAssertEqual(textView.string, "- Item")
        XCTAssertEqual(text, "- Item")
    }

    @MainActor
    func testTabIndentsAndShiftTabOutdentsMarkdownListItem() {
        var text = "- Parent\n- Child"
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { text = $0 }
        )
        let textView = NSTextView()
        textView.string = text
        textView.setSelectedRange(NSRange(location: 12, length: 0))

        XCTAssertTrue(coordinator.textView(
            textView,
            doCommandBy: #selector(NSResponder.insertTab(_:))
        ))
        XCTAssertEqual(textView.string, "- Parent\n    - Child")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 16, length: 0))

        XCTAssertTrue(coordinator.textView(
            textView,
            doCommandBy: #selector(NSResponder.insertBacktab(_:))
        ))
        XCTAssertEqual(textView.string, "- Parent\n- Child")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 12, length: 0))
    }

    @MainActor
    func testTabAndShiftTabRenumberOrderedListsAtTheNewHierarchyLevel() {
        var text = "1. Parent\n2. Child"
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { text = $0 }
        )
        let textView = NSTextView()
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))

        XCTAssertTrue(coordinator.textView(
            textView,
            doCommandBy: #selector(NSResponder.insertTab(_:))
        ))
        XCTAssertEqual(textView.string, "1. Parent\n    1. Child")
        XCTAssertEqual(textView.selectedRange().location, (textView.string as NSString).length)

        XCTAssertTrue(coordinator.textView(
            textView,
            doCommandBy: #selector(NSResponder.insertBacktab(_:))
        ))
        XCTAssertEqual(textView.string, "1. Parent\n2. Child")
        XCTAssertEqual(textView.selectedRange().location, (textView.string as NSString).length)
    }

    @MainActor
    func testFieldEditorTabCommandIndentsMarkdownListItem() {
        var text = "- Item"
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { text = $0 }
        )
        let textView = NSTextView()
        textView.string = text
        textView.setSelectedRange(NSRange(location: 2, length: 0))

        XCTAssertTrue(coordinator.textView(
            textView,
            doCommandBy: NSSelectorFromString("insertTabIgnoringFieldEditor:")
        ))
        XCTAssertEqual(textView.string, "    - Item")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 0))
    }

    @MainActor
    func testTabIndentsAndShiftTabOutdentsMultipleSelectedListItems() {
        var text = "- One\n- Two\n- Three"
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { text = $0 }
        )
        let textView = NSTextView()
        textView.string = text
        textView.setSelectedRange(NSRange(location: 0, length: 11))

        XCTAssertTrue(coordinator.textView(
            textView,
            doCommandBy: #selector(NSResponder.insertTab(_:))
        ))
        XCTAssertEqual(textView.string, "    - One\n    - Two\n- Three")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 19))

        XCTAssertTrue(coordinator.textView(
            textView,
            doCommandBy: #selector(NSResponder.insertBacktab(_:))
        ))
        XCTAssertEqual(textView.string, "- One\n- Two\n- Three")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 11))
    }

    @MainActor
    func testTabIsNotConsumedOutsideMarkdownListItem() {
        var text = "Paragraph"
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { text = $0 }
        )
        let textView = NSTextView()
        textView.string = text

        XCTAssertFalse(coordinator.textView(
            textView,
            doCommandBy: #selector(NSResponder.insertTab(_:))
        ))
        XCTAssertEqual(textView.string, "Paragraph")
    }

    @MainActor
    func testEnterContinuesBulletedListAtTheSameIndentation() {
        var text = "- Parent\n  - Child"
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { text = $0 }
        )
        let textView = NSTextView()
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))

        XCTAssertTrue(coordinator.textView(
            textView,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        XCTAssertEqual(textView.string, "- Parent\n  - Child\n  - ")
        XCTAssertEqual(textView.selectedRange().location, (textView.string as NSString).length)
    }

    @MainActor
    func testEnterIncrementsNumberedListAndResetsChecklistItem() {
        let cases = [
            ("3. Third", "3. Third\n4. "),
            ("- [x] Done", "- [x] Done\n- [ ] ")
        ]

        for (source, expected) in cases {
            var text = source
            let coordinator = MarkdownEditorController(
                presentation: .styled,
                titlePolicy: .note,
                onTextChange: { text = $0 }
            )
            let textView = NSTextView()
            textView.string = source
            textView.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))

            XCTAssertTrue(coordinator.textView(
                textView,
                doCommandBy: #selector(NSResponder.insertNewline(_:))
            ))
            XCTAssertEqual(textView.string, expected)
        }
    }

    @MainActor
    func testEnterUsesTheCurrentHierarchyNumberForMalformedOrderedMarkdown() {
        var text = "1. Parent\n    2. Child"
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { text = $0 }
        )
        let textView = NSTextView()
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))

        XCTAssertTrue(coordinator.textView(
            textView,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))

        XCTAssertEqual(textView.string, "1. Parent\n    1. Child\n    2. ")
        XCTAssertEqual(textView.selectedRange().location, (textView.string as NSString).length)
    }

    @MainActor
    func testBackspaceAtOrderedListContentStartRemovesTheWholeMarker() {
        var text = "3. Keep the label"
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { text = $0 }
        )
        let textView = NSTextView()
        textView.string = text
        textView.setSelectedRange(NSRange(location: 3, length: 0))

        XCTAssertTrue(coordinator.textView(
            textView,
            doCommandBy: #selector(NSResponder.deleteBackward(_:))
        ))
        XCTAssertEqual(textView.string, "Keep the label")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))
    }

    @MainActor
    func testBackspaceAtBulletedListContentStartRemovesTheWholeMarker() {
        var text = "- Keep the label"
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { text = $0 }
        )
        let textView = NSTextView()
        textView.string = text
        textView.setSelectedRange(NSRange(location: 2, length: 0))

        XCTAssertTrue(coordinator.textView(
            textView,
            doCommandBy: #selector(NSResponder.deleteBackward(_:))
        ))
        XCTAssertEqual(textView.string, "Keep the label")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))
    }

    @MainActor
    func testBackspaceAtNestedListContentStartOutdentsOneWholeLevel() {
        let cases = [
            ("- Parent\n    - Child", "- Parent\n- Child"),
            ("1. Parent\n    1. Child", "1. Parent\n2. Child"),
            ("- [ ] Parent\n    - [ ] Child", "- [ ] Parent\n- [ ] Child"),
            ("- Parent\n\t- Child", "- Parent\n- Child")
        ]

        for (source, expected) in cases {
            var text = source
            let coordinator = MarkdownEditorController(
                presentation: .styled,
                titlePolicy: .note,
                onTextChange: { text = $0 }
            )
            let textView = NSTextView()
            textView.string = source
            textView.setSelectedRange(NSRange(
                location: (source as NSString).range(of: "Child").location,
                length: 0
            ))

            XCTAssertTrue(coordinator.textView(
                textView,
                doCommandBy: #selector(NSResponder.deleteBackward(_:))
            ))
            XCTAssertEqual(textView.string, expected)
            XCTAssertEqual(
                textView.selectedRange(),
                NSRange(
                    location: (expected as NSString).range(of: "Child").location,
                    length: 0
                )
            )
        }
    }

    @MainActor
    func testEnterOnAnEmptyListItemEndsTheList() {
        var text = "- First\n- "
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { text = $0 }
        )
        let textView = NSTextView()
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))

        XCTAssertTrue(coordinator.textView(
            textView,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        XCTAssertEqual(textView.string, "- First\n")
        XCTAssertEqual(textView.selectedRange().location, (textView.string as NSString).length)
    }

}
#endif
