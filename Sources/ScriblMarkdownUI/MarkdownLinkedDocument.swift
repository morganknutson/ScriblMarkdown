#if os(macOS)
import AppKit

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
#endif
