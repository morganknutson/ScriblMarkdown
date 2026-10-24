import Foundation

public struct MarkdownDetailsBlock: Equatable {
    private static let blockExpression = try! NSRegularExpression(
        pattern: #"(<details\b([^>]*)>)(?:[ \t]*\r?\n)?[ \t]*(<summary>)(.*?)(</summary>)(?:[ \t]*\r?\n)?(.*?)(?:\r?\n)?[ \t]*(</details>)"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let openExpression = try! NSRegularExpression(
        pattern: #"(?:^|\s)open(?:\s*=\s*(?:\"[^\"]*\"|'[^']*'|[^\s>]+))?(?=\s|$)"#,
        options: .caseInsensitive
    )
    public let sourceRange: NSRange
    public let openingTagRange: NSRange
    public let summaryOpeningRange: NSRange
    public let summaryContentRange: NSRange
    public let summaryClosingRange: NSRange
    public let bodyRange: NSRange
    public let closingTagRange: NSRange
    public let isExpanded: Bool

    public var structuralRanges: [NSRange] {
        [openingTagRange, summaryOpeningRange, summaryClosingRange, closingTagRange]
    }

    public static func blocks(in markdown: String, excluding excludedRanges: [NSRange]) -> [Self] {
        let source = markdown as NSString
        let expression = Self.blockExpression
        return expression.matches(
            in: markdown,
            range: NSRange(location: 0, length: source.length)
        ).compactMap { match in
            guard !excludedRanges.contains(where: {
                NSIntersectionRange($0, match.range).length > 0
            }) else { return nil }
            let attributes = source.substring(with: match.range(at: 2))
            let openExpression = Self.openExpression
            let isExpanded = openExpression.firstMatch(
                in: attributes,
                range: NSRange(location: 0, length: (attributes as NSString).length)
            ) != nil
            return Self(
                sourceRange: match.range,
                openingTagRange: match.range(at: 1),
                summaryOpeningRange: match.range(at: 3),
                summaryContentRange: match.range(at: 4),
                summaryClosingRange: match.range(at: 5),
                bodyRange: match.range(at: 6),
                closingTagRange: match.range(at: 7),
                isExpanded: isExpanded
            )
        }
    }
}

public enum MarkdownSoftBreaks {
    public static func characterIndexes(in markdown: String, excluding excludedRanges: [NSRange]) -> Set<Int> {
        let source = markdown as NSString
        var result = Set<Int>()
        var location = 0
        while location < source.length {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let newlineLocation = NSMaxRange(lineRange) - 1
            guard newlineLocation >= lineRange.location,
                  newlineLocation < source.length,
                  source.character(at: newlineLocation) == unichar(10),
                  NSMaxRange(lineRange) < source.length else {
                location = NSMaxRange(lineRange)
                continue
            }
            var contentEnd = newlineLocation
            if contentEnd > lineRange.location,
               source.character(at: contentEnd - 1) == unichar(13) {
                contentEnd -= 1
            }
            let contentRange = NSRange(
                location: lineRange.location,
                length: contentEnd - lineRange.location
            )
            let nextLineRange = source.lineRange(
                for: NSRange(location: NSMaxRange(lineRange), length: 0)
            )
            var nextEnd = NSMaxRange(nextLineRange)
            while nextEnd > nextLineRange.location,
                  [unichar(10), unichar(13)].contains(source.character(at: nextEnd - 1)) {
                nextEnd -= 1
            }
            let nextContentRange = NSRange(
                location: nextLineRange.location,
                length: nextEnd - nextLineRange.location
            )
            let line = source.substring(with: contentRange)
            let nextLine = source.substring(with: nextContentRange)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let nextTrimmed = nextLine.trimmingCharacters(in: .whitespaces)
            let boundaryRange = NSRange(location: newlineLocation, length: 1)
            if !trimmed.isEmpty,
               !nextTrimmed.isEmpty,
               !line.hasSuffix("  "),
               !line.hasSuffix("\\"),
               !isBlockLine(trimmed),
               !isBlockLine(nextTrimmed),
               !excludedRanges.contains(where: {
                   NSIntersectionRange($0, boundaryRange).length > 0
                       || NSIntersectionRange($0, contentRange).length > 0
                       || NSIntersectionRange($0, nextContentRange).length > 0
               }) {
                result.insert(newlineLocation)
            }
            location = NSMaxRange(lineRange)
        }
        return result
    }

