import Foundation
import UniformTypeIdentifiers

public struct MarkdownImageReference: Equatable {
    private static let referenceExpression = try! NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\(([^)\n]+)\)"#)
    public let range: NSRange
    public let alternateText: String
    public let destination: String

    public static func references(in markdown: String) -> [Self] {
        let expression = Self.referenceExpression
        let fullRange = NSRange(location: 0, length: (markdown as NSString).length)
        return expression.matches(in: markdown, range: fullRange).compactMap { match in
            guard match.numberOfRanges == 3 else { return nil }
            let source = markdown as NSString
            return Self(
                range: match.range,
                alternateText: source.substring(with: match.range(at: 1)),
                destination: source.substring(with: match.range(at: 2))
            )
        }
    }

    public func fileURL(relativeTo noteURL: URL) -> URL? {
        var path = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("<"), path.hasSuffix(">") {
            path = String(path.dropFirst().dropLast())
        }
        guard !path.contains("://"), !path.hasPrefix("data:") else { return nil }
        path = path.removingPercentEncoding ?? path
        return URL(fileURLWithPath: path, relativeTo: noteURL.deletingLastPathComponent())
            .standardizedFileURL
    }
}

public struct MarkdownImageReorderPayload: Codable, Equatable {
    public let referenceLocation: Int
    public let referenceLength: Int
    public let source: String

    public init(referenceLocation: Int, referenceLength: Int, source: String) {
        self.referenceLocation = referenceLocation
        self.referenceLength = referenceLength
        self.source = source
    }

    public var range: NSRange {
        NSRange(location: referenceLocation, length: referenceLength)
    }
}

public enum MarkdownImageEditing {
    public static func expandedSelection(_ selection: NSRange, imageRanges: [NSRange]) -> NSRange {
        guard selection.length > 0 else { return selection }
        var lowerBound = selection.location
        var upperBound = NSMaxRange(selection)
        var didExpand = true

        while didExpand {
            didExpand = false
            for range in imageRanges where NSIntersectionRange(
                NSRange(location: lowerBound, length: upperBound - lowerBound),
                range
            ).length > 0 {
                let newLowerBound = min(lowerBound, range.location)
                let newUpperBound = max(upperBound, NSMaxRange(range))
                if newLowerBound != lowerBound || newUpperBound != upperBound {
                    lowerBound = newLowerBound
                    upperBound = newUpperBound
                    didExpand = true
                }
            }
        }
        return NSRange(location: lowerBound, length: upperBound - lowerBound)
    }

    public static func deletionRange(
        for selection: NSRange,
        forward: Bool,
        imageRanges: [NSRange]
    ) -> NSRange? {
        if selection.length > 0 {
            guard imageRanges.contains(where: {
                NSIntersectionRange(selection, $0).length > 0
            }) else { return nil }
            return expandedSelection(selection, imageRanges: imageRanges)
        }
        return imageRanges.first { range in
            if forward {
                return selection.location >= range.location
                    && selection.location < NSMaxRange(range)
            }
            return selection.location > range.location
                && selection.location <= NSMaxRange(range)
        }
    }

    public static func movementDestination(
        for selection: NSRange,
        forward: Bool,
        imageRanges: [NSRange]
    ) -> Int? {
        if selection.length > 0,
           let range = imageRanges.first(where: {
               NSIntersectionRange(selection, $0).length > 0
           }) {
            return forward ? NSMaxRange(range) : range.location
        }
        guard selection.length == 0 else { return nil }
        guard let range = imageRanges.first(where: { range in
            if forward {
                return selection.location >= range.location
                    && selection.location < NSMaxRange(range)
            }
            return selection.location > range.location
                && selection.location <= NSMaxRange(range)
        }) else { return nil }
        return forward ? NSMaxRange(range) : range.location
    }

