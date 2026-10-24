// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "ScriblMarkdown",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // Platform-neutral Markdown parsing and editing rules shared by every Scribl and Addy surface.
        .library(name: "ScriblMarkdown", targets: ["ScriblMarkdown"]),
        // Rich text (HTML) to Markdown conversion, for pasting and importing.
        .library(name: "ScriblMarkdownHTML", targets: ["ScriblMarkdownHTML"]),
        // The shared AppKit look: theme, code/table/image block views and preview panels.
        .library(name: "ScriblMarkdownUI", targets: ["ScriblMarkdownUI"]),
        // The AppKit live-styling editor built on the parsers.
        .library(name: "ScriblMarkdownEditor", targets: ["ScriblMarkdownEditor"]),
        // Read-only AppKit rendering of a parsed document, for display surfaces.
        .library(name: "ScriblMarkdownRenderer", targets: ["ScriblMarkdownRenderer"])
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.7")
    ],
    targets: [
        .target(name: "ScriblMarkdown"),
        .target(name: "ScriblMarkdownHTML", dependencies: ["ScriblMarkdown", "SwiftSoup"]),
        .target(name: "ScriblMarkdownUI", dependencies: ["ScriblMarkdown"]),
        .target(name: "ScriblMarkdownRenderer", dependencies: ["ScriblMarkdown", "ScriblMarkdownUI"]),
        .target(name: "ScriblMarkdownEditor", dependencies: ["ScriblMarkdown", "ScriblMarkdownHTML", "ScriblMarkdownUI", "ScriblMarkdownRenderer"]),
        .testTarget(name: "ScriblMarkdownTests", dependencies: ["ScriblMarkdown"]),
        .testTarget(name: "ScriblMarkdownHTMLTests", dependencies: ["ScriblMarkdownHTML"]),
        .testTarget(name: "ScriblMarkdownUITests", dependencies: ["ScriblMarkdownUI"]),
        .testTarget(name: "ScriblMarkdownEditorTests", dependencies: ["ScriblMarkdownEditor"]),
        .testTarget(name: "ScriblMarkdownRendererTests", dependencies: ["ScriblMarkdownRenderer"])
    ]
)
