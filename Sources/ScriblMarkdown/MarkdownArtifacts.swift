import Foundation

public enum MarkdownArtifactKind: Equatable, Sendable {
    case web(URL)
    case note(MarkdownNoteReference)
}

public struct MarkdownNoteReference: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case resolved(URL)
        case missing
        case selfLink
    }

    public let title: String
    public let destination: String
    public let state: State
}

public struct MarkdownArtifact: Equatable, Identifiable, Sendable {
    public let kind: MarkdownArtifactKind
    /// Exact source excluding a trailing newline.
    public let sourceRange: NSRange
    /// Complete movable block, including its trailing newline when present.
    public let blockRange: NSRange
    public let source: String

    public var id: String { "\(blockRange.location):\(source)" }
}

public struct MarkdownArtifactParser: Sendable {
    /// Lowercased path extensions of files a relative link can embed as a document card.
    public let linkableDocumentExtensions: Set<String>

    public init(linkableDocumentExtensions: Set<String> = ["md", "markdown"]) {
        self.linkableDocumentExtensions = Set(linkableDocumentExtensions.map { $0.lowercased() })
    }

    public func artifacts(
        in markdown: String,
        noteURL: URL? = nil,
        libraryURLs: [URL] = []
    ) -> [MarkdownArtifact] {
        let source = markdown as NSString
        var result: [MarkdownArtifact] = []
        var location = 0
        var fence: (character: Character, count: Int)?

        while location < source.length {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let rawLine = source.substring(with: lineRange)
            let line = rawLine.trimmingCharacters(in: .newlines)
            let contentLength = (line as NSString).length
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let marker = fenceMarker(in: trimmed) {
                if let active = fence,
                   marker.character == active.character,
                   marker.count >= active.count {
                    fence = nil
                } else if fence == nil {
                    fence = marker
                }
                location = NSMaxRange(lineRange)
                continue
            }

            if fence == nil, !trimmed.isEmpty {
                let leadingUTF16 = (line as NSString).range(of: trimmed).location
                let artifactRange = NSRange(
                    location: lineRange.location + max(0, leadingUTF16),
                    length: (trimmed as NSString).length
                )
                if let kind = webKind(from: trimmed)
                    ?? noteKind(from: trimmed, noteURL: noteURL, libraryURLs: libraryURLs) {
                    result.append(.init(
                        kind: kind,
                        sourceRange: artifactRange,
                        blockRange: NSRange(location: lineRange.location, length: lineRange.length),
                        source: trimmed
                    ))
                }
            }

            location = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
            _ = contentLength
        }
        return result
    }

    private func webKind(from line: String) -> MarkdownArtifactKind? {
        guard !line.contains(where: \Character.isWhitespace),
              let url = URL(string: line),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil else { return nil }
        return .web(url)
    }

    private func noteKind(
        from line: String,
        noteURL: URL?,
        libraryURLs: [URL]
    ) -> MarkdownArtifactKind? {
        let expression = try! NSRegularExpression(
            pattern: #"^\[([^\]\n]+)\]\((<?)([^)\n]+?)(>?)\)$"#
        )
        let fullRange = NSRange(location: 0, length: (line as NSString).length)
        guard let match = expression.firstMatch(in: line, range: fullRange),
              match.range == fullRange else { return nil }
        let nsLine = line as NSString
        let title = nsLine.substring(with: match.range(at: 1))
        var destination = nsLine.substring(with: match.range(at: 3))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.contains("://"), !destination.hasPrefix("/") else { return nil }
        destination = destination.removingPercentEncoding ?? destination
        let extensionName = URL(fileURLWithPath: destination).pathExtension.lowercased()
        guard linkableDocumentExtensions.contains(extensionName) else { return nil }

        let state: MarkdownNoteReference.State
        if let noteURL {
            let target = URL(
                fileURLWithPath: destination,
                relativeTo: noteURL.deletingLastPathComponent()
            ).standardizedFileURL
            if target == noteURL.standardizedFileURL {
                state = .selfLink
            } else if let resolved = libraryURLs.first(where: { $0.standardizedFileURL == target }) {
                state = .resolved(resolved)
            } else {
                state = .missing
            }
        } else {
            state = .missing
        }
        return .note(.init(title: title, destination: destination, state: state))
    }

