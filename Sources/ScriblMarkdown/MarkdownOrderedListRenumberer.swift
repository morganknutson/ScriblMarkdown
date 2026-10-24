import Foundation

/// Coalesces full-document renumbering for long notes away from the editing thread.
/// The caller verifies that its source is still current before applying the result.
public final class MarkdownOrderedListRenumberer {
    public static let backgroundThreshold = 16_384

    private let queue = DispatchQueue(label: "scribl.markdown.ordered-list-renumbering", qos: .userInitiated)
    private let lock = NSLock()
    private var generation: UInt64 = 0

    public init() {}

    public func schedule(
        in source: String,
        selection: NSRange,
        completion: @escaping (MarkdownEdit?) -> Void
    ) {
        let request = advanceGeneration()
        queue.async { [weak self] in
            guard let self, self.isCurrent(request) else { return }
            let edit = MarkdownEditingRules.renumberOrderedLists(in: source, selection: selection)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(request) else { return }
                completion(edit)
            }
        }
    }

    public func cancel() {
        _ = advanceGeneration()
    }

    private func advanceGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        return generation
    }

    private func isCurrent(_ request: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == request
    }
}
