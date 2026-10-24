import Foundation

/// The editing behaviors every Markdown editor shares (Scribl on macOS and iOS, Addy's
/// notepad and Memory), written as source edits so each platform applies the same Markdown.
/// Each rule returns nil when it does not apply, letting the editor do its default.
public enum MarkdownEditingRules {
    private static let listItemExpression = try! NSRegularExpression(
        pattern: #"^([ \t]*)([-*+]|\d+\.)([ \t]+)(\[[ xX]\][ \t]+)?(.*)$"#
    )
    private static let listMarkerExpression = try! NSRegularExpression(
        pattern: #"^([ \t]*)(?:[-*+]|\d+\.)[ \t]+(?:\[[ xX]\][ \t]+)?"#
    )
    private static let quoteExpression = try! NSRegularExpression(
        pattern: #"^([ \t]{0,3}(?:>[ \t]?)+)(.*)$"#
    )
    private static let dashRuleExpression = try! NSRegularExpression(
        pattern: #"^[ \t]{0,3}(?:-{3,}|\*{3,}|_{3,})[ \t]*$"#
    )
    private static let checklistShortcutExpression = try! NSRegularExpression(
        pattern: #"^([ \t]*)\[ ?\]$"#
    )
    private static let fenceShortcutExpression = try! NSRegularExpression(
        pattern: #"^[ \t]{0,3}``$"#
    )

    // MARK: - Return

    /// Return at the caret:
    /// - in a list item, starts the next item (checklists start unchecked, numbers count up);
    /// - on an empty nested item, steps out one level; on an empty top-level item, removes the marker;
    /// - in a quote, continues the quote; on an empty quote line, ends it;
    /// - after `---`, `***` or `___`, keeps the rule on a line of its own and moves below it.
    public static func newline(in source: String, selection: NSRange) -> MarkdownEdit? {
        guard selection.length == 0 else { return nil }
        let text = source as NSString
        let caret = min(selection.location, text.length)
        let line = MarkdownSourceLine(containing: caret, in: text)
        let lineText = line.text(in: text)

        if caret == NSMaxRange(line.contentRange), matches(dashRuleExpression, lineText) {
            return rule(replacing: line, in: source)
        }
        if let item = listItemExpression.firstMatch(in: lineText, range: NSRange(location: 0, length: line.contentRange.length)) {
            return listNewline(item, line: line, caret: caret, in: source)
        }
        if let quote = quoteExpression.firstMatch(in: lineText, range: NSRange(location: 0, length: line.contentRange.length)) {
            return quoteNewline(quote, line: line, caret: caret, in: source)
        }
        return nil
    }

    private static func listNewline(
        _ match: NSTextCheckingResult,
        line: MarkdownSourceLine,
        caret: Int,
        in source: String
    ) -> MarkdownEdit? {
        let text = source as NSString
        let lineText = line.text(in: text) as NSString
        let indentation = lineText.substring(with: match.range(at: 1))
        let marker = lineText.substring(with: match.range(at: 2))
        let content = lineText.substring(with: match.range(at: 5))
        let contentStart = line.contentRange.location + match.range(at: 5).location

        if content.trimmingCharacters(in: .whitespaces).isEmpty, caret >= contentStart {
            if !indentation.isEmpty {
                return indent(in: source, selection: NSRange(location: caret, length: 0), outdent: true)
            }
            let edit = MarkdownEdit(
                range: line.contentRange,
                replacement: "",
                selection: NSRange(location: line.contentRange.location, length: 0)
            )
            return renumbered(after: edit, in: source)
        }

        let nextMarker: String
        if match.range(at: 4).location != NSNotFound {
            nextMarker = "\(marker) [ ] "
        } else if marker.hasSuffix("."), let rawNumber = Int(marker.dropLast()) {
            let number = MarkdownOrderedListItem.items(in: source)
                .first { $0.markerRange.location == line.contentRange.location }?
                .displayNumber ?? rawNumber
            nextMarker = "\(number + 1). "
        } else {
            nextMarker = "\(marker) "
        }

        let edit: MarkdownEdit
        if caret < contentStart {
            // Return before the text keeps the item whole and opens an empty item above it.
            let opened = indentation + (marker.hasSuffix(".") ? "1. " : nextMarker) + "\n"
            edit = MarkdownEdit(
                range: NSRange(location: line.contentRange.location, length: 0),
                replacement: opened,
                selection: NSRange(location: contentStart + (opened as NSString).length, length: 0)
            )
        } else {
            let insertion = "\n" + indentation + nextMarker
            edit = MarkdownEdit(
                range: NSRange(location: caret, length: 0),
                replacement: insertion,
                selection: NSRange(location: caret + (insertion as NSString).length, length: 0)
            )
        }
        return renumbered(after: edit, in: source)
    }

