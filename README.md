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
cards, how they open, web link previews (`WebLinkMetadataProviding`) and diagnostics. Every
requirement has a default.
