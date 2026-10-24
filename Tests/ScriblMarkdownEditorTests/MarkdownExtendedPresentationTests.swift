#if os(macOS)
import AppKit
import XCTest
import ScriblMarkdown
@testable import ScriblMarkdownEditor

final class MarkdownExtendedPresentationTests: XCTestCase {
    func testLinkParserSupportsInlineTitledAndReferenceLinks() {
        let text = """
        [Inline](https://scribl.ing)
        [Titled](https://scribl.ing/manual "Manual")
        [Scribl][scribl-ref]
        [Collapsed reference][]

        [scribl-ref]: https://scribl.ing
        [collapsed reference]: https://scribl.ing/manual
        """

        let presentation = MarkdownLinkPresentation.parse(in: text, excluding: [])

        XCTAssertEqual(presentation.links.map(\.destination), [
            "https://scribl.ing",
            "https://scribl.ing/manual",
            "https://scribl.ing",
            "https://scribl.ing/manual"
        ])
        XCTAssertEqual(presentation.links.map { (text as NSString).substring(with: $0.labelRange) }, [
            "Inline", "Titled", "Scribl", "Collapsed reference"
        ])
        XCTAssertEqual(presentation.definitionRanges.count, 2)
    }

    func testLinkParserIgnoresLinksInsideCodeFences() throws {
        let text = "```\n[Literal](https://scribl.ing)\n```\n\n[Actual](https://scribl.ing)"
        let codeRanges = MarkdownCodeBlock.blocks(in: text).map(\.sourceRange)

        let presentation = MarkdownLinkPresentation.parse(in: text, excluding: codeRanges)

        XCTAssertEqual(presentation.links.count, 1)
        XCTAssertEqual(
            (text as NSString).substring(with: try XCTUnwrap(presentation.links.first).labelRange),
            "Actual"
        )
    }

    @MainActor
    func testStyledLinksHideSyntaxAndApplyRealLinkAttributes() throws {
        let text = "[Inline link](https://scribl.ing) and [Reference][ref]\n\n[ref]: https://scribl.ing/manual"
        let textView = styledTextView(text)

        for label in ["Inline link", "Reference"] {
            let range = (text as NSString).range(of: label)
            let url = textView.textStorage?.attribute(
                .link,
                at: range.location,
                effectiveRange: nil
            ) as? URL
            XCTAssertNotNil(url)
            XCTAssertEqual(
                textView.textStorage?.attribute(
                    .foregroundColor,
                    at: range.location,
                    effectiveRange: nil
                ) as? NSColor,
                NSColor.linkColor
            )
        }
        XCTAssertEqual(try font(in: textView, at: 0).pointSize, 0.1, accuracy: 0.01)
        let destinationMarker = (text as NSString).range(of: "](https://scribl.ing)")
        XCTAssertEqual(
            try font(in: textView, at: destinationMarker.location).pointSize,
            0.1,
            accuracy: 0.01
        )
        let definition = (text as NSString).range(of: "[ref]: https://scribl.ing/manual")
        XCTAssertEqual(try font(in: textView, at: definition.location).pointSize, 0.1, accuracy: 0.01)
        XCTAssertEqual(textView.renderedLinkMarkerRanges.count, 4)
    }

    func testBlockQuoteParserHandlesBlankLinesListsAndNesting() throws {
        let text = """
        > A multi-line quotation
        > continues on the next line.
        >
        > It can contain another paragraph.
        >
        > - And a list
        > - Inside the quote
        >
        > > This is a nested quotation.
        """

        let lines = MarkdownBlockQuoteLine.lines(in: text, excluding: [])

        XCTAssertEqual(lines.count, 9)
        XCTAssertEqual(lines.map(\.depth), [1, 1, 1, 1, 1, 1, 1, 1, 2])
        XCTAssertEqual(lines.filter { $0.contentRange.length == 0 }.count, 3)
        guard case .unordered = try XCTUnwrap(lines[5].listMarker) else {
            return XCTFail("Expected the quoted list marker to be recognized")
        }
    }