    private static func quoteNewline(
        _ match: NSTextCheckingResult,
        line: MarkdownSourceLine,
        caret: Int,
        in source: String
    ) -> MarkdownEdit? {
        let lineText = line.text(in: source as NSString) as NSString
        let markerRange = match.range(at: 1)
        let content = lineText.substring(with: match.range(at: 2))
        let contentStart = line.contentRange.location + match.range(at: 2).location
        guard caret >= contentStart else { return nil }

        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            return MarkdownEdit(
                range: line.contentRange,
                replacement: "",
                selection: NSRange(location: line.contentRange.location, length: 0)
            )
        }
        let depth = lineText.substring(with: markerRange).filter { $0 == ">" }.count
        let insertion = "\n" + String(repeating: "> ", count: depth)
        return MarkdownEdit(
            range: NSRange(location: caret, length: 0),
            replacement: insertion,
            selection: NSRange(location: caret + (insertion as NSString).length, length: 0)
        )
    }

    /// Rewrites a typed rule line through `MarkdownInsertion.horizontalRule`, so it gets the
    /// same blank-line padding (no setext heading above it) and leaves the caret below.
    private static func rule(replacing line: MarkdownSourceLine, in source: String) -> MarkdownEdit {
        let text = source as NSString
        let rule = text.substring(with: line.contentRange).trimmingCharacters(in: .whitespaces)
        let withoutLine = text.replacingCharacters(in: line.contentRange, with: "")
        let insertion = MarkdownInsertion.horizontalRule(
            in: withoutLine,
            selection: NSRange(location: line.contentRange.location, length: 0)
        )
        // Keep the rule characters the writer typed.
        let replacement = insertion.replacement.replacingOccurrences(of: "---", with: rule)
        let delta = (replacement as NSString).length - (insertion.replacement as NSString).length
        let result = (withoutLine as NSString).replacingCharacters(in: insertion.range, with: replacement)
        return MarkdownEdit(
            replacing: source,
            with: result,
            selection: NSRange(location: insertion.selection.location + delta, length: 0)
        )
    }

    // MARK: - Tab

    /// Tab or Shift-Tab over list items indents or outdents every selected item by
    /// `MarkdownVisualSpec.listIndentColumns` spaces and renumbers ordered lists. Returns nil
    /// when a selected non-blank line is not a list item, and an unchanged edit when the
    /// items can't move further.
    public static func indent(in source: String, selection: NSRange, outdent: Bool) -> MarkdownEdit? {
        let width = MarkdownVisualSpec.listIndentColumns
        let text = source as NSString
        let lines = MarkdownSourceLine.lines(covering: selection, in: text)
        guard let first = lines.first, let last = lines.last else { return nil }
        let blockRange = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)

        var replacement = ""
        var shifts: [(location: Int, removed: Int, inserted: Int)] = []
        var containsListItem = false
        for line in lines {
            let raw = text.substring(with: line.range)
            let content = line.text(in: text)
            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                replacement += raw
                continue
            }
            guard let match = listMarkerExpression.firstMatch(
                in: content,
                range: NSRange(location: 0, length: (content as NSString).length)
            ) else { return nil }
            containsListItem = true
            if outdent {
                let removed = leadingWhitespaceToRemove(from: (content as NSString).substring(with: match.range(at: 1)), width: width)
                replacement += (raw as NSString).substring(from: removed)
                if removed > 0 { shifts.append((line.range.location, removed, 0)) }
            } else {
                replacement += String(repeating: " ", count: width) + raw
                shifts.append((line.range.location, 0, width))
            }
        }
        guard containsListItem else { return nil }
        guard !shifts.isEmpty else { return .unchanged(selection: selection) }

        func mapped(_ location: Int) -> Int {
            var delta = 0
            for shift in shifts {
                guard location > shift.location else { break }
                if location <= shift.location + shift.removed {
                    return shift.location + delta + shift.inserted
                }
                delta += shift.inserted - shift.removed
            }
            return location + delta
        }
        let start = mapped(selection.location)
        let end = mapped(NSMaxRange(selection))
        let edit = MarkdownEdit(
            range: blockRange,
            replacement: replacement,
            selection: NSRange(location: start, length: max(0, end - start))
        )
        return renumbered(after: edit, in: source)
    }

    /// Up to one indentation level of leading whitespace, counting a tab as reaching the
    /// next stop.
    private static func leadingWhitespaceToRemove(from indentation: String, width: Int) -> Int {
        var columns = 0
        var count = 0
        for character in indentation {
            guard columns < width else { break }
            columns += character == "\t" ? width - (columns % width) : 1
            count += 1
        }
        return count
    }

    /// Where Tab or Shift-Tab moves inside a table: the next or previous cell's text,
    /// selected. Returns nil outside a table; at the first or last cell it keeps the
    /// selection so the key never inserts a tab into the table.
    public static func tableCellSelection(in source: String, selection: NSRange, forward: Bool) -> NSRange? {
        let text = source as NSString
        let codeRanges = MarkdownCodeBlock.blocks(in: source).map(\.sourceRange)
        let caret = min(selection.location, text.length)
        let lineStart = MarkdownSourceLine(containing: caret, in: text).range.location
        guard let table = MarkdownTable.tables(in: source, excluding: codeRanges).first(where: {
            NSLocationInRange(lineStart, $0.sourceRange)
        }) else { return nil }
        let cells = ([table.header] + table.rows).flatMap(\.cells)
        // The current cell is the last one starting at or before the caret.
        let current = cells.lastIndex { $0.location <= caret } ?? -1
        let target: Int
        if forward {
            target = current + 1
        } else if current >= 0, caret <= NSMaxRange(cells[current]) {
            target = current - 1
        } else {
            target = current
        }
        guard cells.indices.contains(target) else { return selection }
        return cells[target]
    }

    /// Whether `location` is inside a fenced code block's content, where Tab inserts a tab.
    public static func isInsideCodeBlock(_ location: Int, in source: String) -> Bool {
        MarkdownCodeBlock.blocks(in: source).contains {
            location >= $0.contentRange.location && location <= NSMaxRange($0.contentRange)
                && $0.contentRange.length > 0
        }
    }

    // MARK: - Delete

    /// Backspace right after a list marker outdents a nested item one level and otherwise
    /// removes the marker; Forward Delete right before a marker removes it.
    public static func deleteAtListMarker(in source: String, selection: NSRange, forward: Bool) -> MarkdownEdit? {
        guard selection.length == 0 else { return nil }
        let text = source as NSString
        let caret = min(selection.location, text.length)
        let line = MarkdownSourceLine(containing: caret, in: text)
        let content = line.text(in: text)
        guard let match = listMarkerExpression.firstMatch(
            in: content,
            range: NSRange(location: 0, length: (content as NSString).length)
        ) else { return nil }
        let markerRange = NSRange(location: line.contentRange.location + match.range.location, length: match.range.length)
        guard forward ? caret == markerRange.location : caret == NSMaxRange(markerRange) else { return nil }

        if !forward, match.range(at: 1).length > 0 {
            return indent(in: source, selection: selection, outdent: true)
        }
        let edit = MarkdownEdit(
            range: markerRange,
            replacement: "",
            selection: NSRange(location: markerRange.location, length: 0)
        )
        return renumbered(after: edit, in: source)
    }

    // MARK: - Numbering

    /// Rewrites ordered list numbers to count from each list's first number, keeping the
    /// selection on the same text. Nil when every number is already right.
    public static func renumberOrderedLists(in source: String, selection: NSRange) -> MarkdownEdit? {
        let changes = MarkdownOrderedListItem.items(in: source).compactMap { item -> (range: NSRange, replacement: String)? in
            item.rawNumber == item.displayNumber ? nil : (item.numberRange, "\(item.displayNumber)")
        }
        guard !changes.isEmpty else { return nil }
        let result = NSMutableString(string: source)
        for change in changes.reversed() {
            result.replaceCharacters(in: change.range, with: change.replacement)
        }

        func mapped(_ location: Int, preferEnd: Bool) -> Int {
            var delta = 0
            for change in changes {
                let length = (change.replacement as NSString).length
                if location < change.range.location { break }
                if location == change.range.location {
                    return change.range.location + delta + (preferEnd ? length : 0)
                }
                if location <= NSMaxRange(change.range) {
                    return change.range.location + delta + length
                }
                delta += length - change.range.length
            }
            return location + delta
        }
        let start = mapped(selection.location, preferEnd: false)
        let end = mapped(NSMaxRange(selection), preferEnd: selection.length > 0)
        return MarkdownEdit(
            replacing: source,
            with: result as String,
            selection: NSRange(location: start, length: max(0, end - start))
        )
    }

    /// `edit` followed by renumbering, as one edit.
    private static func renumbered(after edit: MarkdownEdit, in source: String) -> MarkdownEdit {
        let edited = edit.applied(to: source)
        guard let renumber = renumberOrderedLists(in: edited, selection: edit.selection) else { return edit }
        return MarkdownEdit(replacing: source, with: renumber.applied(to: edited), selection: renumber.selection)
    }

    // MARK: - Typing shortcuts

    /// Shortcuts completed by typing `replacement` over `selection`:
    /// - a space after `[ ]` (or `[]`) at the start of a line makes a checklist item;
    /// - a third backtick opening a fence adds the closing fence below.
    /// Returns the whole edit, including what was typed.
    public static func typingShortcut(in source: String, selection: NSRange, replacement: String) -> MarkdownEdit? {
        guard selection.length == 0, replacement == " " || replacement == "`" else { return nil }
        let text = source as NSString
        let caret = selection.location
        let line = MarkdownSourceLine(containing: caret, in: text)
        let beforeCaret = text.substring(with: NSRange(location: line.contentRange.location, length: caret - line.contentRange.location))
        let afterCaret = text.substring(with: NSRange(location: caret, length: NSMaxRange(line.contentRange) - caret))

        // Fenced code only: an indented `[ ]` line reads as indented code until it becomes
        // a checklist item.
        if replacement == " ",
           !MarkdownCodeBlock.blocks(in: source).contains(where: {
               $0.openingRange != nil && NSLocationInRange(caret, $0.contentRange)
           }),
           let match = checklistShortcutExpression.firstMatch(in: beforeCaret, range: NSRange(location: 0, length: (beforeCaret as NSString).length)) {
            let indentation = (beforeCaret as NSString).substring(with: match.range(at: 1))
            let marker = indentation + "- [ ] "
            let range = NSRange(location: line.contentRange.location, length: (beforeCaret as NSString).length)
            return MarkdownEdit(
                range: range,
                replacement: marker,
                selection: NSRange(location: range.location + (marker as NSString).length, length: 0)
            )
        }

        if replacement == "`",
           afterCaret.trimmingCharacters(in: .whitespaces).isEmpty,
           matches(fenceShortcutExpression, beforeCaret) {
            let typed = text.replacingCharacters(in: selection, with: "`")
            let opensUnclosedFence = MarkdownCodeBlock.blocks(in: typed).contains {
                $0.openingRange?.location == line.contentRange.location && $0.closingRange == nil
            }
            guard opensUnclosedFence else { return nil }
            let indentation = String(beforeCaret.prefix { $0 == " " || $0 == "\t" })
            let insertion = "`\n" + indentation + "```"
            return MarkdownEdit(
                range: selection,
                replacement: insertion,
                selection: NSRange(location: caret + 1, length: 0)
            )
        }
        return nil
    }

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }
}

