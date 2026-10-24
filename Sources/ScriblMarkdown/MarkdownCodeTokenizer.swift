import Foundation

/// A lexical token in fenced code: its range in the code and what it is. Platform
/// highlighters map kinds to their theme's colors.
public struct MarkdownCodeToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable, CaseIterable {
        case keyword
        case string
        case comment
        case number
        case type
        case function
        case property
        case punctuation
        case `operator`
    }

    public let range: NSRange
    public let kind: Kind

    public init(range: NSRange, kind: Kind) {
        self.range = range
        self.kind = kind
    }
}

/// The shared code lexer: keyword sets for common languages, a generic markup and data
/// pass for the rest, and strings and comments last so tokens inside them keep their
/// kind. Every code block on every platform colors from these tokens.
public enum MarkdownCodeTokenizer {
    private static let keywordSets: [String: Set<String>] = [
        "swift": ["import", "func", "var", "let", "class", "struct", "enum", "protocol", "extension",
                  "if", "else", "guard", "switch", "case", "default", "for", "while", "repeat",
                  "return", "throw", "throws", "try", "catch", "do", "break", "continue",
                  "self", "Self", "super", "init", "deinit", "nil", "true", "false",
                  "public", "private", "internal", "fileprivate", "open", "static", "override",
                  "weak", "unowned", "lazy", "mutating", "inout", "where", "as", "is", "in",
                  "typealias", "associatedtype", "some", "any", "async", "await"],
        "python": ["def", "class", "if", "elif", "else", "for", "while", "return", "import",
                   "from", "as", "try", "except", "finally", "raise", "with", "yield",
                   "lambda", "pass", "break", "continue", "and", "or", "not", "is", "in",
                   "None", "True", "False", "self", "async", "await", "global", "nonlocal"],
        "javascript": ["function", "var", "let", "const", "if", "else", "for", "while", "do",
                       "return", "throw", "try", "catch", "finally", "switch", "case", "default",
                       "break", "continue", "new", "this", "class", "extends", "super",
                       "import", "export", "from", "async", "await", "yield", "of", "in",
                       "typeof", "instanceof", "void", "delete", "true", "false", "null", "undefined"],
        "typescript": ["function", "var", "let", "const", "if", "else", "for", "while", "do",
                       "return", "throw", "try", "catch", "finally", "switch", "case", "default",
                       "break", "continue", "new", "this", "class", "extends", "super",
                       "import", "export", "from", "async", "await", "yield", "of", "in",
                       "typeof", "instanceof", "void", "delete", "true", "false", "null", "undefined",
                       "type", "interface", "enum", "namespace", "declare", "as", "is",
                       "keyof", "readonly", "private", "public", "protected", "static", "abstract"],
        "rust": ["fn", "let", "mut", "const", "if", "else", "match", "for", "while", "loop",
                 "return", "break", "continue", "struct", "enum", "impl", "trait", "type",
                 "pub", "mod", "use", "crate", "self", "Self", "super", "where", "as",
                 "async", "await", "move", "ref", "static", "unsafe", "extern", "dyn",
                 "true", "false", "Some", "None", "Ok", "Err"],
        "go": ["func", "var", "const", "if", "else", "for", "range", "switch", "case", "default",
               "return", "break", "continue", "type", "struct", "interface", "map", "chan",
               "package", "import", "go", "defer", "select", "fallthrough", "goto",
               "true", "false", "nil", "iota"],
        "bash": ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case",
                 "esac", "function", "return", "exit", "echo", "export", "local", "readonly",
                 "shift", "source", "in", "until", "select", "true", "false"],
        "json": [],
        "html": [],
        "css": [],
        "ruby": ["def", "class", "module", "if", "elsif", "else", "unless", "case", "when",
                 "while", "until", "for", "do", "end", "begin", "rescue", "ensure", "raise",
                 "return", "yield", "self", "super", "nil", "true", "false",
                 "require", "include", "extend", "attr_reader", "attr_writer", "attr_accessor"],
        "c": ["if", "else", "for", "while", "do", "switch", "case", "default", "break",
              "continue", "return", "goto", "typedef", "struct", "union", "enum",
              "void", "int", "char", "float", "double", "long", "short", "unsigned", "signed",
              "const", "static", "extern", "register", "volatile", "sizeof", "NULL"],
        "cpp": ["if", "else", "for", "while", "do", "switch", "case", "default", "break",
                "continue", "return", "goto", "typedef", "struct", "union", "enum", "class",
                "void", "int", "char", "float", "double", "long", "short", "unsigned", "signed",
                "const", "static", "extern", "register", "volatile", "sizeof", "NULL",
                "namespace", "using", "template", "typename", "virtual", "override",
                "public", "private", "protected", "new", "delete", "this", "throw", "try", "catch",
                "true", "false", "nullptr", "auto", "constexpr", "noexcept"],
        "java": ["if", "else", "for", "while", "do", "switch", "case", "default", "break",
                 "continue", "return", "class", "interface", "extends", "implements",
                 "public", "private", "protected", "static", "final", "abstract",
                 "void", "int", "char", "float", "double", "long", "short", "boolean", "byte",
                 "new", "this", "super", "throw", "throws", "try", "catch", "finally",
                 "import", "package", "instanceof", "true", "false", "null", "enum",
                 "synchronized", "volatile", "transient", "native"],
    ]

    /// Common fence names mapped to the keyword set they use.
    private static let languageAliases: [String: String] = [
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
        "ts": "typescript", "tsx": "typescript", "py": "python", "rb": "ruby", "rs": "rust",
        "sh": "bash", "shell": "bash", "zsh": "bash", "golang": "go", "c++": "cpp", "cc": "cpp",
        "h": "c", "objc": "c", "xml": "html", "svg": "html", "plist": "html", "jsonc": "json",
        "scss": "css", "less": "css"
    ]

    /// Tokens in application order; later tokens win where they overlap.
    public static func tokens(in code: String, language: String?) -> [MarkdownCodeToken] {
        guard !code.isEmpty else { return [] }
        let lowercased = language?.lowercased() ?? ""
        let lang = languageAliases[lowercased] ?? lowercased
        let fullRange = NSRange(location: 0, length: (code as NSString).length)
        var tokens: [MarkdownCodeToken] = []

        func add(_ pattern: String, _ kind: MarkdownCodeToken.Kind) {
            guard let regex = RegexCache.shared.regex(for: pattern) else { return }
            for match in regex.matches(in: code, range: fullRange) {
                tokens.append(MarkdownCodeToken(range: match.range, kind: kind))
            }
        }

        add(#"[{}\[\](),.;:]"#, .punctuation)
        add(#"[+*/%=!<>?&|^~\-]+"#, .operator)
        add(#"\b[A-Z][A-Za-z0-9_]*\b"#, .type)
        add(#"(?<=\.)[A-Za-z_][A-Za-z0-9_]*\b|@[A-Za-z_][A-Za-z0-9_]*\b"#, .property)
        add(#"\b[a-zA-Z_][A-Za-z0-9_]*(?=\s*\()"#, .function)

        if let keywords = keywordSets[lang], !keywords.isEmpty {
            add(#"\b\d+\.?\d*\b"#, .number)
            add("\\b(" + keywords.sorted().joined(separator: "|") + ")\\b", .keyword)
        } else {
            // Markup and data: numbers, tag names, attribute names, literals.
            add(#"\b\d+\.?\d*\b"#, .number)
            add(#"</?\s*[a-zA-Z][a-zA-Z0-9-]*"#, .keyword)
            add(#"\b[a-zA-Z-]+(?=\s*=)"#, .property)
            add(#"\b(true|false|null|nil|None)\b"#, .keyword)
        }

        // Strings and comments last, in one pass, so tokens inside them (including quotes
        // inside comments) keep the region's color.
        let hashComments = ["bash", "python", "ruby", "yaml", "toml"].contains(lang)
        let comments = #"<!--[\s\S]*?-->|/\*[\s\S]*?\*/|//[^\n]*"# + (hashComments ? #"|#[^\n]*"# : "")
        let strings = #""(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|`(?:[^`\\]|\\.)*`"#
        if let regex = RegexCache.shared.regex(for: "(" + comments + ")|(" + strings + ")") {
            for match in regex.matches(in: code, range: fullRange) {
                let kind: MarkdownCodeToken.Kind = match.range(at: 1).location == NSNotFound ? .string : .comment
                tokens.append(MarkdownCodeToken(range: match.range, kind: kind))
            }
        }
        return tokens
    }

    /// A best guess at untagged code's language.
    public static func detectLanguage(_ code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"<[a-zA-Z/][^>]*>"#, options: .regularExpression) != nil {
            return "html"
        }
        if trimmed.contains("import ") && (trimmed.contains("func ") || trimmed.contains("struct ") || trimmed.contains("class ")) {
            return "swift"
        }
        if trimmed.range(of: #"\bdef \w+\("#, options: .regularExpression) != nil {
            return "python"
        }
        if trimmed.contains("const ") || trimmed.contains("=> ") || trimmed.range(of: #"\bfunction\s"#, options: .regularExpression) != nil {
            return "javascript"
        }
        if trimmed.range(of: #"\bfn \w+"#, options: .regularExpression) != nil {
            return "rust"
        }
        if trimmed.hasPrefix("package ") || trimmed.range(of: #"\bfunc \w+"#, options: .regularExpression) != nil {
            return "go"
        }
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) {
            return "json"
        }
        return nil
    }

    /// The comment prefix for a language ("//" for Swift, "#" for Python).
    public static func commentPrefix(for language: String?) -> String {
        switch language {
        case "python", "ruby", "bash", "yaml": return "#"
        case "lua", "sql": return "--"
        case "html", "xml": return "<!--"
        default: return "//"
        }
    }

    /// The language a file extension's code is highlighted as.
    public static func language(forFileExtension fileExtension: String) -> String? {
        switch fileExtension.lowercased() {
        case "swift": return "swift"
        case "py": return "python"
        case "js", "jsx", "mjs", "cjs": return "javascript"
        case "ts", "tsx": return "typescript"
        case "go": return "go"
        case "rs": return "rust"
        case "rb": return "ruby"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "c", "h": return "c"
        case "cpp", "cc", "cxx", "hpp": return "cpp"
        case "sh", "bash", "zsh": return "bash"
        case "html", "htm": return "html"
        case "css", "scss", "less": return "css"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        case "xml", "plist", "svg": return "xml"
        case "lua": return "lua"
        case "sql": return "sql"
        case "md", "markdown": return "markdown"
        case "toml": return "toml"
        default: return nil
        }
    }
}

/// Compiled patterns, shared across highlights. The pattern set is small and fixed per
/// language, so the cache stays bounded. Thread-safe.
private final class RegexCache: @unchecked Sendable {
    static let shared = RegexCache()

    private var regexes: [String: NSRegularExpression] = [:]
    private let lock = NSLock()

    func regex(for pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let regex = regexes[pattern] { return regex }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        regexes[pattern] = regex
        return regex
    }
}
