import Foundation

public enum MarkdownListNormalizer {
    public static func canonicalizingLiteralBullets(in markdown: String) -> String {
        let ranges = literalBulletMarkerRanges(in: markdown)
        guard !ranges.isEmpty else { return markdown }
        let result = NSMutableString(string: markdown)
        for range in ranges.reversed() {
            result.replaceCharacters(in: range, with: "-")
        }
        return result as String
    }

    public static func literalBulletMarkerRanges(in markdown: String) -> [NSRange] {
        let source = markdown as NSString
        var location = 0
        var fenceMarker: unichar?
        var ranges: [NSRange] = []

        while location < source.length {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            var contentEnd = NSMaxRange(lineRange)
            while contentEnd > lineRange.location,
                  [unichar(10), unichar(13)].contains(source.character(at: contentEnd - 1)) {
                contentEnd -= 1
            }
            var markerLocation = lineRange.location
            while markerLocation < contentEnd,
                  [unichar(9), unichar(32)].contains(source.character(at: markerLocation)) {
                markerLocation += 1
            }

            if markerLocation + 2 < contentEnd {
                let marker = source.character(at: markerLocation)
                if (marker == unichar(96) || marker == unichar(126)),
                   source.character(at: markerLocation + 1) == marker,
                   source.character(at: markerLocation + 2) == marker {
                    fenceMarker = fenceMarker == nil
                        ? marker
                        : (fenceMarker == marker ? nil : fenceMarker)
                    location = NSMaxRange(lineRange)
                    continue
                }
            }

            if fenceMarker == nil,
               markerLocation + 1 < contentEnd,
               source.character(at: markerLocation) == unichar(0x2022),
               [unichar(9), unichar(32)].contains(source.character(at: markerLocation + 1)) {
                ranges.append(NSRange(location: markerLocation, length: 1))
            }
            location = NSMaxRange(lineRange)
        }
        return ranges
    }
}

