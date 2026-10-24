import Foundation

public struct MarkdownEditorCommand: Equatable {
    public enum Action: Equatable {
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
        case horizontalRule
    }

    public let id = UUID()
    public let action: Action

    public init(action: Action) {
        self.action = action
    }
}