    private static func isBlockLine(_ line: String) -> Bool {
        let patterns = [
            #"^#{1,6}(?:\s|$)"#,
            #"^(?:[-*+]\s+|\d+\.\s+)"#,
            #"^>"#,
            #"^(?:```|~~~)"#,
            #"^(?:\*\s*){3,}$|^(?:-\s*){3,}$|^(?:_\s*){3,}$"#,
            #"^\|.*\|$"#,
            #"^\[\^[^\]]+\]:"#,
            #"^:[ \t]+"#,
            #"^<\/?(?:details|summary)\b"#
        ]
        return patterns.contains { pattern in
            line.range(of: pattern, options: .regularExpression) != nil
        }
    }
}

public enum MarkdownEntityDecoder {
    public static func value(for entity: String) -> String? {
        let named: [String: String] = [
            "&amp;": "&", "&copy;": "©", "&mdash;": "—", "&ndash;": "–",
            "&hellip;": "…", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&apos;": "'", "&nbsp;": "\u{00A0}"
        ]
        if let value = named[entity.lowercased()] { return value }
        guard entity.hasPrefix("&#"), entity.hasSuffix(";") else { return nil }
        let start = entity.index(entity.startIndex, offsetBy: 2)
        let end = entity.index(before: entity.endIndex)
        let payload = String(entity[start..<end])
        let radix: Int
        let digits: String
        if payload.lowercased().hasPrefix("x") {
            radix = 16
            digits = String(payload.dropFirst())
        } else {
            radix = 10
            digits = payload
        }
        guard let scalarValue = UInt32(digits, radix: radix),
              let scalar = UnicodeScalar(scalarValue) else { return nil }
        return String(Character(scalar))
    }
}

public struct MarkdownCodeBlock: Equatable {
    private static let listMarkerExpression = try! NSRegularExpression(
        pattern: #"^(?:[-*+](?:[ \t]+|$)|\d+\.(?:[ \t]+|$))"#
    )
    public let sourceRange: NSRange
    public let contentRange: NSRange
    public let openingRange: NSRange?
    public let closingRange: NSRange?
    public let indentationRanges: [NSRange]

    public static func blocks(in markdown: String) -> [Self] {
        let source = markdown as NSString
        var blocks: [Self] = []
        var location = 0
        var openFence: (marker: unichar, count: Int, openingRange: NSRange, contentStart: Int)?

        while location < source.length {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let contentRange = lineContentRange(lineRange, in: source)
            let line = source.substring(with: contentRange) as NSString
            let fence = fenceMarker(in: line)

            if let activeFence = openFence {
                if let fence,
                   fence.marker == activeFence.marker,
                   fence.count >= activeFence.count,
                   fence.isClosing {
                    blocks.append(Self(
                        sourceRange: NSRange(
                            location: activeFence.openingRange.location,
                            length: NSMaxRange(lineRange) - activeFence.openingRange.location
                        ),
                        contentRange: NSRange(
                            location: activeFence.contentStart,
                            length: max(0, lineRange.location - activeFence.contentStart)
                        ),
                        openingRange: activeFence.openingRange,
                        closingRange: lineRange,
                        indentationRanges: []
                    ))
                    location = NSMaxRange(lineRange)
                    openFence = nil
                    continue
                }
                location = NSMaxRange(lineRange)
                continue
            }

            if let fence {
                openFence = (
                    fence.marker,
                    fence.count,
                    lineRange,
                    NSMaxRange(lineRange)
                )
                location = NSMaxRange(lineRange)
                continue
            }

            if let indentation = indentationRange(in: line, documentOffset: lineRange.location) {
                let start = lineRange.location
                var end = NSMaxRange(lineRange)
                var indentationRanges = [indentation]
                var next = end
                while next < source.length {
                    let nextLineRange = source.lineRange(for: NSRange(location: next, length: 0))
                    let nextContentRange = lineContentRange(nextLineRange, in: source)
                    let nextLine = source.substring(with: nextContentRange) as NSString
                    guard let nextIndentation = indentationRange(
                        in: nextLine,
                        documentOffset: nextLineRange.location
                    ) else { break }
                    indentationRanges.append(nextIndentation)
                    end = NSMaxRange(nextLineRange)
                    next = end
                }
                blocks.append(Self(
                    sourceRange: NSRange(location: start, length: end - start),
                    contentRange: NSRange(location: start, length: end - start),
                    openingRange: nil,
                    closingRange: nil,
                    indentationRanges: indentationRanges
                ))
                location = end
                continue
            }

            location = NSMaxRange(lineRange)
        }

        if let openFence {
            blocks.append(Self(
                sourceRange: NSRange(
                    location: openFence.openingRange.location,
                    length: source.length - openFence.openingRange.location
                ),
                contentRange: NSRange(
                    location: openFence.contentStart,
                    length: source.length - openFence.contentStart
                ),
                openingRange: openFence.openingRange,
                closingRange: nil,
                indentationRanges: []
            ))
        }
        return blocks
    }

