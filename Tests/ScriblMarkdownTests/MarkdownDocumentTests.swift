import XCTest
@testable import ScriblMarkdown

final class MarkdownDocumentTests: XCTestCase {
    func testParsesEveryBlockKind() {
        let markdown = """
        # Title

        First line
        second line

        - Bullet
            - Nested
        - [x] Done
        1. One
        2. Two
        > Quoted
        >> Deeper

        ---

        ![Diagram](images/d.png)

        | Name | Count |
        |:-----|------:|
        | a \\| b | 2 |

        ```swift
        let x = 1
        ```

        Note[^n].

        [^n]: The note.
        """
        let document = MarkdownDocument(parsing: markdown)

        XCTAssertEqual(document.blocks, [
            .heading(level: 1, text: "Title"),
            .paragraph("First line\nsecond line"),
            .listItem(MarkdownListItem(depth: 0, marker: .bullet, text: "Bullet")),
            .listItem(MarkdownListItem(depth: 1, marker: .bullet, text: "Nested")),
            .listItem(MarkdownListItem(depth: 0, marker: .task(isChecked: true), text: "Done")),
            .listItem(MarkdownListItem(depth: 0, marker: .ordered(number: 1, label: "1."), text: "One")),
            .listItem(MarkdownListItem(depth: 0, marker: .ordered(number: 2, label: "2."), text: "Two")),
            .quote(depth: 1, text: "Quoted"),
            .quote(depth: 2, text: "Deeper"),
            .thematicBreak,
            .image(source: "images/d.png", alternateText: "Diagram"),
            .table(MarkdownTableContent(
                headers: ["Name", "Count"],
                alignments: [.leading, .trailing],
                rows: [["a | b", "2"]]
            )),
            .codeBlock(code: "let x = 1", language: "swift"),
            .paragraph("Note[^n]."),
            .footnote(label: "n", ordinal: 1, text: "The note."),
        ])
        XCTAssertEqual(document.footnoteOrdinals, ["n": 1])
    }

    func testDropsHTMLCommentsAndIgnoresMarkdownInsideCode() {
        let document = MarkdownDocument(parsing: "<!-- hidden -->\n```\n# not a heading\n- not a list\n```\n")
        XCTAssertEqual(document.blocks, [.codeBlock(code: "# not a heading\n- not a list", language: nil)])
    }

    func testInlineRunsStripMarkersAndCarryStyles() {
        let runs = MarkdownInlineParser.runs(in: "Use **bold _both_** and `code *x*` see [docs](https://a.dev) \\* &amp;")
        XCTAssertEqual(runs.map(\.text).joined(), "Use bold both and code *x* see docs * &")
        XCTAssertEqual(runs.first { $0.text == "both" }?.styles, [.strong, .emphasis])
        XCTAssertEqual(runs.first { $0.text == "code *x*" }?.styles, [.code])
        XCTAssertEqual(runs.first { $0.text == "docs" }?.link, "https://a.dev")
    }

    func testEmphasisNeverMatchesInsideLinkDestinations() {
        let runs = MarkdownInlineParser.runs(in: "[a](https://x.dev/some_path_here) _real_")
        XCTAssertEqual(runs.map(\.text).joined(), "a real")
        XCTAssertEqual(runs.last?.styles, [.emphasis])
    }

    func testFootnoteReferencesBecomeNumbers() {
        let runs = MarkdownInlineParser.runs(in: "See[^src] and[^unknown]", footnoteOrdinals: ["src": 3])
        XCTAssertEqual(runs.map(\.text).joined(), "See3 and[^unknown]")
        XCTAssertEqual(runs.first { $0.footnoteOrdinal == 3 }?.text, "3")
    }

    func testPlainTextDropsMarkupAndCode() {
        let document = MarkdownDocument(parsing: "## Plan\n\nRun `make` then **ship** via [CI](https://ci).\n\n```\nmake\n```\n- [ ] Test\n")
        XCTAssertEqual(document.plainText(), "Plan\nRun  then ship via CI.\nTest")
    }
}

final class MarkdownHTMLRendererTests: XCTestCase {
    func testRendersBlocksListsAndInlineStyles() {
        let html = MarkdownHTMLRenderer().html(for: MarkdownDocument(parsing: """
        ## Changes
        Fixed **crash** in `Foo<T>` & [docs](https://a.dev)
        - One
            - Nested
        - [x] Done
        3. Three
        4. Four
        > Quote
        ---
        """))
        XCTAssertEqual(html, """
        <h2>Changes</h2>
        <p>Fixed <strong>crash</strong> in <code>Foo&lt;T&gt;</code> &amp; <a href="https://a.dev">docs</a></p>
        <ul>
        <li>One<ul>
        <li>Nested</li></ul>
        </li>
        <li><input type="checkbox" disabled checked> Done</li></ul>
        <ol start="3">
        <li>Three</li>
        <li>Four</li></ol>
        <blockquote>
        <p>Quote</p>
        </blockquote>
        <hr>

        """)
    }
}
