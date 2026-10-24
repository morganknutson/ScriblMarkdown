import Foundation

public struct MarkdownStyledLink: Equatable {
    public let sourceRange: NSRange
    public let labelRange: NSRange
    public let markerRanges: [NSRange]
    public let destination: String
}

public struct MarkdownLinkPresentation: Equatable {
    private static let angleURLPattern = try! NSRegularExpression(pattern: #"<(https?://[^\s<>]+)>"#, options: .caseInsensitive)
    private static let bareURLPattern = try! NSRegularExpression(pattern: #"https?://[^\s<>]+"#, options: .caseInsensitive)
    private static let referenceDefinitionPattern = try! NSRegularExpression(
        pattern: #"^[ \t]{0,3}\[([^\]^][^\]]*)\]:[ \t]*(.+?)[ \t]*$"#
    )
    public let links: [MarkdownStyledLink]
    public let definitionRanges: [NSRange]

    public static func parse(in markdown: String, excluding excludedRanges: [NSRange]) -> Self {
        let source = markdown as NSString
        let definitions = referenceDefinitions(in: source, excluding: excludedRanges)
        let definitionsByLabel = Dictionary(
            definitions.map { (normalizedLabel($0.label), $0.destination) },
            uniquingKeysWith: { first, _ in first }
        )
        let definitionRanges = definitions.map(\.range)
        let protectedRanges = excludedRanges + definitionRanges
        var links: [MarkdownStyledLink] = []
        var cursor = 0

        while cursor < source.length {
            guard source.character(at: cursor) == unichar(91),
                  (cursor == 0 || source.character(at: cursor - 1) != unichar(33)),
                  !protectedRanges.contains(where: { NSLocationInRange(cursor, $0) }),
                  let labelEnd = closingDelimiter(
                    unichar(93),
                    opening: unichar(91),
                    after: cursor,
                    in: source
                  ),
                  labelEnd > cursor + 1 else {
                cursor += 1
                continue
            }
            let labelRange = NSRange(location: cursor + 1, length: labelEnd - cursor - 1)
            let label = source.substring(with: labelRange)
            let next = labelEnd + 1
            var parsed: MarkdownStyledLink?

            if next < source.length,
               source.character(at: next) == unichar(40),
               let destinationEnd = closingDelimiter(
                unichar(41),
                opening: unichar(40),
                after: next,
                in: source
               ) {
                let destinationSourceRange = NSRange(
                    location: next + 1,
                    length: destinationEnd - next - 1
                )
                if let destination = destination(
                    from: source.substring(with: destinationSourceRange)
                ) {
                    let sourceRange = NSRange(
                        location: cursor,
                        length: destinationEnd - cursor + 1
                    )
                    parsed = .init(
                        sourceRange: sourceRange,
                        labelRange: labelRange,
                        markerRanges: [
                            NSRange(location: cursor, length: 1),
                            NSRange(
                                location: labelEnd,
                                length: NSMaxRange(sourceRange) - labelEnd
                            )
                        ],
                        destination: destination
                    )
                }
            } else if next < source.length,
                      source.character(at: next) == unichar(91),
                      let referenceEnd = closingDelimiter(
                        unichar(93),
                        opening: unichar(91),
                        after: next,
                        in: source
                      ) {
                let referenceRange = NSRange(
                    location: next + 1,
                    length: referenceEnd - next - 1
                )
                let reference = source.substring(with: referenceRange)
                let key = normalizedLabel(reference.isEmpty ? label : reference)
                if let destination = definitionsByLabel[key] {
                    let sourceRange = NSRange(
                        location: cursor,
                        length: referenceEnd - cursor + 1
                    )
                    parsed = .init(
                        sourceRange: sourceRange,
                        labelRange: labelRange,
                        markerRanges: [
                            NSRange(location: cursor, length: 1),
                            NSRange(
                                location: labelEnd,
                                length: NSMaxRange(sourceRange) - labelEnd
                            )
                        ],
                        destination: destination
                    )
                }
            } else if let destination = definitionsByLabel[normalizedLabel(label)] {
                let sourceRange = NSRange(location: cursor, length: labelEnd - cursor + 1)
                parsed = .init(
                    sourceRange: sourceRange,
                    labelRange: labelRange,
                    markerRanges: [
                        NSRange(location: cursor, length: 1),
                        NSRange(location: labelEnd, length: 1)
                    ],
                    destination: destination
                )
            }

            guard let parsed,
                  !protectedRanges.contains(where: {
                    NSIntersectionRange($0, parsed.sourceRange).length > 0
                  }) else {
                cursor = labelEnd + 1
                continue
            }
            links.append(parsed)
            cursor = NSMaxRange(parsed.sourceRange)
        }
        links += autolinks(in: markdown, excluding: protectedRanges + links.map(\.sourceRange))
        links.sort { $0.sourceRange.location < $1.sourceRange.location }
        return Self(links: links, definitionRanges: definitionRanges)
    }

    private static func autolinks(in markdown: String, excluding excludedRanges: [NSRange]) -> [MarkdownStyledLink] {
        guard markdown.range(of: "http", options: .caseInsensitive) != nil else { return [] }
        let source = markdown as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        var links: [MarkdownStyledLink] = []

        for match in angleURLPattern.matches(in: markdown, range: fullRange) {
            guard !excludedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            let destination = source.substring(with: match.range(at: 1))
            guard isWebURL(destination) else { continue }
            links.append(.init(
                sourceRange: match.range,
                labelRange: match.range(at: 1),
                markerRanges: [
                    NSRange(location: match.range.location, length: 1),
                    NSRange(location: NSMaxRange(match.range) - 1, length: 1)
                ],
                destination: destination
            ))
        }

        let occupied = excludedRanges + links.map(\.sourceRange)
        for match in bareURLPattern.matches(in: markdown, range: fullRange) {
            guard !occupied.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            var destination = source.substring(with: match.range)
            while let last = destination.last {
                let unmatchedParenthesis = last == ")" &&
                    destination.filter({ $0 == ")" }).count > destination.filter({ $0 == "(" }).count
                let unmatchedBracket = last == "]" &&
                    destination.filter({ $0 == "]" }).count > destination.filter({ $0 == "[" }).count
                guard ".,;:!?".contains(last) || unmatchedParenthesis || unmatchedBracket else { break }
                destination.removeLast()
            }
            guard !destination.isEmpty, isWebURL(destination) else { continue }
            let range = NSRange(location: match.range.location, length: (destination as NSString).length)
            links.append(.init(sourceRange: range, labelRange: range, markerRanges: [], destination: destination))
        }
        return links
    }

    private static func isWebURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false else { return false }
        return true
    }

    private struct ReferenceDefinition {
        let range: NSRange
        let label: String
        let destination: String
    }

    private static func referenceDefinitions(
        in source: NSString,
        excluding excludedRanges: [NSRange]
    ) -> [ReferenceDefinition] {
        var result: [ReferenceDefinition] = []
        var location = 0
        while location < source.length {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            var contentEnd = NSMaxRange(lineRange)
            while contentEnd > lineRange.location,
                  [unichar(10), unichar(13)].contains(source.character(at: contentEnd - 1)) {
                contentEnd -= 1
            }
            let contentRange = NSRange(
                location: lineRange.location,
                length: contentEnd - lineRange.location
            )
            let line = source.substring(with: contentRange)
            let localRange = NSRange(location: 0, length: (line as NSString).length)
            if !excludedRanges.contains(where: {
                NSIntersectionRange($0, contentRange).length > 0
            }), let match = referenceDefinitionPattern.firstMatch(in: line, range: localRange),
               let destination = destination(
                from: (line as NSString).substring(with: match.range(at: 2))
               ) {
                result.append(.init(
                    range: lineRange,
                    label: (line as NSString).substring(with: match.range(at: 1)),
                    destination: destination
                ))
            }
            location = NSMaxRange(lineRange)
        }
        return result
    }

    private static func destination(from source: String) -> String? {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("<"), let end = value.firstIndex(of: ">") {
            let start = value.index(after: value.startIndex)
            let destination = String(value[start..<end])
            return destination.isEmpty ? nil : destination
        }

        var isEscaped = false
        var parenthesisDepth = 0
        for index in value.indices {
            let character = value[index]
            if character == "\\", !isEscaped {
                isEscaped = true
                continue
            }
            if !isEscaped {
                if character == "(" { parenthesisDepth += 1 }
                if character == ")" { parenthesisDepth = max(0, parenthesisDepth - 1) }
                if character.isWhitespace, parenthesisDepth == 0 {
                    let destination = String(value[..<index])
                    return destination.isEmpty ? nil : destination
                }
            }
            isEscaped = false
        }
        return value
    }

    private static func normalizedLabel(_ label: String) -> String {
        label.split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    private static func closingDelimiter(
        _ closing: unichar,
        opening: unichar,
        after start: Int,
        in source: NSString
    ) -> Int? {
        var depth = 1
        var cursor = start + 1
        var isEscaped = false
        while cursor < source.length {
            let character = source.character(at: cursor)
            if character == unichar(92), !isEscaped {
                isEscaped = true
                cursor += 1
                continue
            }
            if !isEscaped {
                if character == opening { depth += 1 }
                if character == closing {
                    depth -= 1
                    if depth == 0 { return cursor }
                }
                if [unichar(10), unichar(13)].contains(character) { return nil }
            }
            isEscaped = false
            cursor += 1
        }
        return nil
    }
}

public struct MarkdownFootnotePresentation: Equatable {
    private static let definitionExpression = try! NSRegularExpression(
        pattern: #"(?m)^(\[\^([^\]\r\n]+)\]:[ \t]*)([^\r\n]*)$"#
    )
    private static let referenceExpression = try! NSRegularExpression(pattern: #"\[\^([^\]\r\n]+)\]"#)
    public struct Reference: Equatable {
        public let sourceRange: NSRange
        public let label: String
        public let ordinal: Int
        public let definitionLocation: Int?
    }

    public struct Definition: Equatable {
        public let lineRange: NSRange
        public let prefixRange: NSRange
        public let contentRange: NSRange
        public let label: String
        public let ordinal: Int
        public let referenceLocation: Int?
    }

    public let references: [Reference]
    public let definitions: [Definition]

    public static func parse(in markdown: String, excluding excludedRanges: [NSRange]) -> Self {
        let source = markdown as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let definitionExpression = Self.definitionExpression
        let definitionMatches = definitionExpression.matches(in: markdown, range: fullRange)
            .filter { match in
                !excludedRanges.contains {
                    NSIntersectionRange($0, match.range).length > 0
                }
            }
        let definitionRanges = definitionMatches.map(\.range)
        let referenceExpression = Self.referenceExpression
        let referenceMatches = referenceExpression.matches(in: markdown, range: fullRange)
            .filter { match in
                !(excludedRanges + definitionRanges).contains {
                    NSIntersectionRange($0, match.range).length > 0
                }
            }

        var ordinals: [String: Int] = [:]
        var nextOrdinal = 1
        for match in referenceMatches {
            let label = source.substring(with: match.range(at: 1)).lowercased()
            if ordinals[label] == nil {
                ordinals[label] = nextOrdinal
                nextOrdinal += 1
            }
        }
        for match in definitionMatches {
            let label = source.substring(with: match.range(at: 2)).lowercased()
            if ordinals[label] == nil {
                ordinals[label] = nextOrdinal
                nextOrdinal += 1
            }
        }

        let definitionLocations = Dictionary(
            definitionMatches.map { match in
                let label = source.substring(with: match.range(at: 2)).lowercased()
                return (label, match.range(at: 3).location)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let firstReferenceLocations = Dictionary(
            referenceMatches.map { match in
                let label = source.substring(with: match.range(at: 1)).lowercased()
                return (label, match.range.location)
            },
            uniquingKeysWith: { first, _ in first }
        )

        let references = referenceMatches.map { match in
            let label = source.substring(with: match.range(at: 1))
            let key = label.lowercased()
            return Reference(
                sourceRange: match.range,
                label: label,
                ordinal: ordinals[key] ?? 1,
                definitionLocation: definitionLocations[key]
            )
        }
        let definitions = definitionMatches.map { match in
            let label = source.substring(with: match.range(at: 2))
            let key = label.lowercased()
            return Definition(
                lineRange: source.lineRange(for: match.range),
                prefixRange: match.range(at: 1),
                contentRange: match.range(at: 3),
                label: label,
                ordinal: ordinals[key] ?? 1,
                referenceLocation: firstReferenceLocations[key]
            )
        }
        return Self(references: references, definitions: definitions)
    }
}

