// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "ScriblMarkdown",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // Platform-neutral Markdown parsing shared by every Scribl and Addy surface.
        .library(name: "ScriblMarkdown", targets: ["ScriblMarkdown"]),
        // The AppKit live-styling editor built on the parsers.
        .library(name: "ScriblMarkdownEditor", targets: ["ScriblMarkdownEditor"])
    ],
    targets: [
        .target(name: "ScriblMarkdown"),
        .target(name: "ScriblMarkdownEditor", dependencies: ["ScriblMarkdown"]),
        .testTarget(name: "ScriblMarkdownEditorTests", dependencies: ["ScriblMarkdownEditor"])
    ]
)
