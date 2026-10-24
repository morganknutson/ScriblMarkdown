import CoreGraphics
import Foundation

/// The platform-neutral half of the shared Markdown look: sizes, symbols and labels every
/// surface (the editors, the display renderer, Scribl's iOS editor) draws with. Apps supply
/// only theme values such as colors, font families and the body size.
public enum MarkdownVisualSpec {
    /// The body size every other size is designed against.
    public static let referenceBodySize: CGFloat = 17
    /// Heading sizes for levels 1–6 at `referenceBodySize`.
    public static let referenceHeadingSizes: [CGFloat] = [32, 24, 19, 17, 15, 14]
    /// Inline and block code at `referenceBodySize`.
    public static let referenceCodeSize: CGFloat = 15
    /// Footnote definitions at `referenceBodySize`.
    public static let referenceFootnoteSize: CGFloat = 15
    /// Columns of indentation that make one list nesting level.
    public static let listIndentColumns = 4
    /// Bullets by nesting depth; deeper levels repeat the last.
    public static let bulletSymbols = ["\u{2022}", "\u{25E6}", "\u{25AA}"]

    /// The heading size for `level` (clamped to 1–6) relative to `bodySize`.
    public static func headingSize(level: Int, bodySize: CGFloat) -> CGFloat {
        referenceHeadingSizes[min(max(level, 1), referenceHeadingSizes.count) - 1] * bodySize / referenceBodySize
    }

    public static func bulletSymbol(depth: Int) -> String {
        bulletSymbols[min(max(depth, 0), bulletSymbols.count - 1)]
    }

    /// The ordered list label for `number` at `depth`: "1." at the top level, "a." one
    /// level down, "i." two levels down, then repeating.
    public static func orderedLabel(number: Int, depth: Int) -> String {
        switch max(depth, 0) % 3 {
        case 0: return "\(number)."
        case 1: return alphabeticLabel(for: number) + "."
        default: return romanLabel(for: number) + "."
        }
    }

    /// The nesting depth of a list item indented by `indentation`: any indentation up to
    /// `listIndentColumns` columns is one level deeper. Tabs advance to the next stop.
    public static func listDepth(ofIndentation indentation: String) -> Int {
        let columns = indentation.reduce(into: 0) { columns, character in
            columns += character == "\t" ? listIndentColumns - (columns % listIndentColumns) : 1
        }
        return columns == 0 ? 0 : (columns + listIndentColumns - 1) / listIndentColumns
    }

    private static func alphabeticLabel(for number: Int) -> String {
        var value = max(1, number)
        var label = ""
        while value > 0 {
            value -= 1
            label.insert(Character(UnicodeScalar(97 + value % 26)!), at: label.startIndex)
            value /= 26
        }
        return label
    }

    private static func romanLabel(for number: Int) -> String {
        let numerals: [(Int, String)] = [
            (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
            (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")
        ]
        var value = min(max(1, number), 3999)
        var label = ""
        for (amount, numeral) in numerals {
            while value >= amount {
                label += numeral
                value -= amount
            }
        }
        return label
    }
}
