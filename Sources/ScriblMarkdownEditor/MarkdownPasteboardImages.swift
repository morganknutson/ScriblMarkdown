#if os(macOS)
import AppKit
import Foundation
import ScriblMarkdown

/// Image data read from a pasteboard, in the first format the editor can store.
public struct PasteboardImagePayload: Equatable {
    public let data: Data
    public let preferredFileName: String
    public let mimeType: String

    public init(data: Data, preferredFileName: String, mimeType: String) {
        self.data = data
        self.preferredFileName = preferredFileName
        self.mimeType = mimeType
    }

    public static func read(from pasteboard: NSPasteboard) -> Self? {
        let formats: [(NSPasteboard.PasteboardType, String, String)] = [
            (.init("public.png"), "Pasted Image.png", "image/png"),
            (.init("public.jpeg"), "Pasted Image.jpg", "image/jpeg"),
            (.init("public.heic"), "Pasted Image.heic", "image/heic"),
            (.init("com.compuserve.gif"), "Pasted Image.gif", "image/gif"),
            (.init("org.webmproject.webp"), "Pasted Image.webp", "image/webp"),
            (.tiff, "Pasted Image.tiff", "image/tiff")
        ]
        for (type, fileName, mimeType) in formats {
            if let data = pasteboard.data(forType: type), !data.isEmpty {
                return .init(data: data, preferredFileName: fileName, mimeType: mimeType)
            }
        }

        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let data = representation.representation(using: .png, properties: [:]) else {
            return nil
        }
        return .init(data: data, preferredFileName: "Pasted Image.png", mimeType: "image/png")
    }
}

extension MarkdownImageReorderPayload {
    static let pasteboardType = NSPasteboard.PasteboardType("ing.scribl.image-reorder")
}

public extension MarkdownImageAssetStore {
    func importImage(_ image: NSImage, for noteURL: URL) throws -> String {
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let data = representation.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let destination = try importImageData(
            data,
            preferredName: "Pasted Image.png",
            for: noteURL
        )
        return markdown(destination: destination, alternateText: "Pasted Image")
    }

    func importPastedImage(_ payload: PasteboardImagePayload, for noteURL: URL) throws -> String {
        let destination = try importImageData(
            payload.data,
            preferredName: payload.preferredFileName,
            for: noteURL
        )
        return markdown(destination: destination, alternateText: "Pasted Image")
    }
}
#endif