    private static func lineContentRange(_ lineRange: NSRange, in source: NSString) -> NSRange {
        var end = NSMaxRange(lineRange)
        while end > lineRange.location,
              [unichar(10), unichar(13)].contains(source.character(at: end - 1)) {
            end -= 1
        }
        return NSRange(location: lineRange.location, length: end - lineRange.location)
    }

    private static func fenceMarker(in line: NSString) -> (marker: unichar, count: Int, isClosing: Bool)? {
        var index = 0
        while index < min(3, line.length), line.character(at: index) == unichar(32) {
            index += 1
        }
        guard index < line.length else { return nil }
        let marker = line.character(at: index)
        guard marker == unichar(96) || marker == unichar(126) else { return nil }
        var end = index
        while end < line.length, line.character(at: end) == marker { end += 1 }
        guard end - index >= 3 else { return nil }
        let remainder = line.substring(from: end)
        return (
            marker,
            end - index,
            remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    private static func indentationRange(in line: NSString, documentOffset: Int) -> NSRange? {
        guard line.length > 0 else { return nil }
        if line.character(at: 0) == unichar(9) {
            return NSRange(location: documentOffset, length: 1)
        }
        guard line.length >= 4,
              (0..<4).allSatisfy({ line.character(at: $0) == unichar(32) }),
              line.substring(from: 4).trimmingCharacters(in: .whitespaces).isEmpty == false else {
            return nil
        }
        let remainder = line.substring(from: 4)
            .trimmingCharacters(in: .whitespaces)
        let listMarker = Self.listMarkerExpression
        if listMarker.firstMatch(
            in: remainder,
            range: NSRange(location: 0, length: (remainder as NSString).length)
        ) != nil {
            return nil
        }
        return NSRange(location: documentOffset, length: 4)
    }

}

public struct MarkdownTable: Equatable {
    private static let delimiterExpression = try! NSRegularExpression(
        pattern: #"^[ \t]*\|?[ \t]*:?-{3,}:?[ \t]*(?:\|[ \t]*:?-{3,}:?[ \t]*)+\|?[ \t]*$"#
    )
    public struct Row: Equatable {
        public let lineRange: NSRange
        public let cells: [NSRange]
        public let separators: [NSRange]
    }

    public let sourceRange: NSRange
    public let header: Row
    public let delimiterRange: NSRange
    public let rows: [Row]

    public static func tables(in markdown: String, excluding excludedRanges: [NSRange]) -> [Self] {
        let source = markdown as NSString
        var lines: [(range: NSRange, content: String)] = []
        var location = 0
        while location < source.length {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            var end = NSMaxRange(lineRange)
            while end > lineRange.location,
                  [unichar(10), unichar(13)].contains(source.character(at: end - 1)) {
                end -= 1
            }
            lines.append((lineRange, source.substring(with: NSRange(
                location: lineRange.location,
                length: end - lineRange.location
            ))))
            location = NSMaxRange(lineRange)
        }

        let delimiter = Self.delimiterExpression
        var tables: [Self] = []
        var index = 0
        while index + 1 < lines.count {
            let headerLine = lines[index]
            let delimiterLine = lines[index + 1]
            let delimiterNSString = delimiterLine.content as NSString
            let isExcluded = excludedRanges.contains {
                NSIntersectionRange($0, delimiterLine.range).length > 0
            }
            guard !isExcluded,
                  delimiter.firstMatch(
                    in: delimiterLine.content,
                    range: NSRange(location: 0, length: delimiterNSString.length)
                  ) != nil,
                  let header = row(from: headerLine, source: source),
                  header.cells.count >= 2 else {
                index += 1
                continue
            }

            var rows: [Row] = []
            var rowIndex = index + 2
            while rowIndex < lines.count,
                  let row = row(from: lines[rowIndex], source: source),
                  row.cells.count == header.cells.count {
                rows.append(row)
                rowIndex += 1
            }
            let end = rows.last.map { NSMaxRange($0.lineRange) }
                ?? NSMaxRange(delimiterLine.range)
            tables.append(Self(
                sourceRange: NSRange(
                    location: header.lineRange.location,
                    length: end - header.lineRange.location
                ),
                header: header,
                delimiterRange: delimiterLine.range,
                rows: rows
            ))
            index = rowIndex
        }
        return tables
    }

    private static func row(
        from line: (range: NSRange, content: String),
        source: NSString
    ) -> Row? {
        let value = line.content as NSString
        var pipeLocations: [Int] = []
        var escaped = false
        for index in 0..<value.length {
            let character = value.character(at: index)
            if character == unichar(92), !escaped {
                escaped = true
                continue
            }
            if character == unichar(124), !escaped { pipeLocations.append(index) }
            escaped = false
        }
        guard !pipeLocations.isEmpty else { return nil }

        var boundaries = pipeLocations
        if boundaries.first != 0 { boundaries.insert(-1, at: 0) }
        if boundaries.last != value.length - 1 { boundaries.append(value.length) }
        var cells: [NSRange] = []
        for pair in zip(boundaries, boundaries.dropFirst()) {
            var start = pair.0 + 1
            var end = pair.1
            while start < end, [unichar(9), unichar(32)].contains(value.character(at: start)) {
                start += 1
            }
            while end > start, [unichar(9), unichar(32)].contains(value.character(at: end - 1)) {
                end -= 1
            }
            cells.append(NSRange(
                location: line.range.location + start,
                length: end - start
            ))
        }
        guard cells.count >= 2 else { return nil }

        var separators: [NSRange] = []
        var cursor = line.range.location
        for cell in cells {
            separators.append(NSRange(location: cursor, length: cell.location - cursor))
            cursor = NSMaxRange(cell)
        }
        separators.append(NSRange(
            location: cursor,
            length: max(0, line.range.location + value.length - cursor)
        ))
        return Row(lineRange: line.range, cells: cells, separators: separators)
    }
}

public enum MarkdownMathDisplay {
    private static let superscriptExpression = try! NSRegularExpression(pattern: #"\^\{?([0-9+\-]+)\}?"#)
    public static func text(for source: String) -> String {
        var result = source
            .replacingOccurrences(of: #"\pm"#, with: "±")
            .replacingOccurrences(of: #"\times"#, with: "×")
            .replacingOccurrences(of: #"\cdot"#, with: "·")
            .replacingOccurrences(of: #"\le"#, with: "≤")
            .replacingOccurrences(of: #"\ge"#, with: "≥")
            .replacingOccurrences(of: #"\neq"#, with: "≠")
            .replacingOccurrences(of: #"\infty"#, with: "∞")
        result = replacingCommand("sqrt", in: result) { "√(\($0))" }
        result = replacingFraction(in: result)
        let superscripts: [Character: Character] = [
            "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
            "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
            "+": "⁺", "-": "⁻"
        ]
        let expression = Self.superscriptExpression
        let mutable = NSMutableString(string: result)
        for match in expression.matches(
            in: result,
            range: NSRange(location: 0, length: (result as NSString).length)
        ).reversed() {
            let digits = (result as NSString).substring(with: match.range(at: 1))
            let replacement = String(digits.map { superscripts[$0] ?? $0 })
            mutable.replaceCharacters(in: match.range, with: replacement)
        }
        return (mutable as String)
            .replacingOccurrences(of: "{", with: "(")
            .replacingOccurrences(of: "}", with: ")")
    }

    private static func replacingCommand(
        _ command: String,
        in source: String,
        transform: (String) -> String
    ) -> String {
        var result = source
        while let commandRange = result.range(of: "\\\(command){"),
              let argument = balancedArgument(in: result, openingAt: result.index(before: commandRange.upperBound)) {
            result.replaceSubrange(
                commandRange.lowerBound..<argument.range.upperBound,
                with: transform(argument.value)
            )
        }
        return result
    }

    private static func replacingFraction(in source: String) -> String {
        var result = source
        while let commandRange = result.range(of: #"\frac{"#),
              let numerator = balancedArgument(
                in: result,
                openingAt: result.index(before: commandRange.upperBound)
              ),
              numerator.range.upperBound < result.endIndex,
              result[numerator.range.upperBound] == "{",
              let denominator = balancedArgument(in: result, openingAt: numerator.range.upperBound) {
            let replacement = "(\(text(for: numerator.value)))⁄(\(text(for: denominator.value)))"
            result.replaceSubrange(commandRange.lowerBound..<denominator.range.upperBound, with: replacement)
        }
        return result
    }

    private static func balancedArgument(
        in source: String,
        openingAt opening: String.Index
    ) -> (range: Range<String.Index>, value: String)? {
        guard opening < source.endIndex, source[opening] == "{" else { return nil }
        var depth = 0
        var index = opening
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 {
                    let contentStart = source.index(after: opening)
                    return (opening..<source.index(after: index), String(source[contentStart..<index]))
                }
            }
            index = source.index(after: index)
        }
        return nil
    }
}

