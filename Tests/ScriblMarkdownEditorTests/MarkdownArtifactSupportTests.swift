#if os(macOS)
import AppKit
import Foundation
import XCTest
import ScriblMarkdown
@testable import ScriblMarkdownEditor

final class MarkdownArtifactSupportTests: XCTestCase {
    func testLinkableFilePasteboardFallsBackToDocumentPayload() throws {
        let pasteboard = NSPasteboard(name: .init("SketchNotePayload.\(UUID().uuidString)"))
        let sketchURL = URL(fileURLWithPath: "/Notes/Brainstorm.tldr")
        pasteboard.clearContents()
        pasteboard.writeObjects([sketchURL as NSURL])

        let payload = try XCTUnwrap(MarkdownDocumentDragPayload.read(
            from: pasteboard,
            linkableExtensions: ["md", "tldr"]
        ))
        XCTAssertEqual(payload.fileURL, sketchURL)
        XCTAssertEqual(payload.title, "Brainstorm")
    }

    func testArtifactInsertionCreatesStandaloneBlockBesideExistingText() throws {
        let source = "First line\nSecond line"
        let firstLineEnd = ("First line" as NSString).length
        let insertion = try XCTUnwrap(MarkdownArtifactInsertion.insertion(
            ["[Target](Target.md)"],
            in: source,
            near: firstLineEnd
        ))
        let result = NSMutableString(string: source)
        result.insert(insertion.text, at: insertion.location)

        XCTAssertEqual(result as String, "First line\n[Target](Target.md)\nSecond line")
        XCTAssertEqual(
            MarkdownArtifactParser().artifacts(in: result as String).count,
            1
        )
    }

    func testParserFindsOnlyStandaloneWebAndNoteArtifactsOutsideCode() {
        let current = URL(fileURLWithPath: "/Notes/Current.md")
        let linked = URL(fileURLWithPath: "/Notes/Project Brief.md")
        let markdown = """
        https://example.com/path?q=1

        A URL in prose https://example.com is not a card.
        [Website](https://example.com)
        ![Image](Picture.png)
        `https://inline.example`
        ```
        https://code.example
        [Project](Project%20Brief.md)
        ```
        [Project](Project%20Brief.md)
        """

        let artifacts = MarkdownArtifactParser().artifacts(
            in: markdown,
            noteURL: current,
            libraryURLs: [current, linked]
        )

        XCTAssertEqual(artifacts.count, 2)
        guard case .web(let url) = artifacts[0].kind else { return XCTFail("Expected web artifact") }
        XCTAssertEqual(url.absoluteString, "https://example.com/path?q=1")
        guard case .note(let reference) = artifacts[1].kind else { return XCTFail("Expected note artifact") }
        XCTAssertEqual(reference.state, .resolved(linked))
    }

    func testNoteStatesCoverSelfMissingAndUnicodeResolution() {
        let current = URL(fileURLWithPath: "/Notes/Café.md")
        let linked = URL(fileURLWithPath: "/Notes/旅行.md")
        let markdown = "[Self](Caf%C3%A9.md)\n[Trip](%E6%97%85%E8%A1%8C.md)\n[Gone](Gone.md)"
        let artifacts = MarkdownArtifactParser().artifacts(
            in: markdown,
            noteURL: current,
            libraryURLs: [current, linked]
        )

        XCTAssertEqual(artifacts.count, 3)
        XCTAssertEqual(noteState(artifacts[0]), .selfLink)
        XCTAssertEqual(noteState(artifacts[1]), .resolved(linked))
        XCTAssertEqual(noteState(artifacts[2]), .missing)
    }

    func testPortableNoteLinkUsesRelativeEncodedPath() {
        let source = URL(fileURLWithPath: "/Notes/Projects/Current.md")
        let target = URL(fileURLWithPath: "/Notes/Archive/Project Brief.md")
        XCTAssertEqual(
            MarkdownNoteLink.markdown(title: "Project Brief", targetURL: target, from: source),
            "[Project Brief](../Archive/Project%20Brief.md)"
        )
        XCTAssertNil(MarkdownNoteLink.markdown(title: "Self", targetURL: source, from: source))
    }

    func testRangesAreUTF16AndReorderMovesCompleteBlock() {
        let markdown = "🙂 first\nhttps://example.com\nlast\n"
        let artifact = try! XCTUnwrap(MarkdownArtifactParser().artifacts(in: markdown).first)
        XCTAssertEqual(artifact.blockRange.location, ("🙂 first\n" as NSString).length)
        let moved = MarkdownArtifactReorder.move(
            block: artifact.blockRange,
            to: (markdown as NSString).length,
            in: markdown
        )
        XCTAssertEqual(moved, "🙂 first\nlast\nhttps://example.com\n")
    }

    func testCardContentUsesCompactHeightWithoutUsefulWebSummary() {
        let url = URL(string: "https://example.com/path")!
        let fallback = MarkdownLinkCardContent.web(.fallback(for: url))
        let rich = MarkdownLinkCardContent.web(.init(
            url: url,
            title: "Example",
            summary: "A useful description",
            siteName: "Example",
            thumbnailData: nil
        ))

        XCTAssertNil(fallback.displaySummary)
        XCTAssertEqual(fallback.preferredHeight, 88)
        XCTAssertEqual(rich.displaySummary, "A useful description")
        XCTAssertEqual(rich.preferredHeight, 100)
        XCTAssertEqual(
            MarkdownLinkCardContent.document(
                .note("Note", preview: "  Useful\npreview  "),
                isBroken: false
            ).displaySummary,
            "Useful preview"
        )
    }

    private func noteState(_ artifact: MarkdownArtifact) -> MarkdownNoteReference.State? {
        guard case .note(let reference) = artifact.kind else { return nil }
        return reference.state
    }
}
#endif
