# ScriblMarkdown

The Markdown engine shared by [Scribl](https://github.com/morganknutson/Scribl) and Addy's notepad.

- **ScriblMarkdown** — platform-neutral parsers (lists, checklists, links, footnotes, tables,
  code blocks, math, images, linked-document cards). Foundation only; macOS and iOS.
- **ScriblMarkdownEditor** — the AppKit live-styling editor. It edits Markdown source directly
  and decorates it; the text is never converted to rich text.

## Embedding the editor

```swift
let editor = MarkdownEditorView(
    controller: MarkdownEditorController(
        documentURL: fileURL,               // relative images and links resolve against it
        style: MarkdownEditorStyle(palette: myPalette, typeface: myTypeface, bodyFontSize: 15),
        titlePolicy: .none,                 // or .protectedLeadingHeading(placeholder:)
        host: myHost,                       // optional MarkdownEditorHost
        onTextChange: { save($0) }
    ),
    text: markdown
)
editor.perform(.bold)
```

`MarkdownEditorHost` connects the editor to its app: which documents links can embed as
cards, how they open, web link previews (`WebLinkMetadataProviding`), code block syntax
colors (`MarkdownCodeHighlighting`) and diagnostics. Every requirement has a default.

`editor.formatting` reports the formatting at the caret (heading level, bold, quote, code)
for toolbars; `onSelectionChange` says when to read it. `MarkdownInsertion` holds the
source edits behind commands like `.link` and `.horizontalRule`, so other editor surfaces
(Scribl's iOS editor) apply exactly the same Markdown.

## Displaying Markdown

`MarkdownDocument(parsing:)` produces blocks for paragraphs, ATX headings, lists,
quotes, code fences, tables, images, footnotes, `<details><summary>…</summary>…</details>`
and multiline `$$` math. Details have an inline summary and a nested body document.
`MarkdownHTMLRenderer` produces semantic HTML, while `MarkdownAttributedRenderer`
produces AppKit text or sections for hosts with their own code, table and image views.
Inline links include `<https://…>` and bare HTTP(S) URLs; sentence punctuation stays
outside the link.

Display follows the live editor: setext headings and single-column tables remain
ordinary text. HTML comments are omitted. The editor's `MarkdownMathDisplay` supplies
the display text for math blocks.

For a host that repeatedly renders a growing document, keep a `MarkdownRenderCache`
with that surface and pass it to `attributedString(for:cache:)` or
`segments(for:cache:)`. The cache reuses unchanged blocks in the same position and
checks their neighbors and footnote numbering. Call `invalidate()` whenever the
`MarkdownRenderStyle` or link resolver changes. Calls without a cache behave as before.