    @MainActor
    func testBlockQuotesHideEveryMarkerAndUseDepthAwareIndentation() throws {
        let text = "> First\n>\n> - List item\n> > Nested"
        let textView = styledTextView(text)

        XCTAssertEqual(textView.renderedBlockQuoteLines.map(\.depth), [1, 1, 1, 2])
        for line in textView.renderedBlockQuoteLines {
            let color = textView.textStorage?.attribute(
                .foregroundColor,
                at: line.markerRange.location,
                effectiveRange: nil
            ) as? NSColor
            XCTAssertEqual(color, NSColor.clear)
        }

        let outerParagraph = try XCTUnwrap(textView.textStorage?.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        let listLocation = (text as NSString).range(of: "> - List item").location
        let listParagraph = try XCTUnwrap(textView.textStorage?.attribute(
            .paragraphStyle,
            at: listLocation,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        let nestedLocation = (text as NSString).range(of: "> > Nested").location
        let nestedParagraph = try XCTUnwrap(textView.textStorage?.attribute(
            .paragraphStyle,
            at: nestedLocation,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        XCTAssertGreaterThan(listParagraph.headIndent, outerParagraph.headIndent)
        XCTAssertGreaterThan(nestedParagraph.headIndent, outerParagraph.headIndent)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let bars = textView.blockQuoteBarRects()
        XCTAssertEqual(bars.count, 2)
        XCTAssertGreaterThan(try XCTUnwrap(bars.first).height, try XCTUnwrap(bars.last).height)
    }

    func testCodeBlockParserSupportsBothFencesAndIndentedCode() {
        let text = """
        ```swift
        let value = "**literal**"
        ```

        ~~~json
        {"value": true}
        ~~~

            indented()
            stillIndented()
        """

        let blocks = MarkdownCodeBlock.blocks(in: text)

        XCTAssertEqual(blocks.count, 3)
        XCTAssertNotNil(blocks[0].openingRange)
        XCTAssertNotNil(blocks[1].closingRange)
        XCTAssertEqual(blocks[2].indentationRanges.count, 2)
    }

    func testCodeBlockParserDoesNotTreatNestedListsAsIndentedCode() {
        let text = "1. Parent\n    1. Child\n        - Grandchild"

        XCTAssertTrue(MarkdownCodeBlock.blocks(in: text).isEmpty)
    }

    func testCodeBlockParserDoesNotTreatEmptyNestedListMarkersAsCode() {
        let text = """
        - Parent
            - 
            + 
            * 
            1. 
        """

        XCTAssertTrue(MarkdownCodeBlock.blocks(in: text).isEmpty)
    }

    @MainActor
    func testFencedCodeUsesOneRenderedBlockAndProtectsItsContents() throws {
        let text = "```swift\n# not a heading\n**not bold**\n```"
        let textView = styledTextView(text)

        XCTAssertEqual(textView.renderedCodeBlocks.count, 1)
        let opening = (text as NSString).range(of: "```swift")
        XCTAssertEqual(try font(in: textView, at: opening.location).pointSize, 0.1, accuracy: 0.01)
        let content = (text as NSString).range(of: "# not a heading")
        XCTAssertTrue(try font(in: textView, at: content.location).isFixedPitch)
        XCTAssertNil(textView.textStorage?.attribute(
            .backgroundColor,
            at: content.location,
            effectiveRange: nil
        ))
    }

    @MainActor
    func testTableHidesStructuralSyntaxAndStylesItsHeader() throws {
        let text = "| Name | Value |\n| :--- | ---: |\n| Alpha | 42 |"
        let textView = styledTextView(text)

        let delimiter = (text as NSString).range(of: "| :--- | ---: |")
        XCTAssertEqual(try font(in: textView, at: delimiter.location).pointSize, 0.1, accuracy: 0.01)
        let header = (text as NSString).range(of: "Name")
        let traits = NSFontManager.shared.traits(of: try font(in: textView, at: header.location))
        XCTAssertTrue(traits.contains(.boldFontMask))
        let separator = (text as NSString).range(of: " | Value")
        XCTAssertEqual(try font(in: textView, at: separator.location).pointSize, MarkdownEditorStyle.referenceBodyFontSize, accuracy: 0.01)
        XCTAssertEqual(
            textView.textStorage?.attribute(.foregroundColor, at: separator.location, effectiveRange: nil)
                as? NSColor,
            NSColor.clear
        )
    }

    @MainActor
    func testTableColumnsAlignAfterInlineFormattingIsApplied() throws {
        let text = """
        | Alignment | Syntax | Example |
        | :--- | :---: | ---: |
        | Left | `:---` | Alpha |
        | Center | `:---:` | 42 |
        | Right | `---:` | $19.99 |
        | Escaped pipe | `\\|` | A \\| B |
        """
        var boundText = text
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { boundText = $0 }
        )
        let textView = MarkdownEditorTextView(
            frame: NSRect(x: 0, y: 0, width: 700, height: 600)
        )
        textView.string = text
        textView.layoutManager?.delegate = coordinator
        coordinator.applyPresentation(to: textView)

        let source = text as NSString
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)

        func xPosition(of substring: String, offset: Int = 0) -> CGFloat {
            let location = source.range(of: substring).location + offset
            let glyph = layoutManager.glyphIndexForCharacter(at: location)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return line.minX + layoutManager.location(forGlyphAt: glyph).x
        }

        XCTAssertEqual(xPosition(of: "Syntax"), xPosition(of: "`:---`", offset: 1), accuracy: 0.5)
        XCTAssertEqual(xPosition(of: "Example"), xPosition(of: "Alpha"), accuracy: 0.5)
    }

    @MainActor
    func testHorizontalRulesRenderAsRulesInsteadOfRawMarkers() throws {
        let text = "Above\n\n---\n\n***\n\nBelow"
        let textView = styledTextView(text)

        XCTAssertEqual(textView.renderedHorizontalRules.count, 2)
        for marker in ["---", "***"] {
            let range = (text as NSString).range(of: marker)
            XCTAssertEqual(try font(in: textView, at: range.location + 1).pointSize, 0.1, accuracy: 0.01)
        }
    }

    @MainActor
    func testFootnotesAndDefinitionsHideTheirStructuralMarkers() throws {
        let text = "Reference[^1] and named[^details]\n\n[^1]: Supporting detail\n[^details]: Longer explanation\n\nTerm\n: Definition text"
        let textView = styledTextView(text)

        let reference = (text as NSString).range(of: "[^1]")
        XCTAssertEqual(textView.renderedFootnoteReferences.map(\.displayText), ["1", "2"])
        XCTAssertEqual(textView.renderedFootnoteDefinitions.map(\.displayText), ["1", "2"])
        XCTAssertNotNil(textView.textStorage?.attribute(
            .link,
            at: reference.location,
            effectiveRange: nil
        ))

        let namedDefinition = (text as NSString).range(of: "[^details]:")
        XCTAssertEqual(
            textView.textStorage?.attribute(
                .foregroundColor,
                at: namedDefinition.location + 2,
                effectiveRange: nil
            ) as? NSColor,
            NSColor.clear
        )
        let content = (text as NSString).range(of: "Supporting detail")
        let paragraph = try XCTUnwrap(textView.textStorage?.attribute(
            .paragraphStyle,
            at: content.location,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.headIndent, 24, accuracy: 0.01)
        XCTAssertGreaterThan(paragraph.paragraphSpacingBefore, 0)
    }

    @MainActor
    func testMathIsPresentedAsReadableInlineAndBlockObjects() {
        let text = "Inline: $E = mc^2$\n\n$$\n\\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}\n$$"
        let textView = styledTextView(text)

        XCTAssertEqual(textView.renderedMath.count, 2)
        XCTAssertEqual(textView.renderedMath.first?.displayText, "E = mc²")
        XCTAssertTrue(textView.renderedMath.last?.displayText.contains("±") == true)
        XCTAssertTrue(textView.renderedMath.last?.displayText.contains("√") == true)
        XCTAssertFalse(textView.renderedMath.first?.isBlock ?? true)
        XCTAssertTrue(textView.renderedMath.last?.isBlock ?? false)
    }

    @MainActor
    func testCommonInlineHTMLHidesTagsAndComments() throws {
        let text = "Shortcut: <kbd>⌘F</kbd>\n\n<details>\n<summary>More</summary>\nBody\n</details>\n\n<!-- hidden -->"
        let textView = styledTextView(text)

        let openingTag = (text as NSString).range(of: "<kbd>")
        XCTAssertEqual(
            textView.textStorage?.attribute(
                .foregroundColor,
                at: openingTag.location,
                effectiveRange: nil
            ) as? NSColor,
            NSColor.clear
        )
        let keycap = try XCTUnwrap(textView.renderedKeycaps.first)
        let rawTextWidth = (keycap.displayText as NSString).size(withAttributes: [
            .font: keycap.font
        ]).width
        XCTAssertGreaterThan(keycap.size.width, rawTextWidth + 8)
        let summary = (text as NSString).range(of: "More")
        let traits = NSFontManager.shared.traits(of: try font(in: textView, at: summary.location))
        XCTAssertTrue(traits.contains(.boldFontMask))
        XCTAssertEqual(textView.renderedDetails.count, 1)
        let body = (text as NSString).range(of: "Body")
        XCTAssertEqual(try font(in: textView, at: body.location).pointSize, 0.1, accuracy: 0.01)
        let comment = (text as NSString).range(of: "<!-- hidden -->")
        XCTAssertEqual(try font(in: textView, at: comment.location).pointSize, 0.1, accuracy: 0.01)
    }

    @MainActor
    func testDetailsToggleUpdatesPortableOpenAttributeAndRevealsBody() throws {
        var text = "<details>\n<summary>More</summary>\nBody\n</details>"
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { text = $0 }
        )
        let textView = MarkdownEditorTextView()
        textView.string = text
        textView.layoutManager?.delegate = coordinator
        coordinator.applyPresentation(to: textView)

        let details = try XCTUnwrap(textView.renderedDetails.first)
        coordinator.setDetailsExpanded(
            true,
            openingTagRange: details.openingTagRange,
            in: textView
        )
        XCTAssertTrue(textView.string.hasPrefix("<details open>"))

        coordinator.applyPresentation(to: textView)
        let body = (textView.string as NSString).range(of: "Body")
        XCTAssertGreaterThan(try font(in: textView, at: body.location).pointSize, 1)
        XCTAssertTrue(try XCTUnwrap(textView.renderedDetails.first).isExpanded)
    }

    @MainActor
    func testInlineMarkdownStylesHideMarkersAndComposeNestedTraits() throws {
        let text = """
        ***both*** ~~strike~~ __strong__ _emphasis_
        **bold with *italic* inside** and *italic with **bold** inside*
        ==highlighted== H~2~O 2^10^
        Escaped: \\*not italic\\* and \\# literal
        Entities: &amp; &copy; &mdash; &#9731;
        """
        let textView = styledTextView(text)

        func traits(of value: String) throws -> NSFontTraitMask {
            let range = (text as NSString).range(of: value)
            return NSFontManager.shared.traits(of: try font(in: textView, at: range.location))
        }

        let bothTraits = try traits(of: "both")
        XCTAssertTrue(bothTraits.contains(.boldFontMask))
        XCTAssertTrue(bothTraits.contains(.italicFontMask))
        let nestedItalicTraits = try traits(of: "italic")
        XCTAssertTrue(nestedItalicTraits.contains(.boldFontMask))
        XCTAssertTrue(nestedItalicTraits.contains(.italicFontMask))
        let nestedBold = (text as NSString).range(of: "bold", options: [], range: NSRange(
            location: (text as NSString).range(of: "italic with").location,
            length: (text as NSString).length - (text as NSString).range(of: "italic with").location
        ))
        let nestedBoldTraits = NSFontManager.shared.traits(
            of: try font(in: textView, at: nestedBold.location)
        )
        XCTAssertTrue(nestedBoldTraits.contains(.boldFontMask))
        XCTAssertTrue(nestedBoldTraits.contains(.italicFontMask))

        let strike = (text as NSString).range(of: "strike")
        XCTAssertNotNil(textView.textStorage?.attribute(
            .strikethroughStyle,
            at: strike.location,
            effectiveRange: nil
        ))
        let highlight = (text as NSString).range(of: "highlighted")
        XCTAssertNotNil(textView.textStorage?.attribute(
            .backgroundColor,
            at: highlight.location,
            effectiveRange: nil
        ))
        let subscriptRange = (text as NSString).range(of: "~2~")
        let superscriptRange = (text as NSString).range(of: "^10^")
        XCTAssertLessThan(
            (textView.textStorage?.attribute(
                .baselineOffset,
                at: subscriptRange.location + 1,
                effectiveRange: nil
            ) as? NSNumber)?.doubleValue ?? 0,
            0
        )
        XCTAssertGreaterThan(
            (textView.textStorage?.attribute(
                .baselineOffset,
                at: superscriptRange.location + 1,
                effectiveRange: nil
            ) as? NSNumber)?.doubleValue ?? 0,
            0
        )
        let escapedStar = (text as NSString).range(of: "\\*not italic")
        XCTAssertEqual(try font(in: textView, at: escapedStar.location).pointSize, 0.1, accuracy: 0.01)
        XCTAssertEqual(
            textView.renderedInlineReplacements.map(\.displayText),
            ["&", "©", "—", "☃"]
        )
    }

    @MainActor
    func testSoftBreakCollapsesToSpaceWhileHardBreakStartsANewLine() throws {
        let text = "Hard break.  \nAfter hard.\nAfter soft."
        var boundText = text
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { boundText = $0 }
        )
        let textView = MarkdownEditorTextView(
            frame: NSRect(x: 0, y: 0, width: 700, height: 300)
        )
        textView.string = text
        textView.layoutManager?.delegate = coordinator
        coordinator.applyPresentation(to: textView)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)

        func lineY(_ value: String) -> CGFloat {
            let location = (text as NSString).range(of: value).location
            let glyph = layoutManager.glyphIndexForCharacter(at: location)
            return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
        }

        XCTAssertNotEqual(lineY("Hard break."), lineY("After hard."))
        XCTAssertEqual(lineY("After hard."), lineY("After soft."), accuracy: 0.01)
    }

    @MainActor
    private func styledTextView(_ text: String) -> MarkdownEditorTextView {
        var boundText = text
        let coordinator = MarkdownEditorController(
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { boundText = $0 }
        )
        let textView = MarkdownEditorTextView(
            frame: NSRect(x: 0, y: 0, width: 700, height: 600)
        )
        textView.string = text
        textView.layoutManager?.delegate = coordinator
        coordinator.applyPresentation(to: textView)
        return textView
    }

    private func font(in textView: NSTextView, at location: Int) throws -> NSFont {
        try XCTUnwrap(
            textView.textStorage?.attribute(.font, at: location, effectiveRange: nil) as? NSFont
        )
    }
}
#endif
