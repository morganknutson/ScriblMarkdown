#if os(macOS)
import AppKit
import XCTest
import ScriblMarkdown
@testable import ScriblMarkdownEditor

@MainActor
final class MarkdownArtifactIntegrationTests: XCTestCase {
    func testStyledEditorMountsNoteCardAndSourceModeRestoresMarkdown() throws {
        let currentURL = URL(fileURLWithPath: "/Notes/Current.md")
        let targetURL = URL(fileURLWithPath: "/Notes/Project Brief.md")
        let host = TestMarkdownEditorHost(documents: [
            targetURL: .note("Project Brief", preview: "A concise preview.")
        ])
        var text = "# Current\n\n[Project Brief](Project%20Brief.md)\n"
        let coordinator = MarkdownEditorController(
            documentURL: currentURL,
            presentation: .styled,
            titlePolicy: .note,
            host: host,
            onTextChange: { text = $0 }
        )
        let textView = MarkdownEditorTextView(frame: NSRect(x: 0, y: 0, width: 620, height: 400))
        textView.string = text
        textView.layoutManager?.delegate = coordinator

        coordinator.applyPresentation(to: textView)
        textView.layoutSubtreeIfNeeded()

        XCTAssertEqual(textView.string, text)
        XCTAssertEqual(textView.renderedArtifacts.count, 1)
        XCTAssertEqual(
            textView.subviews.compactMap { $0 as? ArtifactCardView }.first?.frame.width,
            300
        )
        let card = try XCTUnwrap(
            textView.subviews.compactMap { $0 as? ArtifactCardView }.first
        )
        let artifactRange = try XCTUnwrap(textView.renderedArtifacts.first?.artifact.sourceRange)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        let artifactGlyph = layoutManager.glyphIndexForCharacter(at: artifactRange.location)
        let artifactGlyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: artifactGlyph, length: 1),
            in: textContainer
        )
        XCTAssertEqual(artifactGlyphRect.width, card.frame.width + 8, accuracy: 1)
        XCTAssertGreaterThan(card.frame.minX, textView.textContainerOrigin.x + artifactGlyphRect.minX)
        XCTAssertLessThan(card.frame.maxX, textView.textContainerOrigin.x + artifactGlyphRect.maxX)
        let proposedCaret = NSRect(x: 100, y: 100, width: 1, height: 20)
        textView.setSelectedRange(NSRange(location: artifactRange.location, length: 0))
        XCTAssertEqual(textView.insertionPointRect(for: proposedCaret), proposedCaret)
        textView.setSelectedRange(NSRange(location: NSMaxRange(artifactRange), length: 0))
        XCTAssertEqual(textView.insertionPointRect(for: proposedCaret), proposedCaret)

        textView.setSelectedRange(NSRange(location: artifactRange.location + 1, length: 0))
        coordinator.textViewDidChangeSelection(Notification(
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        ))
        XCTAssertEqual(textView.selectedRange().location, NSMaxRange(artifactRange))

        guard case .document(let document, let broken) = textView.renderedArtifacts[0].content else {
            return XCTFail("Expected a note card")
        }
        XCTAssertEqual(document.title, "Project Brief")
        XCTAssertTrue(document.preview.contains("concise preview"))
        XCTAssertEqual(document.kindLabel, "Note")
        XCTAssertFalse(broken)

        coordinator.presentation = .source
        coordinator.applyPresentation(to: textView)
        XCTAssertTrue(textView.renderedArtifacts.isEmpty)
        XCTAssertEqual(textView.string, text)
    }


    func testNoteInsertionRejectsSelfAndCreatesPortableLink() {
        let currentURL = URL(fileURLWithPath: "/Notes/Current.md")
        let targetURL = URL(fileURLWithPath: "/Notes/Archive/Project Brief.md")
        let sketchURL = URL(fileURLWithPath: "/Notes/Sketch.tldr")
        var text = "# Current\n\n"
        let host = TestMarkdownEditorHost(linkableDocumentExtensions: ["md", "tldr"])
        let coordinator = MarkdownEditorController(
            documentURL: currentURL,
            presentation: .styled,
            titlePolicy: .note,
            host: host,
            onTextChange: { text = $0 }
        )
        let textView = MarkdownEditorTextView()
        textView.delegate = coordinator
        textView.string = text

        XCTAssertFalse(coordinator.insertNotePayload(
            .init(fileURL: currentURL, title: "Current"),
            at: NSRange(location: (text as NSString).length, length: 0),
            into: textView
        ))
        XCTAssertTrue(coordinator.insertNotePayload(
            .init(fileURL: targetURL, title: "Project Brief"),
            at: NSRange(location: (textView.string as NSString).length, length: 0),
            into: textView
        ))
        XCTAssertTrue(textView.string.contains("[Project Brief](Archive/Project%20Brief.md)"))
        XCTAssertTrue(coordinator.insertNotePayload(
            .init(fileURL: sketchURL, title: "Sketch"),
            at: NSRange(location: (textView.string as NSString).length, length: 0),
            into: textView
        ))
        XCTAssertTrue(textView.string.contains("[Sketch](Sketch.tldr)"))
    }

    func testSidebarNoteInsertionPreservesViewportAndExistingCaret() {
        let currentURL = URL(fileURLWithPath: "/Notes/Current.md")
        let targetURL = URL(fileURLWithPath: "/Notes/Target.md")
        var text = (0..<180).map { "Paragraph \($0)" }.joined(separator: "\n\n")
        let coordinator = MarkdownEditorController(
            documentURL: currentURL,
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { text = $0 }
        )
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        let textView = MarkdownEditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 4_000))
        textView.delegate = coordinator
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        scrollView.documentView = textView
        coordinator.applyPresentation(to: textView)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 900))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        let viewportBeforeDrop = scrollView.contentView.bounds.origin
        let dropPoint = NSPoint(x: 40, y: scrollView.contentView.bounds.midY)
        let dropLocation = textView.characterIndexForInsertion(at: dropPoint)
        let expectedInsertion = try! XCTUnwrap(MarkdownArtifactInsertion.insertion(
            ["[Target](Target.md)"],
            in: text,
            near: dropLocation
        ))

        XCTAssertTrue(coordinator.insertNotePayload(
            .init(fileURL: targetURL, title: "Target"),
            at: NSRange(location: dropLocation, length: 0),
            into: textView
        ))

        XCTAssertEqual(scrollView.contentView.bounds.origin, viewportBeforeDrop)
        XCTAssertEqual(
            textView.selectedRange(),
            NSRange(
                location: expectedInsertion.location + (expectedInsertion.text as NSString).length,
                length: 0
            )
        )
    }

    func testMultipleWebURLsInsertInOneEditAndReorderUsesBackingMarkdown() throws {
        var text = "before\nafter\n"
        var updateCount = 0
        let coordinator = MarkdownEditorController(
            documentURL: URL(fileURLWithPath: "/Notes/Current.md"),
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { text = $0; updateCount += 1 }
        )
        let textView = MarkdownEditorTextView()
        textView.delegate = coordinator
        textView.allowsUndo = true
        textView.string = text

        XCTAssertTrue(coordinator.insertWebURLs(
            [URL(string: "https://one.example")!, URL(string: "https://two.example")!],
            at: NSRange(location: ("before\n" as NSString).length, length: 0),
            into: textView
        ))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        XCTAssertTrue(textView.string.contains("https://one.example\nhttps://two.example"))

        let artifact = try XCTUnwrap(MarkdownArtifactParser().artifacts(in: textView.string).first)
        let payload = ArtifactReorderDragPayload(
            blockLocation: artifact.blockRange.location,
            blockLength: artifact.blockRange.length,
            source: artifact.source
        )
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertTrue(coordinator.reorderArtifact(
            payload,
            to: (textView.string as NSString).length,
            in: textView
        ))
        XCTAssertTrue(textView.string.hasSuffix("https://one.example\n"))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))
        XCTAssertGreaterThanOrEqual(updateCount, 2)
    }

    func testCardAccessibilityAndActivation() throws {
        let targetURL = URL(fileURLWithPath: "/Notes/Target.md")
        let host = TestMarkdownEditorHost(documents: [targetURL: .note("Target", preview: "Preview")])
        let coordinator = MarkdownEditorController(
            documentURL: URL(fileURLWithPath: "/Notes/Current.md"),
            presentation: .styled,
            titlePolicy: .note,
            host: host
        )
        let artifact = try XCTUnwrap(MarkdownArtifactParser().artifacts(
            in: "[Target](Target.md)",
            noteURL: URL(fileURLWithPath: "/Notes/Current.md"),
            libraryURLs: [targetURL]
        ).first)

        coordinator.activate(artifact)
        XCTAssertEqual(host.openedURLs, [targetURL])

        let card = ArtifactCardView(frame: NSRect(x: 0, y: 0, width: 320, height: ArtifactCardView.noteHeight))
        card.configure(.document(.note("Target", preview: "Preview"), isBroken: false))
        card.layoutSubtreeIfNeeded()
        XCTAssertEqual(card.accessibilityRole(), .button)
        XCTAssertTrue((card.accessibilityLabel() ?? "").contains("Target"))
        XCTAssertTrue(card.hitTest(NSPoint(x: 150, y: 44)) === card)
    }

    @MainActor
    func testFallbackLinkIconMatchesBareNoteIconTreatment() throws {
        let card = ArtifactCardView(
            frame: NSRect(x: 0, y: 0, width: 320, height: ArtifactCardView.noteHeight)
        )
        card.configure(.document(.note("Note", preview: "Preview"), isBroken: false))
        card.layoutSubtreeIfNeeded()
        let noteImageView = try XCTUnwrap(card.subviews.first?.subviews.first as? NSImageView)
        let noteIconDimensions = activeIconDimensions(of: noteImageView)

        card.configure(.web(.fallback(for: try XCTUnwrap(URL(string: "https://scribl.ing")))))
        card.layoutSubtreeIfNeeded()
        let linkImageView = try XCTUnwrap(card.subviews.first?.subviews.first as? NSImageView)

        XCTAssertEqual(activeIconDimensions(of: linkImageView), noteIconDimensions)
        XCTAssertEqual(activeIconDimensions(of: linkImageView), [32, 32])
        XCTAssertEqual(linkImageView.layer?.cornerRadius, 0)
        XCTAssertEqual(linkImageView.layer?.backgroundColor?.alpha, 0)

        card.configure(.loading(url: try XCTUnwrap(URL(string: "https://scribl.ing"))))
        XCTAssertEqual(activeIconDimensions(of: linkImageView), [32, 32])
        XCTAssertEqual(linkImageView.layer?.backgroundColor?.alpha, 0)
    }

    private func activeIconDimensions(of imageView: NSImageView) -> [CGFloat] {
        imageView.constraints.compactMap { constraint in
            guard constraint.isActive,
                  ["artifact.media.icon.width", "artifact.media.icon.height"]
                    .contains(constraint.identifier) else { return nil }
            return constraint.constant
        }.sorted()
    }
}
#endif
