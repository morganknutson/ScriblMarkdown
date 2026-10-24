#if os(macOS)
import AppKit
import Foundation
import ScriblMarkdown
import UniformTypeIdentifiers

/// A document dragged into the editor, such as a note from Scribl's sidebar, which
/// inserts as a relative link card.
public struct MarkdownDocumentDragPayload: Codable, Equatable, Sendable {
    public static let pasteboardType = NSPasteboard.PasteboardType("com.morgan.notes.note-artifact")

    public let fileURL: URL
    public let title: String

    public init(fileURL: URL, title: String) {
        self.fileURL = fileURL
        self.title = title
    }

    var encodedData: Data? { try? JSONEncoder().encode(self) }

    static func decode(_ data: Data) -> Self? {
        try? JSONDecoder().decode(Self.self, from: data)
    }

    /// Reads a dragged document, accepting plain file URLs whose extension is in `linkableExtensions`.
    public static func read(from pasteboard: NSPasteboard, linkableExtensions: Set<String>) -> Self? {
        if let data = pasteboard.data(forType: pasteboardType),
           let payload = decode(data) {
            return payload
        }

        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        guard let url = urls.first(where: { linkableExtensions.contains($0.pathExtension.lowercased()) }) else {
            return nil
        }
        return .init(
            fileURL: url,
            title: url.deletingPathExtension().lastPathComponent
        )
    }

    public func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        if let data = encodedData {
            provider.registerDataRepresentation(
                forTypeIdentifier: Self.pasteboardType.rawValue,
                visibility: .all
            ) { completion in
                completion(data, nil)
                return nil
            }
        }
        provider.registerObject(fileURL as NSURL, visibility: .all)
        return provider
    }
}

struct ArtifactReorderDragPayload: Codable, Equatable, Sendable {
    static let pasteboardType = NSPasteboard.PasteboardType("com.morgan.notes.markdown-artifact-reorder")

    let blockLocation: Int
    let blockLength: Int
    let source: String

    var range: NSRange { NSRange(location: blockLocation, length: blockLength) }
}
#endif
