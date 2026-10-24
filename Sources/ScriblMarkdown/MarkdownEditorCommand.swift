import Foundation

public struct MarkdownEditorCommand: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case title
        case heading
        case subheading
        case smallHeading
        case body
        case quote
        case bold
        case italic
        case inlineCode
        case bulletedList
        case numberedList
        case checklist
        case codeBlock
        /// Links the selection, or inserts a link labelled `title` (or the destination).
        case link(title: String?, destination: String)
        /// Asks for a link to add, or edits the link at the caret, in the link popover.
        case editLink
        case horizontalRule
    }

    public let id = UUID()
    public let action: Action

    public init(action: Action) {
        self.action = action
    }
}

/// A keyboard shortcut for an editor command. The Mac editor handles `all` itself, and
/// hosts show the same keys in their menus and toolbars.
public struct MarkdownEditorShortcut: Equatable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    /// The unshifted key: "b", "1".
    public let key: String
    public let modifiers: Modifiers
    public let action: MarkdownEditorCommand.Action
    /// The command's name for menus.
    public let title: String

    public init(key: String, modifiers: Modifiers, action: MarkdownEditorCommand.Action, title: String) {
        self.key = key
        self.modifiers = modifiers
        self.action = action
        self.title = title
    }

    public static let all: [MarkdownEditorShortcut] = [
        .init(key: "b", modifiers: .command, action: .bold, title: "Bold"),
        .init(key: "i", modifiers: .command, action: .italic, title: "Italic"),
        .init(key: "e", modifiers: .command, action: .inlineCode, title: "Code"),
        .init(key: "k", modifiers: .command, action: .editLink, title: "Link"),
        .init(key: "1", modifiers: [.command, .shift], action: .title, title: "Heading 1"),
        .init(key: "2", modifiers: [.command, .shift], action: .heading, title: "Heading 2"),
        .init(key: "3", modifiers: [.command, .shift], action: .subheading, title: "Heading 3"),
        .init(key: "0", modifiers: [.command, .shift], action: .body, title: "Body"),
        .init(key: "7", modifiers: [.command, .shift], action: .bulletedList, title: "Bulleted List"),
        .init(key: "8", modifiers: [.command, .shift], action: .numberedList, title: "Numbered List"),
        .init(key: "9", modifiers: [.command, .shift], action: .quote, title: "Quote"),
    ]

    /// The shortcut for an unshifted `key` pressed with exactly `modifiers`.
    public static func matching(key: String, modifiers: Modifiers) -> MarkdownEditorShortcut? {
        let key = key.lowercased()
        return all.first { $0.key == key && $0.modifiers == modifiers }
    }

    /// The shortcut that runs `action`, for showing its keys in a menu.
    public static func shortcut(for action: MarkdownEditorCommand.Action) -> MarkdownEditorShortcut? {
        all.first { $0.action == action }
    }
}
