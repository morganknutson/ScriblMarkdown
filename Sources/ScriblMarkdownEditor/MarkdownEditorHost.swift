import AppKit

/// A public web page's preview, shown on a bare link's card.
public struct WebLinkMetadata: Codable, Equatable, Sendable {
    public let url: URL
    public let title: String?
    public let summary: String?
    public let siteName: String
    public let thumbnailData: Data?

    public init(url: URL, title: String?, summary: String?, siteName: String, thumbnailData: Data?) {
        self.url = url
        self.title = title
        self.summary = summary
        self.siteName = siteName
        self.thumbnailData = thumbnailData
    }

    public static func fallback(for url: URL) -> Self {
        .init(
            url: url,
            title: nil,
            summary: nil,
            siteName: url.host ?? url.absoluteString,
            thumbnailData: nil
        )
    }
}

/// Fetches previews for bare web links. Implementations own their caching and network policy.
public protocol WebLinkMetadataProviding: Sendable {
    func metadata(for url: URL) async -> WebLinkMetadata
}

/// How a linked document's card describes it.
public struct MarkdownLinkedDocument: Equatable {
    public var title: String
    public var preview: String
    /// The card's eyebrow, such as "Note" or "Sketch note".
    public var kindLabel: String
    public var image: NSImage?

    public init(title: String, preview: String, kindLabel: String, image: NSImage?) {
        self.title = title
        self.preview = preview
        self.kindLabel = kindLabel
        self.image = image
    }
}

/// A foreground color for a range of a code block's content.
public struct MarkdownCodeColorRun: Equatable {
    public let range: NSRange
    public let color: NSColor

    public init(range: NSRange, color: NSColor) {
        self.range = range
        self.color = color
    }
}

/// Syntax-colors fenced code blocks. It runs on the main thread on every restyle, so
/// implementations should be fast or cache by input.
public protocol MarkdownCodeHighlighting: AnyObject {
    /// Color runs for `code`, with ranges relative to `code`.
    func colorRuns(forCode code: String, language: String?) -> [MarkdownCodeColorRun]
}

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
