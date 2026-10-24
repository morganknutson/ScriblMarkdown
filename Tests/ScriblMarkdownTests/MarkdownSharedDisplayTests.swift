import XCTest
@testable import ScriblMarkdown

final class MarkdownSharedDisplayTests: XCTestCase {
    func testLoneLinksBecomeCardsAsThePolicyAllows() {
        let document = MarkdownDocument(parsing: "Intro\n\nhttps://scribl.ing\n\n[Plan](Plan.md)\n\nSee https://scribl.ing now")
        func kinds(_ policy: MarkdownLinkCardPolicy) -> [String] {
            document.sections(linkCards: policy).map {
                switch $0 {
                case .text: "text"
                case .linkCard(.web): "web"
                case .linkCard(.note(let note)): "note:\(note.title)"
                case .codeBlock, .table, .image: "block"
                }
            }
        }
        XCTAssertEqual(kinds(.none), ["text"])
        XCTAssertEqual(kinds(.documents), ["text", "note:Plan", "text"])
        XCTAssertEqual(kinds(.all), ["text", "web", "note:Plan", "text"])
    }

    func testInlineKeycapsMathAndHTMLTagsDisplayAsTheEditorShowsThem() {
        let runs = MarkdownInlineParser.runs(in: "Press <kbd>⌘K</kbd> for $x^2$ and <span>tags</span> or <https://a.dev>")
        XCTAssertEqual(runs.filter(\.isKeycap).map(\.text), ["⌘K"])
        XCTAssertEqual(runs.filter(\.isMath).count, 1)
        let text = runs.map(\.text).joined()
        XCTAssertFalse(text.contains("<span>"))
        XCTAssertTrue(text.contains("https://a.dev"))
    }

    func testCodeTokensColorStringsAndCommentsLast() {
        let tokens = MarkdownCodeTokenizer.tokens(in: "let s = \"if\" // if", language: "swift")
        let source = "let s = \"if\" // if" as NSString
        let last = Dictionary(tokens.map { (source.substring(with: $0.range), $0.kind) }, uniquingKeysWith: { $1 })
        XCTAssertEqual(last["let"], .keyword)
        XCTAssertEqual(last["\"if\""], .string)
        XCTAssertEqual(last["// if"], .comment)
        XCTAssertEqual(MarkdownCodeTokenizer.language(forFileExtension: "tsx"), "typescript")
    }
}
