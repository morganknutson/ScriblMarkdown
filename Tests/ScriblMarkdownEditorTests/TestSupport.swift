import AppKit
@testable import ScriblMarkdownEditor

extension MarkdownEditorTitlePolicy {
    /// Scribl's note title behavior, which most editor behavior tests exercise.
    static let note = MarkdownEditorTitlePolicy.protectedLeadingHeading(placeholder: "Untitled Note")
}

/// A host whose linkable documents and openings the test controls.
final class TestMarkdownEditorHost: MarkdownEditorHost {
    var documents: [URL: MarkdownLinkedDocument]
    let linkableDocumentExtensions: Set<String>
    private(set) var openedURLs: [URL] = []

    init(
        documents: [URL: MarkdownLinkedDocument] = [:],
        linkableDocumentExtensions: Set<String> = ["md", "markdown"]
    ) {
        self.documents = documents
        self.linkableDocumentExtensions = linkableDocumentExtensions
    }

    var linkableDocumentURLs: [URL] { Array(documents.keys) }

    func linkedDocument(at url: URL) -> MarkdownLinkedDocument? {
        documents[url]
    }

    func openLinkedDocument(at url: URL) -> Bool {
        guard documents[url] != nil else { return false }
        openedURLs.append(url)
        return true
    }
}

extension MarkdownLinkedDocument {
    static func note(_ title: String, preview: String) -> MarkdownLinkedDocument {
        MarkdownLinkedDocument(
            title: title,
            preview: preview,
            kindLabel: "Note",
            image: NSImage(systemSymbolName: "note.text", accessibilityDescription: nil)
        )
    }
}
