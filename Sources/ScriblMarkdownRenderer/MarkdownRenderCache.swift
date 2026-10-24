#if os(macOS)
import AppKit
import ScriblMarkdown

/// Host-owned cache for repeated renders of a growing document.
///
/// Call `invalidate()` whenever the renderer's style or link resolver changes. A cache is
/// intended for one render surface; it stores values by block position and its neighbors.
public final class MarkdownRenderCache {
    private struct Entry {
        let block: MarkdownBlock
        let previous: MarkdownBlock?
        let next: MarkdownBlock?
        let footnoteOrdinals: [String: Int]
        let value: NSAttributedString
    }

    private struct Position: Hashable {
        let scope: Int
        let index: Int
    }

    private var entries: [Position: Entry] = [:]

    public init() {}

    public func invalidate() {
        entries.removeAll()
    }

    func value(
        at index: Int,
        scope: Int,
        block: MarkdownBlock,
        previous: MarkdownBlock?,
        next: MarkdownBlock?,
        footnoteOrdinals: [String: Int]
    ) -> NSAttributedString? {
        guard let entry = entries[Position(scope: scope, index: index)],
              entry.block == block,
              entry.previous == previous,
              entry.next == next,
              entry.footnoteOrdinals == footnoteOrdinals else { return nil }
        return entry.value
    }

    func store(
        _ value: NSAttributedString,
        at index: Int,
        scope: Int,
        block: MarkdownBlock,
        previous: MarkdownBlock?,
        next: MarkdownBlock?,
        footnoteOrdinals: [String: Int]
    ) {
        entries[Position(scope: scope, index: index)] = Entry(
            block: block, previous: previous, next: next,
            footnoteOrdinals: footnoteOrdinals, value: NSAttributedString(attributedString: value)
        )
    }
}
#endif
