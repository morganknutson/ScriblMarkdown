#if os(macOS)
import AppKit
import XCTest
import ScriblMarkdown
@testable import ScriblMarkdownEditor

final class MarkdownListPresentationTests: XCTestCase {
    func testOrderedListNumberingFollowsHierarchyInsteadOfRawGlobalSequence() {
        let text = """
        1. First
            2. Child
                3. Grandchild
                    4. Great-grandchild
        5. Second
        """

        let items = MarkdownOrderedListItem.items(in: text)

        XCTAssertEqual(items.map(\.rawNumber), [1, 2, 3, 4, 5])
        XCTAssertEqual(items.map(\.displayNumber), [1, 1, 1, 1, 2])
        XCTAssertEqual(items.map(\.indentationLevel), [0, 1, 2, 3, 0])
    }

    func testOrderedListsKeepIndependentSequencesAndIgnoreCodeFences() {
        let text = """
        4. First
        5. Second

        ```text
        8. Not a list
        ```

        7. Separate list
        8. Next
        """

        let items = MarkdownOrderedListItem.items(in: text)

        XCTAssertEqual(items.map(\.displayNumber), [4, 5, 7, 8])
        XCTAssertEqual(Set(items.map(\.listID)).count, 2)
    }

    func testOrderedListLabelsAlternateByDepthAndContinueAlphabetically() {
        let text = """
        1. Parent
            1. First child
            2. Second child
                1. Grandchild
                    1. First great-grandchild
                    2. Second great-grandchild
        """

        let items = MarkdownOrderedListItem.items(in: text)

        XCTAssertEqual(items.map(\.displayLabel), ["1.", "a.", "b.", "1.", "a.", "b."])
    }

