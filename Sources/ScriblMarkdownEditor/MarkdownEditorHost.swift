#if os(macOS)
import AppKit
import ScriblMarkdown

/// Connects the editor to the app hosting it: the documents its links can embed, how
/// they open, web previews, and diagnostics. Every requirement has a default, so a host
/// only implements what it supports.
public protocol MarkdownEditorHost: AnyObject {
    /// Documents a relative link may embed as a card.
    var linkableDocumentURLs: [URL] { get }
    /// Lowercased path extensions of files that count as linkable documents.
    var linkableDocumentExtensions: Set<String> { get }
    var webLinkMetadataProvider: (any WebLinkMetadataProviding)? { get }
    var codeHighlighter: (any MarkdownCodeHighlighting)? { get }

    /// Card details for a document in `linkableDocumentURLs`, or nil when it can't be described.
    func linkedDocument(at url: URL) -> MarkdownLinkedDocument?
    /// Opens a linked document in place. Returns false to fall back to the system handler.
    func openLinkedDocument(at url: URL) -> Bool
    /// Whether a source edit is allowed. Called before rendered objects are prepared.
    func shouldChangeText(in textView: NSTextView, range: NSRange, replacement: String?) -> Bool
    func recordEditorEvent(_ message: String, metadata: [String: String])
}

public extension MarkdownEditorHost {
    var linkableDocumentURLs: [URL] { [] }
    var linkableDocumentExtensions: Set<String> { ["md", "markdown"] }
    var webLinkMetadataProvider: (any WebLinkMetadataProviding)? { nil }
    var codeHighlighter: (any MarkdownCodeHighlighting)? { nil }

    func linkedDocument(at url: URL) -> MarkdownLinkedDocument? { nil }
    func openLinkedDocument(at url: URL) -> Bool { false }
    func shouldChangeText(in textView: NSTextView, range: NSRange, replacement: String?) -> Bool { true }
    func recordEditorEvent(_ message: String, metadata: [String: String]) {}
}

/// Whether the first line is a protected `# ` title, as in a Scribl note.
public enum MarkdownEditorTitlePolicy: Equatable {
    case none
    /// The `# ` prefix can't be deleted, and an empty title shows `placeholder`.
    case protectedLeadingHeading(placeholder: String)
}
#endif