/// One line of Markdown source: its full range (newline included) and its content.
struct MarkdownSourceLine {
    let range: NSRange
    let contentRange: NSRange

    init(range: NSRange, in source: NSString) {
        self.range = range
        var end = NSMaxRange(range)
        while end > range.location, [unichar(10), unichar(13)].contains(source.character(at: end - 1)) {
            end -= 1
        }
        contentRange = NSRange(location: range.location, length: end - range.location)
    }

    init(containing location: Int, in source: NSString) {
        self.init(range: source.lineRange(for: NSRange(location: min(location, source.length), length: 0)), in: source)
    }

    func text(in source: NSString) -> String {
        source.substring(with: contentRange)
    }

    /// The lines a selection touches. A selection ending at a line start doesn't include
    /// that line.
    static func lines(covering selection: NSRange, in source: NSString) -> [MarkdownSourceLine] {
        let start = min(selection.location, source.length)
        let end = min(NSMaxRange(selection), source.length)
        let lastCharacter = selection.length > 0 ? max(start, end - 1) : start
        var lines: [MarkdownSourceLine] = []
        var location = start
        repeat {
            let line = MarkdownSourceLine(containing: location, in: source)
            lines.append(line)
            location = NSMaxRange(line.range)
        } while location <= lastCharacter && location < source.length
        return lines
    }
}
