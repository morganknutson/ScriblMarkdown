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
    }

    public let id = UUID()
    public let action: Action

    public init(action: Action) {
        self.action = action
    }
}