public struct MarkdownOrderedListItem: Equatable {
    private static let orderedExpression = try! NSRegularExpression(pattern: #"^([ \t]*)(\d+)(\.[ \t]+)([^\r\n]*)$"#)
    private static let listExpression = try! NSRegularExpression(pattern: #"^[ \t]*(?:[-*+]|\d+\.)[ \t]+"#)
    public let markerRange: NSRange
    public let indentationRange: NSRange
    public let numberRange: NSRange
    public let contentRange: NSRange
    public let rawNumber: Int
    public let displayNumber: Int
    public let indentationLevel: Int
    public let listID: Int

    /// The hierarchy-aware label shown for this item ("1.", "a.", "i.").
    public var displayLabel: String {
        MarkdownVisualSpec.orderedLabel(number: displayNumber, depth: indentationLevel)
    }

    public static func items(in source: String) -> [MarkdownOrderedListItem] {
        let string = source as NSString
        let orderedExpression = Self.orderedExpression
        let listExpression = Self.listExpression
        var location = 0
        var fenceMarker: unichar?
        var listID = 0
        var isInsideList = false
        var previousLevel: Int?
        var counters: [Int: Int] = [:]
        var items: [MarkdownOrderedListItem] = []

        func endList() {
            isInsideList = false
            previousLevel = nil
            counters.removeAll()
        }

        while location < string.length {
            let lineRange = string.lineRange(for: NSRange(location: location, length: 0))
            var contentEnd = NSMaxRange(lineRange)
            while contentEnd > lineRange.location,
                  [unichar(10), unichar(13)].contains(string.character(at: contentEnd - 1)) {
                contentEnd -= 1
            }
            let contentRange = NSRange(
                location: lineRange.location,
                length: contentEnd - lineRange.location
            )
            let line = string.substring(with: contentRange) as NSString
            var markerLocation = 0
            while markerLocation < line.length,
                  [unichar(9), unichar(32)].contains(line.character(at: markerLocation)) {
                markerLocation += 1
            }

            if markerLocation + 2 < line.length {
                let marker = line.character(at: markerLocation)
                if (marker == unichar(96) || marker == unichar(126)),
                   line.character(at: markerLocation + 1) == marker,
                   line.character(at: markerLocation + 2) == marker {
                    fenceMarker = fenceMarker == nil
                        ? marker
                        : (fenceMarker == marker ? nil : fenceMarker)
                    endList()
                    location = NSMaxRange(lineRange)
                    continue
                }
            }

            guard fenceMarker == nil else {
                endList()
                location = NSMaxRange(lineRange)
                continue
            }

            let localRange = NSRange(location: 0, length: line.length)
            let orderedMatch = orderedExpression.firstMatch(
                in: line as String,
                range: localRange
            )
            let listMatch = listExpression.firstMatch(in: line as String, range: localRange)

            guard orderedMatch != nil || listMatch != nil else {
                endList()
                location = NSMaxRange(lineRange)
                continue
            }

            let startsList = !isInsideList
            if startsList {
                listID += 1
                isInsideList = true
            }

            let indentationRange = orderedMatch?.range(at: 1) ?? NSRange(
                location: 0,
                length: markerLocation
            )
            let level = MarkdownVisualSpec.listDepth(ofIndentation: line.substring(with: indentationRange))

            guard let orderedMatch else {
                counters = counters.filter { $0.key < level }
                previousLevel = level
                location = NSMaxRange(lineRange)
                continue
            }

            let rawNumber = Int(line.substring(with: orderedMatch.range(at: 2))) ?? 1
            let displayNumber: Int
            if startsList {
                displayNumber = rawNumber
            } else if level > (previousLevel ?? -1) {
                displayNumber = 1
            } else if let previousNumber = counters[level] {
                displayNumber = previousNumber + 1
            } else {
                displayNumber = 1
            }
            counters = counters.filter { $0.key <= level }
            counters[level] = displayNumber
            previousLevel = level

            func documentRange(_ localRange: NSRange) -> NSRange {
                NSRange(
                    location: lineRange.location + localRange.location,
                    length: localRange.length
                )
            }

            let localMarkerRange = NSRange(
                location: 0,
                length: NSMaxRange(orderedMatch.range(at: 3))
            )
            items.append(MarkdownOrderedListItem(
                markerRange: documentRange(localMarkerRange),
                indentationRange: documentRange(orderedMatch.range(at: 1)),
                numberRange: documentRange(orderedMatch.range(at: 2)),
                contentRange: documentRange(orderedMatch.range(at: 4)),
                rawNumber: rawNumber,
                displayNumber: displayNumber,
                indentationLevel: level,
                listID: listID
            ))
            location = NSMaxRange(lineRange)
        }

        return items
    }
}

public struct MarkdownChecklistItem: Equatable {
    private static let itemExpression = try! NSRegularExpression(
        pattern: #"(?m)^(([ \t]*)[-*+][ \t]+\[([ xX])\][ \t]+)([^\r\n]*)"#
    )
    public let markerRange: NSRange
    public let indentationRange: NSRange
    public let stateRange: NSRange
    public let contentRange: NSRange
    public let isChecked: Bool

    public static func items(in source: String) -> [MarkdownChecklistItem] {
        let expression = Self.itemExpression
        let string = source as NSString
        return expression.matches(
            in: source,
            range: NSRange(location: 0, length: string.length)
        ).map { match in
            let state = string.substring(with: match.range(at: 3))
            return MarkdownChecklistItem(
                markerRange: match.range(at: 1),
                indentationRange: match.range(at: 2),
                stateRange: match.range(at: 3),
                contentRange: match.range(at: 4),
                isChecked: state.lowercased() == "x"
            )
        }
    }
}

public struct MarkdownBlockQuoteLine: Equatable {
    private static let unorderedMarker = try! NSRegularExpression(pattern: #"^([-*+][ \t]+)"#)
    private static let orderedMarker = try! NSRegularExpression(pattern: #"^(\d+\.[ \t]+)"#)
    public enum ListMarker: Equatable {
        case unordered(range: NSRange)
        case ordered(range: NSRange)

        public var range: NSRange {
            switch self {
            case .unordered(let range), .ordered(let range): range
            }
        }
    }

    public let lineRange: NSRange
    public let markerRange: NSRange
    public let contentRange: NSRange
    public let depth: Int
    public let listMarker: ListMarker?

    public static func lines(in markdown: String, excluding excludedRanges: [NSRange]) -> [Self] {
        let source = markdown as NSString
        var result: [Self] = []
        var location = 0
        while location < source.length {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            var contentEnd = NSMaxRange(lineRange)
            while contentEnd > lineRange.location,
                  [unichar(10), unichar(13)].contains(source.character(at: contentEnd - 1)) {
                contentEnd -= 1
            }
            let visibleLineRange = NSRange(
                location: lineRange.location,
                length: contentEnd - lineRange.location
            )
            guard !excludedRanges.contains(where: {
                NSIntersectionRange($0, visibleLineRange).length > 0
            }) else {
                location = NSMaxRange(lineRange)
                continue
            }

            var cursor = lineRange.location
            var leadingSpaces = 0
            while cursor < contentEnd,
                  source.character(at: cursor) == unichar(32),
                  leadingSpaces < 3 {
                cursor += 1
                leadingSpaces += 1
            }
            let markerStart = lineRange.location
            var depth = 0
            while cursor < contentEnd, source.character(at: cursor) == unichar(62) {
                depth += 1
                cursor += 1
                if cursor < contentEnd,
                   [unichar(9), unichar(32)].contains(source.character(at: cursor)) {
                    cursor += 1
                }
                var spacesBeforeNestedMarker = 0
                while cursor < contentEnd,
                      source.character(at: cursor) == unichar(32),
                      spacesBeforeNestedMarker < 2 {
                    cursor += 1
                    spacesBeforeNestedMarker += 1
                }
            }
            guard depth > 0 else {
                location = NSMaxRange(lineRange)
                continue
            }

            let markerRange = NSRange(location: markerStart, length: cursor - markerStart)
            let contentRange = NSRange(location: cursor, length: contentEnd - cursor)
            result.append(Self(
                lineRange: lineRange,
                markerRange: markerRange,
                contentRange: contentRange,
                depth: depth,
                listMarker: listMarker(in: source, contentRange: contentRange)
            ))
            location = NSMaxRange(lineRange)
        }
        return result
    }

    private static func listMarker(in source: NSString, contentRange: NSRange) -> ListMarker? {
        guard contentRange.length > 1 else { return nil }
        let content = source.substring(with: contentRange)
        let unordered = Self.unorderedMarker
        let ordered = Self.orderedMarker
        let localRange = NSRange(location: 0, length: (content as NSString).length)
        if let match = unordered.firstMatch(in: content, range: localRange) {
            return .unordered(range: NSRange(
                location: contentRange.location + match.range(at: 1).location,
                length: match.range(at: 1).length
            ))
        }
        if let match = ordered.firstMatch(in: content, range: localRange) {
            return .ordered(range: NSRange(
                location: contentRange.location + match.range(at: 1).location,
                length: match.range(at: 1).length
            ))
        }
        return nil
    }
}