    private func fenceMarker(in line: String) -> (character: Character, count: Int)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let count = line.prefix { $0 == first }.count
        return count >= 3 ? (first, count) : nil
    }
}

public enum MarkdownNoteLink {
    public static func markdown(title: String, targetURL: URL, from sourceURL: URL) -> String? {
        guard targetURL.standardizedFileURL != sourceURL.standardizedFileURL else { return nil }
        let targetComponents = targetURL.standardizedFileURL.pathComponents
        let sourceComponents = sourceURL.deletingLastPathComponent().standardizedFileURL.pathComponents
        var shared = 0
        while shared < targetComponents.count,
              shared < sourceComponents.count,
              targetComponents[shared] == sourceComponents[shared] {
            shared += 1
        }
        let upward = Array(repeating: "..", count: sourceComponents.count - shared)
        let downward = Array(targetComponents.dropFirst(shared))
        let path = (upward + downward)
            .map(encodePathComponent)
            .joined(separator: "/")
        guard !path.isEmpty else { return nil }
        let escapedTitle = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "[\(escapedTitle)](\(path))"
    }

    public static func insertion(_ markdown: String, in source: String, at utf16Location: Int) -> String {
        MarkdownImageAssetStore.insertion(markdown: [markdown], in: source, at: utf16Location)
    }

    private static func encodePathComponent(_ component: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "()"))
        return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
    }
}

public enum MarkdownArtifactInsertion {
    public static func blockLocation(in markdown: String, near utf16Location: Int) -> Int {
        let source = markdown as NSString
        let location = min(max(0, utf16Location), source.length)
        guard source.length > 0, location < source.length else { return source.length }

        let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
        let line = source.substring(with: lineRange) as NSString
        let newlineLength = line.hasSuffix("\r\n")
            ? 2
            : (line.hasSuffix("\n") || line.hasSuffix("\r") ? 1 : 0)
        let contentEnd = max(lineRange.location, NSMaxRange(lineRange) - newlineLength)
        let midpoint = lineRange.location + (contentEnd - lineRange.location) / 2
        return location <= midpoint ? lineRange.location : NSMaxRange(lineRange)
    }

    public static func insertion(
        _ artifacts: [String],
        in markdown: String,
        near utf16Location: Int
    ) -> (location: Int, text: String)? {
        guard !artifacts.isEmpty else { return nil }
        let source = markdown as NSString
        let location = blockLocation(in: markdown, near: utf16Location)
        var insertion = artifacts.joined(separator: "\n")

        if location > 0 {
            let preceding = source.substring(with: NSRange(location: location - 1, length: 1))
            if preceding != "\n", preceding != "\r" {
                insertion = "\n" + insertion
            }
        }
        if location < source.length {
            let following = source.substring(with: NSRange(location: location, length: 1))
            if following != "\n", following != "\r" {
                insertion += "\n"
            }
        }
        return (location, insertion)
    }
}

public enum MarkdownArtifactReorder {
    public static func move(block sourceRange: NSRange, to destination: Int, in markdown: String) -> String? {
        let source = markdown as NSString
        guard sourceRange.location >= 0,
              sourceRange.length > 0,
              NSMaxRange(sourceRange) <= source.length,
              destination >= 0,
              destination <= source.length,
              !NSLocationInRange(destination, sourceRange) else { return nil }

        let block = source.substring(with: sourceRange)
        let remainder = source.mutableCopy() as! NSMutableString
        remainder.replaceCharacters(in: sourceRange, with: "")
        var adjustedDestination = destination
        if destination > NSMaxRange(sourceRange) {
            adjustedDestination -= sourceRange.length
        }
        adjustedDestination = min(max(0, adjustedDestination), remainder.length)
        if adjustedDestination == sourceRange.location { return nil }
        remainder.insert(block, at: adjustedDestination)
        let result = remainder as String
        return result == markdown ? nil : result
    }
}
