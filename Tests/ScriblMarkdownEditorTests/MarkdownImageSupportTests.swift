#if os(macOS)
import AppKit
import XCTest
import ScriblMarkdown
@testable import ScriblMarkdownEditor

final class MarkdownImageSupportTests: XCTestCase {
    private func makePNGData() throws -> Data {
        let image = NSImage(size: NSSize(width: 32, height: 20))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 32, height: 20).fill()
        image.unlockFocus()
        return try XCTUnwrap(
            image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
                .representation(using: .png, properties: [:])
        )
    }

    func testParsesAndResolvesEncodedRelativeImageReference() throws {
        let noteURL = URL(fileURLWithPath: "/tmp/Notes/Trip.md")
        let reference = try XCTUnwrap(
            MarkdownImageReference.references(in: "![Beach](Assets/Trip/Beach%20Photo.png)").first
        )

        XCTAssertEqual(reference.alternateText, "Beach")
        XCTAssertEqual(
            reference.fileURL(relativeTo: noteURL)?.path,
            "/tmp/Notes/Assets/Trip/Beach Photo.png"
        )
    }

    func testImportCopiesImageIntoNoteAssetsAndReturnsPortableMarkdown() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sourceDirectory = root.appendingPathComponent("Incoming")
        let notesDirectory = root.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = sourceDirectory.appendingPathComponent("My Photo.png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: source)
        let noteURL = notesDirectory.appendingPathComponent("Journal.md")

        let markdown = try XCTUnwrap(MarkdownImageAssetStore().importFile(at: source, for: noteURL))

        XCTAssertEqual(markdown, "![My Photo](Assets/Journal/My%20Photo.png)")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: notesDirectory.appendingPathComponent("Assets/Journal/My Photo.png").path
            )
        )
    }

    func testImageDataImportCreatesPortableLocalAssetPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let noteURL = root.appendingPathComponent("Meeting.html")

        let relativePath = try MarkdownImageAssetStore().importImageData(
            Data([0x89, 0x50, 0x4e, 0x47]),
            preferredName: "Pasted Image.png",
            for: noteURL
        )

        XCTAssertEqual(relativePath, "Assets/Meeting/Pasted%20Image.png")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Assets/Meeting/Pasted Image.png").path
        ))
    }

    @MainActor
    func testMarkdownEditorPastesRawPNGFromPasteboard() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pasteboard = NSPasteboard(name: .init("MarkdownImageSupportTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(try makePNGData(), forType: .init("public.png"))

        var text = "# Note\nBody"
        let noteURL = root.appendingPathComponent("Note.md")
        let coordinator = MarkdownEditorController(
            documentURL: noteURL,
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { text = $0 }
        )
        let textView = MarkdownEditorTextView()
        textView.delegate = coordinator
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        textView.importImages = { urls, image, range in
            coordinator.importImages(at: urls, pastedImage: image, range: range, into: textView)
        }

        XCTAssertTrue(textView.pasteImage(from: pasteboard))
        XCTAssertTrue(textView.string.contains("![Pasted Image](Assets/Note/Pasted%20Image.png)"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Assets/Note/Pasted Image.png").path
        ))
    }

    func testInsertionKeepsImagesInline() {
        XCTAssertEqual(
            MarkdownImageAssetStore.insertion(markdown: ["![Image](image.png)"], in: "beforeafter", at: 6),
            "![Image](image.png)"
        )
        XCTAssertEqual(
            MarkdownImageAssetStore.insertion(
                markdown: ["![One](one.png)", "![Two](two.png)"],
                in: "before\nafter",
                at: 7
            ),
            "![One](one.png) ![Two](two.png)"
        )
    }

    func testImageSelectionExpandsToWholeMarkdownReference() {
        let imageRange = NSRange(location: 5, length: 20)
        XCTAssertEqual(
            MarkdownImageEditing.expandedSelection(
                NSRange(location: 8, length: 4),
                imageRanges: [imageRange]
            ),
            imageRange
        )
        XCTAssertEqual(
            MarkdownImageEditing.expandedSelection(
                NSRange(location: 2, length: 8),
                imageRanges: [imageRange]
            ),
            NSRange(location: 2, length: 23)
        )
    }

    func testArrowNavigationSkipsWholeImageReference() {
        let imageRange = NSRange(location: 5, length: 20)
        XCTAssertEqual(
            MarkdownImageEditing.movementDestination(
                for: NSRange(location: 5, length: 0),
                forward: true,
                imageRanges: [imageRange]
            ),
            25
        )
        XCTAssertEqual(
            MarkdownImageEditing.movementDestination(
                for: NSRange(location: 25, length: 0),
                forward: false,
                imageRanges: [imageRange]
            ),
            5
        )
    }

    func testDeleteAtImageBoundaryRemovesWholeReference() {
        let imageRange = NSRange(location: 5, length: 20)
        XCTAssertEqual(
            MarkdownImageEditing.deletionRange(
                for: NSRange(location: 25, length: 0),
                forward: false,
                imageRanges: [imageRange]
            ),
            imageRange
        )
        XCTAssertEqual(
            MarkdownImageEditing.deletionRange(
                for: NSRange(location: 5, length: 0),
                forward: true,
                imageRanges: [imageRange]
            ),
            imageRange
        )
        XCTAssertEqual(
            MarkdownImageEditing.deletionRange(
                for: NSRange(location: 10, length: 2),
                forward: false,
                imageRanges: [imageRange]
            ),
            imageRange
        )
    }

    func testImageReorderMovesExactReferenceWithoutChangingMarkdownSource() throws {
        let markdown = "A ![One](one.png) B ![Two](two.png) C"
        let reference = try XCTUnwrap(MarkdownImageReference.references(in: markdown).first)
        let payload = MarkdownImageReorderPayload(
            referenceLocation: reference.range.location,
            referenceLength: reference.range.length,
            source: (markdown as NSString).substring(with: reference.range)
        )
        let result = try XCTUnwrap(MarkdownImageEditing.move(
            payload: payload,
            to: (markdown as NSString).length,
            in: markdown
        ))

        XCTAssertEqual(result.markdown, "A  B ![Two](two.png) C![One](one.png)")
        XCTAssertEqual(
            (result.markdown as NSString).substring(with: result.selection),
            "![One](one.png)"
        )
    }

    @MainActor
    func testImageReorderPreservesCaretOutsideMovedReference() throws {
        var markdown = "Caret here\n![One](one.png)\nMore text\n"
        let coordinator = MarkdownEditorController(
            documentURL: URL(fileURLWithPath: "/Notes/Current.md"),
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { markdown = $0 }
        )
        let textView = MarkdownEditorTextView()
        textView.delegate = coordinator
        textView.string = markdown
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        let reference = try XCTUnwrap(MarkdownImageReference.references(in: markdown).first)
        let payload = MarkdownImageReorderPayload(
            referenceLocation: reference.range.location,
            referenceLength: reference.range.length,
            source: (markdown as NSString).substring(with: reference.range)
        )

        XCTAssertTrue(coordinator.reorderImage(
            payload,
            to: (markdown as NSString).length,
            in: textView
        ))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 3, length: 0))
        XCTAssertTrue(textView.string.hasSuffix("![One](one.png)"))
    }

    @MainActor
    func testEditorAcceptsImageAndArtifactReorderDrops() throws {
        let textView = MarkdownEditorTextView()
        let pasteboard = NSPasteboard(name: .init("MarkdownReorderDropTests.\(UUID().uuidString)"))
        let imagePayload = MarkdownImageReorderPayload(
            referenceLocation: 0,
            referenceLength: 20,
            source: "![Image](image.png)"
        )
        let artifactPayload = ArtifactReorderDragPayload(
            blockLocation: 0,
            blockLength: 20,
            source: "https://example.com"
        )

        pasteboard.clearContents()
        pasteboard.setData(try JSONEncoder().encode(imagePayload), forType: MarkdownImageReorderPayload.pasteboardType)
        XCTAssertTrue(textView.acceptsEditorReorderDrop(from: pasteboard))

        pasteboard.clearContents()
        pasteboard.setData(try JSONEncoder().encode(artifactPayload), forType: ArtifactReorderDragPayload.pasteboardType)
        XCTAssertTrue(textView.acceptsEditorReorderDrop(from: pasteboard))
    }

    @MainActor
    func testStyledPresentationRendersLocalImageWithoutChangingMarkdown() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let assetDirectory = root.appendingPathComponent("Assets/Note")
        try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let image = NSImage(size: NSSize(width: 320, height: 180))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 320, height: 180).fill()
        image.unlockFocus()
        let data = try XCTUnwrap(
            image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
                .representation(using: .png, properties: [:])
        )
        try data.write(to: assetDirectory.appendingPathComponent("Preview.png"))

        let markdown = "![Preview](Assets/Note/Preview.png)"
        var boundText = markdown
        let coordinator = MarkdownEditorController(
            documentURL: root.appendingPathComponent("Note.md"),
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { boundText = $0 }
        )
        let textView = MarkdownEditorTextView()
        textView.frame.size.width = 700
        textView.string = markdown

        coordinator.applyPresentation(to: textView)

        XCTAssertEqual(textView.renderedImages.count, 1)
        XCTAssertEqual(textView.renderedImages[0].range, NSRange(location: 0, length: (markdown as NSString).length))
        XCTAssertEqual(textView.string, markdown)
        XCTAssertEqual(boundText, markdown)
    }

    @MainActor
    func testStyledImageReservesInlineLayoutSpaceAndKeepsFollowingTextOnLine() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let assetDirectory = root.appendingPathComponent("Assets/Note")
        try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let image = NSImage(size: NSSize(width: 80, height: 40))
        image.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: 80, height: 40).fill()
        image.unlockFocus()
        let data = try XCTUnwrap(
            image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
                .representation(using: .png, properties: [:])
        )
        try data.write(to: assetDirectory.appendingPathComponent("Inline.png"))

        let reference = "![Inline](Assets/Note/Inline.png)"
        let markdown = reference + " after"
        let coordinator = MarkdownEditorController(
            documentURL: root.appendingPathComponent("Note.md"),
            presentation: .styled,
            titlePolicy: .note
        )
        let textView = MarkdownEditorTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        textView.textContainer?.containerSize = NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        textView.layoutManager?.delegate = coordinator
        textView.string = markdown

        coordinator.applyPresentation(to: textView)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)

        let imageGlyph = layoutManager.glyphIndexForCharacter(at: 0)
        let followingGlyph = layoutManager.glyphIndexForCharacter(at: (reference as NSString).length + 1)
        let imageRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: imageGlyph, length: 1),
            in: textContainer
        )
        let followingRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: followingGlyph, length: 1),
            in: textContainer
        )
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: imageGlyph, effectiveRange: nil)

        XCTAssertEqual(imageRect.width, 80, accuracy: 1)
        XCTAssertGreaterThanOrEqual(followingRect.minX, imageRect.maxX)
        XCTAssertEqual(followingRect.minY, imageRect.minY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(lineRect.height, 40)
        XCTAssertEqual(textView.string, markdown)
    }

    @MainActor
    func testStyledEditorDeletesSelectedImageAsOneObject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let assetDirectory = root.appendingPathComponent("Assets/Note")
        try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try makePNGData().write(to: assetDirectory.appendingPathComponent("Delete.png"))

        let reference = "![Delete](Assets/Note/Delete.png)"
        var markdown = "Before \(reference) After"
        let coordinator = MarkdownEditorController(
            documentURL: root.appendingPathComponent("Note.md"),
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { markdown = $0 }
        )
        let textView = MarkdownEditorTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        textView.delegate = coordinator
        textView.string = markdown
        coordinator.applyPresentation(to: textView)
        let range = try XCTUnwrap(MarkdownImageReference.references(in: markdown).first?.range)
        textView.setSelectedRange(range)

        XCTAssertTrue(coordinator.textView(textView, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
        XCTAssertEqual(textView.string, "Before  After")
        XCTAssertFalse(textView.string.contains("!["))
    }

    @MainActor
    func testTypingBeforeStyledImageKeepsCaretBeforeImage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let assetDirectory = root.appendingPathComponent("Assets/Note")
        try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try makePNGData().write(to: assetDirectory.appendingPathComponent("Inline.png"))

        let reference = "![Inline](Assets/Note/Inline.png)"
        var markdown = reference
        let coordinator = MarkdownEditorController(
            documentURL: root.appendingPathComponent("Note.md"),
            presentation: .styled,
            titlePolicy: .note,
            onTextChange: { markdown = $0 }
        )
        let textView = MarkdownEditorTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        textView.delegate = coordinator
        textView.string = markdown
        coordinator.applyPresentation(to: textView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        XCTAssertTrue(coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: 0, length: 0),
            replacementString: " "
        ))
        textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: " ")
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        coordinator.textViewDidChangeSelection(Notification(
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        ))

        XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 0))

        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        XCTAssertEqual(textView.string, " " + reference)
        XCTAssertEqual(markdown, " " + reference)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 0))
    }
}
#endif