    @MainActor
    func testStyledOrderedListsRenderSemanticMarkersAndHideRawNumbers() throws {
        let text = "1. Parent\n    2. Child\n        3. Grandchild\n            4. Great-grandchild\n5. Sibling"
        var boundText = text
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { boundText = $0 }
        )
        let textView = MarkdownEditorTextView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 200)
        )
        textView.string = text
        textView.layoutManager?.delegate = coordinator

        coordinator.applyPresentation(to: textView)

        XCTAssertEqual(
            textView.renderedOrderedLists.map(\.label),
            ["1.", "a.", "1.", "a.", "2."]
        )
        let childNumberRange = try XCTUnwrap(
            MarkdownOrderedListItem.items(in: text).dropFirst().first?.numberRange
        )
        let markerFont = try XCTUnwrap(
            textView.textStorage?.attribute(
                .font,
                at: childNumberRange.location,
                effectiveRange: nil
            ) as? NSFont
        )
        XCTAssertEqual(markerFont.pointSize, 0.1, accuracy: 0.01)

        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let rendered = try XCTUnwrap(textView.renderedOrderedLists.first)
        let rect = try XCTUnwrap(textView.orderedListRect(for: rendered))
        let contentGlyph = layoutManager.glyphIndexForCharacter(
            at: NSMaxRange(rendered.markerRange)
        )
        let contentLine = layoutManager.lineFragmentRect(
            forGlyphAt: contentGlyph,
            effectiveRange: nil
        )
        let baselineOffset = layoutManager.location(forGlyphAt: contentGlyph).y
        let expectedTop = textView.textContainerOrigin.y
            + contentLine.minY
            + baselineOffset
            - rendered.font.ascender
        XCTAssertEqual(rect.minY, expectedTop, accuracy: 0.01)
    }

    @MainActor
    func testFlatOrderedListKeepsSingleAndDoubleDigitItemsAligned() throws {
        let text = (1...10).map { "\($0). Item \($0)" }.joined(separator: "\n")
        var boundText = text
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { boundText = $0 }
        )
        let textView = MarkdownEditorTextView()
        textView.string = text
        textView.layoutManager?.delegate = coordinator

        coordinator.applyPresentation(to: textView)

        let items = MarkdownOrderedListItem.items(in: text)
        let headIndents = try items.map { item in
            try paragraphStyle(in: textView, at: item.markerRange.location).headIndent
        }
        XCTAssertEqual(Set(headIndents).count, 1)
        XCTAssertEqual(Set(textView.renderedOrderedLists.map(\.markerSlotWidth)).count, 1)
    }

    @MainActor
    func testTwoSpaceAndFourSpaceListNestingRenderAtTheSameIndent() throws {
        let twoSpaceIndent = try renderedHeadIndent(for: "- Parent\n  - Child", nestedLine: "  - Child")
        let fourSpaceIndent = try renderedHeadIndent(for: "- Parent\n    - Child", nestedLine: "    - Child")

        XCTAssertEqual(twoSpaceIndent, fourSpaceIndent)
    }

    @MainActor
    func testMixedLegacyAndEditedItemsRenderAtTheSameDepth() throws {
        let text = "- Parent\n  - Legacy child\n    - Edited child"
        var boundText = text
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { boundText = $0 }
        )
        let textView = NSTextView()
        textView.string = text

        coordinator.applyPresentation(to: textView)

        let legacyChild = try paragraphStyle(
            in: textView,
            at: (text as NSString).range(of: "  - Legacy child").location
        )
        let editedChild = try paragraphStyle(
            in: textView,
            at: (text as NSString).range(of: "    - Edited child").location
        )
        XCTAssertEqual(legacyChild.headIndent, editedChild.headIndent)
    }

    @MainActor
    func testStyledChecklistsRenderControlsAndCompletedText() throws {
        let text = "- [ ] Open item\n- [x] Completed item"
        var boundText = text
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { boundText = $0 }
        )
        let textView = MarkdownEditorTextView()
        textView.string = text

        coordinator.applyPresentation(to: textView)

        XCTAssertEqual(textView.renderedChecklists.count, 2)
        XCTAssertFalse(try XCTUnwrap(textView.renderedChecklists.first).isChecked)
        XCTAssertTrue(try XCTUnwrap(textView.renderedChecklists.last).isChecked)
        let firstMarker = try XCTUnwrap(MarkdownChecklistItem.items(in: text).first).markerRange
        let markerFont = try XCTUnwrap(
            textView.textStorage?.attribute(.font, at: firstMarker.location, effectiveRange: nil)
                as? NSFont
        )
        let hiddenMarkerFont = try XCTUnwrap(
            textView.textStorage?.attribute(.font, at: firstMarker.location + 1, effectiveRange: nil)
                as? NSFont
        )
        XCTAssertEqual(markerFont.pointSize, MarkdownEditorStyle.referenceBodyFontSize, accuracy: 0.01)
        XCTAssertEqual(hiddenMarkerFont.pointSize, 0.1, accuracy: 0.01)
        let completedRange = (text as NSString).range(of: "Completed item")
        let strike = textView.textStorage?.attribute(
            .strikethroughStyle,
            at: completedRange.location,
            effectiveRange: nil
        ) as? NSNumber
        XCTAssertEqual(strike?.intValue, NSUnderlineStyle.single.rawValue)
    }

    @MainActor
    func testChecklistControlAlignsToTheTextBaseline() throws {
        let text = "- [ ] Align me"
        var boundText = text
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { boundText = $0 }
        )
        let textView = MarkdownEditorTextView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 120)
        )
        textView.string = text
        textView.layoutManager?.delegate = coordinator

        coordinator.applyPresentation(to: textView)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let rendered = try XCTUnwrap(textView.renderedChecklists.first)
        let rect = try XCTUnwrap(textView.checklistRect(for: rendered))
        let contentGlyph = layoutManager.glyphIndexForCharacter(
            at: NSMaxRange(rendered.markerRange)
        )
        let contentLine = layoutManager.lineFragmentRect(
            forGlyphAt: contentGlyph,
            effectiveRange: nil
        )
        let baselineOffset = layoutManager.location(forGlyphAt: contentGlyph).y
        let expectedCenter = textView.textContainerOrigin.y
            + contentLine.minY
            + baselineOffset
            - rendered.font.capHeight / 2

        XCTAssertEqual(rect.midY, expectedCenter, accuracy: 0.01)
    }

    @MainActor
    func testEmptySemanticListItemsKeepTheBodyLineHeight() throws {
        let text = "1. Filled\n2. \n- [ ] Filled\n- [ ] "
        var boundText = text
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { boundText = $0 }
        )
        let textView = MarkdownEditorTextView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 240)
        )
        textView.string = text
        textView.layoutManager?.delegate = coordinator

        coordinator.applyPresentation(to: textView)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)

        func lineHeight(at location: Int) -> CGFloat {
            let glyph = layoutManager.glyphIndexForCharacter(at: location)
            return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).height
        }

        let orderedItems = MarkdownOrderedListItem.items(in: text)
        let checklistItems = MarkdownChecklistItem.items(in: text)
        XCTAssertEqual(
            lineHeight(at: try XCTUnwrap(orderedItems.first).markerRange.location),
            lineHeight(at: try XCTUnwrap(orderedItems.last).markerRange.location),
            accuracy: 0.01
        )
        XCTAssertEqual(
            lineHeight(at: try XCTUnwrap(checklistItems.first).markerRange.location),
            lineHeight(at: try XCTUnwrap(checklistItems.last).markerRange.location),
            accuracy: 0.01
        )
    }

    @MainActor
    func testEmptyOrderedListMarkersFollowTheSameVerticalRhythm() throws {
        let text = "1. Filled\n2. \n3. Filled\n4. \n5. Filled"
        var boundText = text
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { boundText = $0 }
        )
        let textView = MarkdownEditorTextView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        textView.string = text
        textView.layoutManager?.delegate = coordinator

        coordinator.applyPresentation(to: textView)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let markerTops = try textView.renderedOrderedLists.map { rendered in
            try XCTUnwrap(textView.orderedListRect(for: rendered)).minY
        }
        let intervals = zip(markerTops.dropFirst(), markerTops).map { next, previous in
            next - previous
        }

        XCTAssertEqual(intervals.count, 4)
        for interval in intervals.dropFirst() {
            XCTAssertEqual(
                interval,
                intervals[0],
                accuracy: 0.01,
                "marker tops: \(markerTops); intervals: \(intervals)"
            )
        }
    }

    @MainActor
    func testEmptyChecklistControlsFollowTheSameVerticalRhythm() throws {
        let text = "- [ ] Filled\n- [ ] \n- [ ] Filled\n- [ ] \n- [ ] Filled"
        var boundText = text
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { boundText = $0 }
        )
        let textView = MarkdownEditorTextView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        textView.string = text
        textView.layoutManager?.delegate = coordinator

        coordinator.applyPresentation(to: textView)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let controlCenters = try textView.renderedChecklists.map { rendered in
            try XCTUnwrap(textView.checklistRect(for: rendered)).midY
        }
        let intervals = zip(controlCenters.dropFirst(), controlCenters).map { next, previous in
            next - previous
        }

        XCTAssertEqual(intervals.count, 4)
        for interval in intervals.dropFirst() {
            XCTAssertEqual(
                interval,
                intervals[0],
                accuracy: 0.01,
                "control centers: \(controlCenters); intervals: \(intervals)"
            )
        }
    }

    @MainActor
    func testChecklistToggleChangesOnlyThePortableMarkdownState() throws {
        var text = "- [ ] Keep the label"
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { text = $0 }
        )
        let textView = MarkdownEditorTextView()
        textView.delegate = coordinator
        textView.string = text
        let item = try XCTUnwrap(MarkdownChecklistItem.items(in: text).first)

        coordinator.setChecklistState(true, stateRange: item.stateRange, in: textView)

        XCTAssertEqual(textView.string, "- [x] Keep the label")
        XCTAssertEqual(text, "- [x] Keep the label")
    }

    @MainActor
    func testBackspaceAtChecklistContentStartRemovesTheWholeMarker() {
        var text = "- [ ] Keep the label"
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { text = $0 }
        )
        let textView = MarkdownEditorTextView()
        textView.delegate = coordinator
        textView.string = text
        textView.setSelectedRange(NSRange(location: 6, length: 0))

        XCTAssertTrue(coordinator.textView(
            textView,
            doCommandBy: #selector(NSResponder.deleteBackward(_:))
        ))
        XCTAssertEqual(textView.string, "Keep the label")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))
    }

    @MainActor
    private func renderedHeadIndent(for text: String, nestedLine: String) throws -> CGFloat {
        var boundText = text
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { boundText = $0 }
        )
        let textView = NSTextView()
        textView.string = text
        coordinator.applyPresentation(to: textView)
        return try paragraphStyle(
            in: textView,
            at: (text as NSString).range(of: nestedLine).location
        ).headIndent
    }

    private func paragraphStyle(in textView: NSTextView, at location: Int) throws -> NSParagraphStyle {
        try XCTUnwrap(
            textView.textStorage?.attribute(.paragraphStyle, at: location, effectiveRange: nil)
                as? NSParagraphStyle
        )
    }
}
#endif
