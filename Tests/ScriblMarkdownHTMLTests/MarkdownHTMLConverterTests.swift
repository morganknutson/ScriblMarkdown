import XCTest
import ScriblMarkdownHTML

final class MarkdownHTMLConverterTests: XCTestCase {
    private let converter = MarkdownHTMLConverter()

    func testConvertsRichTextToTheEditorsMarkdown() {
        let html = """
        <meta charset="utf-8"><style>p { color: red }</style>
        <h2>Plan</h2>
        <p>Some <b>bold </b>and <a href="https://scribl.ing">a link</a>.</p>
        <ul><li>One<ul><li>Nested<ul><li>Deeper</li></ul></li></ul></li><li><input type="checkbox" checked>Done</li></ul>
        <pre><code class="language-swift">let x = 1</code></pre>
        """
        let markdown = converter.convert(html: html, plaintext: nil).markdown
        XCTAssertEqual(markdown, """
        ## Plan

        Some **bold** and [a link](https://scribl.ing).

        - One
            - Nested
                - Deeper
        - [x] Done

        ```swift
        let x = 1
        ```

        """)
    }

    func testPasteKeepsPlainTextForStyledCode() {
        let colored = #"<div><span style="color: blue">let</span> <span>x_y</span> = 1</div>"#
        XCTAssertNil(converter.markdownForPaste(html: colored, plainText: "let x_y = 1"))
        XCTAssertEqual(converter.markdownForPaste(html: "<p><em>Hi</em></p>", plainText: "Hi"), "*Hi*")
    }
}