    public static func move(
        payload: MarkdownImageReorderPayload,
        to destination: Int,
        in markdown: String
    ) -> (markdown: String, selection: NSRange)? {
        let source = markdown as NSString
        let range = payload.range
        guard range.location >= 0,
              range.length > 0,
              NSMaxRange(range) <= source.length,
              source.substring(with: range) == payload.source else { return nil }

        let boundedDestination = min(max(destination, 0), source.length)
        guard boundedDestination < range.location || boundedDestination > NSMaxRange(range) else {
            return nil
        }

        let result = NSMutableString(string: markdown)
        result.deleteCharacters(in: range)
        let adjustedDestination = boundedDestination > NSMaxRange(range)
            ? boundedDestination - range.length
            : boundedDestination
        result.insert(payload.source, at: adjustedDestination)
        return (
            result as String,
            NSRange(location: adjustedDestination, length: range.length)
        )
    }
}

public struct MarkdownImageAssetStore {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func importFile(at sourceURL: URL, for noteURL: URL) throws -> String? {
        guard Self.isImageFile(sourceURL) else { return nil }
        let directory = try assetDirectory(for: noteURL)
        let originalName = Self.sanitizedFileName(sourceURL.lastPathComponent, fallback: "Image")
        let destination = availableURL(in: directory, preferredName: originalName)
        try fileManager.copyItem(at: sourceURL, to: destination)
        return markdown(for: destination, relativeTo: noteURL, alternateText: destination.deletingPathExtension().lastPathComponent)
    }

    public func importImageData(
        _ data: Data,
        preferredName: String,
        for noteURL: URL
    ) throws -> String {
        let directory = try assetDirectory(for: noteURL)
        let fileName = Self.sanitizedFileName(preferredName, fallback: "Pasted Image.png")
        let destination = availableURL(in: directory, preferredName: fileName)
        try data.write(to: destination, options: .atomic)
        return encodedRelativePath(for: destination, relativeTo: noteURL)
    }

    public static func insertion(markdown references: [String], in text: String, at utf16Location: Int) -> String {
        guard !references.isEmpty else { return "" }
        return references.joined(separator: " ")
    }

    private func assetDirectory(for noteURL: URL) throws -> URL {
        let noteName = Self.sanitizedFileName(
            noteURL.deletingPathExtension().lastPathComponent,
            fallback: "Note"
        )
        let directory = noteURL.deletingLastPathComponent()
            .appendingPathComponent("Assets", isDirectory: true)
            .appendingPathComponent(noteName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func availableURL(in directory: URL, preferredName: String) -> URL {
        let source = URL(fileURLWithPath: preferredName)
        let stem = source.deletingPathExtension().lastPathComponent
        let extensionName = source.pathExtension
        var candidate = directory.appendingPathComponent(preferredName)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let name = extensionName.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(extensionName)"
            candidate = directory.appendingPathComponent(name)
            suffix += 1
        }
        return candidate
    }

    private func markdown(for imageURL: URL, relativeTo noteURL: URL, alternateText: String) -> String {
        markdown(
            destination: encodedRelativePath(for: imageURL, relativeTo: noteURL),
            alternateText: alternateText
        )
    }

    public func markdown(destination: String, alternateText: String) -> String {
        let label = alternateText
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "![\(label)](\(destination))"
    }

    private func encodedRelativePath(for imageURL: URL, relativeTo noteURL: URL) -> String {
        let relativePath = imageURL.path.replacingOccurrences(
            of: noteURL.deletingLastPathComponent().path + "/",
            with: ""
        )
        let markdownPathCharacters = CharacterSet.urlPathAllowed
            .subtracting(CharacterSet(charactersIn: "()"))
        let encodedPath = relativePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: markdownPathCharacters) ?? String($0) }
            .joined(separator: "/")
        return encodedPath
    }

    private static func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    private static func sanitizedFileName(_ value: String, fallback: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let cleaned = value.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? fallback : cleaned
    }
}

