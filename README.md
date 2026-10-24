# ScriblMarkdown

The Markdown engine shared by [Scribl](https://github.com/morganknutson/Scribl) and Addy's notepad.

- **ScriblMarkdown** — platform-neutral parsers (lists, checklists, links, footnotes, tables,
  code blocks, math, images, linked-document cards). Foundation only; macOS and iOS.
- **ScriblMarkdownHTML** — rich text (HTML) to Markdown, for pasting and importing, and
  `MarkdownWebLinkMetadataService`, the safe web preview fetcher behind link cards.
- **ScriblMarkdownUI** — the shared AppKit look: `MarkdownTheme` (palette, typeface, body
  size, code/table surface, syntax colors), and the block views every surface shows:
  `MarkdownCodeBlockView`, `MarkdownTableView`, `MarkdownImageBlockView`, their pop-out
  panels, `MarkdownLinkCardView` and `MarkdownLinkPopover`.
- **ScriblMarkdownEditor** — the AppKit live-styling editor. It edits Markdown source directly
  and decorates it; the text is never converted to rich text.
- **ScriblMarkdownRenderer** — read-only AppKit rendering for display surfaces.

## One look, one set of editing rules

`MarkdownVisualSpec` (core) fixes what every surface draws: headings 1–6 on one scale
relative to the body size, bullets by depth (• ◦ ▪), ordered labels by depth (1. / a. / i.),
four-column list nesting. Apps supply only theme values through `MarkdownTheme`.

`MarkdownEditingRules` (core) holds the editing behaviors as source edits, so the Mac editor
and Scribl's iOS editor apply the same Markdown: Return continues lists and quotes (an empty
nested item steps out, an empty item or quote line ends it, `---` becomes a padded rule),
Tab and Shift-Tab indent items, move between table cells and type tabs in code, Backspace
after a marker outdents or removes it, ordered lists renumber after every edit, `[ ] `
makes a checklist and a third backtick closes the fence. `MarkdownEditorShortcut.all` is the
shared shortcut set (⌘B/I/E/K, ⌘⇧1–3 headings, ⌘⇧0 body, ⌘⇧7/8/9 bullet/number/quote),
which the Mac editor handles itself; hosts show the same keys in their menus.
`MarkdownCodeTokenizer` (core) lexes fenced code for every platform's highlighter.

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
cards, how they open, web link previews (`WebLinkMetadataProviding`, such as
`MarkdownWebLinkMetadataService.shared`), code block syntax colors (`MarkdownCodeHighlighting`;
the theme's `MarkdownSyntaxHighlighter` by default) and diagnostics. Every requirement has a
default. Use `MarkdownEditorStyle(theme:textContainerInset:)` to share a theme with display
surfaces.

The editor draws code block headers (language, copy, pop-out) with line numbers, and table
grids with a pop-out, over source that stays editable. Rich text pastes convert to Markdown;
pastes without Markdown-bearing formatting (colored code) stay plain text.

`editor.formatting` reports the formatting at the caret (heading level, bold, quote, code)
for toolbars; `onSelectionChange` says when to read it. `MarkdownInsertion` holds the
source edits behind commands like `.link` and `.horizontalRule`, so other editor surfaces
(Scribl's iOS editor) apply exactly the same Markdown.

## Displaying Markdown

`MarkdownDocument(parsing:)` produces blocks for paragraphs, ATX headings, lists,
quotes, code fences, tables, images, footnotes, `<details><summary>…</summary>…</details>`
and multiline `$$` math. Details have an inline summary and a nested body document.
`MarkdownHTMLRenderer` produces semantic HTML, while `MarkdownAttributedRenderer`
produces AppKit text or segments for hosts to show with the shared block views.
`MarkdownRenderStyle(theme:spacing:)` renders in the shared look (drawn checklists with
struck-through checked items, drawn rules, plain quotes with an accent bar, keycaps,
footnotes as the editor shows them); show it in a text view whose layout manager is a
`MarkdownDecorationLayoutManager`. `segments(for:…linkCards:)` turns a lone web address or
document link into a `.linkCard` segment for a `MarkdownLinkCardView`; use `.documents` where
web previews would fetch too much (chat).
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
