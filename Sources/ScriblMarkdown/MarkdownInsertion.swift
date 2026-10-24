import Foundation

/// A replacement in Markdown source and the selection to leave afterwards.
public struct MarkdownEdit: Equatable {
    public let range: NSRange
    public let replacement: String
    public let selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }

    /// The edit that turns `source` into `result`: the smallest replacement between their
    /// common prefix and suffix, which keeps undo and restyling local to what changed.
    /// `selection` is in `result`'s coordinates.
    public init(replacing source: String, with result: String, selection: NSRange) {
        let old = source as NSString
        let new = result as NSString
        let limit = min(old.length, new.length)
        var prefix = 0
        while prefix < limit, old.character(at: prefix) == new.character(at: prefix) {
            prefix += 1
        }
        // Never split a surrogate pair at the start of the changed range.
        if prefix > 0, prefix < limit, UTF16.isLeadSurrogate(old.character(at: prefix - 1)) {
            prefix -= 1
        }
        var suffix = 0
        while suffix < limit - prefix,
              old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) {
            suffix += 1
        }
        if suffix > 0, suffix < limit - prefix,
           UTF16.isTrailSurrogate(old.character(at: old.length - suffix)) {
            suffix -= 1
        }
        self.init(
            range: NSRange(location: prefix, length: old.length - prefix - suffix),
            replacement: new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix)),
            selection: selection
        )
    }

    /// An edit that changes nothing: the rule handled the keystroke but had nothing to do.
    public static func unchanged(selection: NSRange) -> MarkdownEdit {
        MarkdownEdit(range: NSRange(location: selection.location, length: 0), replacement: "", selection: selection)
    }

    public var changesText: Bool { range.length > 0 || !replacement.isEmpty }

    /// `source` with this edit applied.
    public func applied(to source: String) -> String {
        (source as NSString).replacingCharacters(in: range, with: replacement)
    }
}

/// Source edits for inserting Markdown constructs, shared by every editor surface.
public enum MarkdownInsertion {
    /// Replaces `selection` with an inline link. The label is `title`, else the selected
    /// text, else the destination itself.
    public static func link(
        title: String?,
        destination: String,
        in source: String,
        selection: NSRange
    ) -> MarkdownEdit {
        let selectedText = (source as NSString).substring(with: selection)
        let label = [title, selectedText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? destination
        let escapedLabel = label
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        let target = destination.contains(where: \.isWhitespace) ? "<\(destination)>" : destination
        let replacement = "[\(escapedLabel)](\(target))"
        return MarkdownEdit(
            range: selection,
            replacement: replacement,
            selection: NSRange(location: selection.location + (replacement as NSString).length, length: 0)
        )
    }

    /// Replaces `selection` with a `---` rule on its own line, padded with blank lines so
    /// the line above can't turn it into a setext heading.
    public static func horizontalRule(in source: String, selection: NSRange) -> MarkdownEdit {
        let text = source as NSString
        let start = selection.location
        let before = text.substring(to: start)
        let after = text.substring(from: NSMaxRange(selection))

        let leading: String
        if before.isEmpty || before.hasSuffix("\n\n") {
            leading = ""
        } else if before.hasSuffix("\n") {
            leading = "\n"
        } else {
            leading = "\n\n"
        }
        // Existing newlines after the selection count toward the blank line below the rule.
        let followingNewlines = after.hasPrefix("\n\n") ? 2 : (after.hasPrefix("\n") ? 1 : 0)
        let replacement = leading + "---" + String(repeating: "\n", count: 2 - followingNewlines)
        // Leave the caret on the line after the blank line below the rule.
        let caret = start + (replacement as NSString).length + followingNewlines
        return MarkdownEdit(
            range: selection,
            replacement: replacement,
            selection: NSRange(location: caret, length: 0)
        )
    }
}
