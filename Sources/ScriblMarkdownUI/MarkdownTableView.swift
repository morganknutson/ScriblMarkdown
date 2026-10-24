#if os(macOS)
import AppKit
import ScriblMarkdown

/// A Markdown table as a real grid: one wrapping text field per cell, column widths
/// measured from content and shrunk to fit the available width, a tinted header row,
/// hairline row dividers and a pop-out button. The parent supplies the width; the view
/// reports the resulting height as its intrinsic size.
public final class MarkdownTableView: NSView {
    public static let horizontalCellPadding: CGFloat = 10
    public static let verticalCellPadding: CGFloat = 6
    public static let minimumColumnWidth: CGFloat = 56
    /// Room kept in the header row's last cell for the pop-out button.
    public static let popOutButtonSpace: CGFloat = 28
    /// NSTextField labels draw with a little inset on each side; measuring accounts for it
    /// so widths don't wrap one word early.
    private static let fieldInset: CGFloat = 4

    /// Renders one cell's inline Markdown: its text, whether it is in the header row, and
    /// its column's alignment.
    public typealias CellRenderer = (_ text: String, _ isHeader: Bool, _ alignment: MarkdownTableAlignment) -> NSAttributedString

    public let table: MarkdownTableContent
    public var theme: MarkdownTheme {
        didSet { applyTheme() }
    }
    /// A pop-out preview has no pop-out button.
    public var isInPreview = false {
        didSet {
            measuredWidth = -1
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    private let cellRenderer: CellRenderer
    /// Carries the background, border and radius, sized to the table's content width so
    /// small tables stay compact.
    private let frameView = FlippedTableContainerView()
    private let headerBackground = NSView()
    private let popOutButton = MarkdownHoverButton(symbolName: "arrow.up.left.and.arrow.down.right", accessibilityLabel: "Pop Out Table")
    private var previewPanel: MarkdownContentPreviewPanel?
    /// `cells[0]` is the header row; `cells[1...]` are body rows.
    private var cells: [[NSTextField]] = []
    private var dividers: [NSView] = []

    private var columnWidths: [CGFloat] = []
    private var rowHeights: [CGFloat] = []
    private var tableWidth: CGFloat = 0
    private var tableHeight: CGFloat = 0
    private var measuredWidth: CGFloat = -1

    public override var isFlipped: Bool { true }

    public init(table: MarkdownTableContent, theme: MarkdownTheme, cellRenderer: @escaping CellRenderer) {
        self.table = table
        self.theme = theme
        self.cellRenderer = cellRenderer
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildSubviews()
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var allRows: [[String]] { [table.headers] + table.rows }

    private func buildSubviews() {
        frameView.wantsLayer = true
        frameView.layer?.masksToBounds = true
        addSubview(frameView)
        headerBackground.wantsLayer = true
        frameView.addSubview(headerBackground)

        popOutButton.translatesAutoresizingMaskIntoConstraints = true
        popOutButton.target = self
        popOutButton.action = #selector(popOut)
        frameView.addSubview(popOutButton)

        // Fields start empty: `reloadCells()` renders every cell once.
        for row in allRows {
            cells.append(row.indices.map { column in
                let field = Self.makeCellField()
                field.alignment = textAlignment(for: column)
                frameView.addSubview(field)
                return field
            })
        }
        // One divider under every row except the last.
        for _ in 0..<max(allRows.count - 1, 0) {
            let divider = NSView()
            divider.wantsLayer = true
            frameView.addSubview(divider)
            dividers.append(divider)
        }
    }

    private static func makeCellField() -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.isEditable = false
        field.isSelectable = true
        field.allowsEditingTextAttributes = true // required for clickable links
        field.drawsBackground = false
        field.isBordered = false
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func alignment(for column: Int) -> MarkdownTableAlignment {
        column < table.alignments.count ? table.alignments[column] : .leading
    }

    private func textAlignment(for column: Int) -> NSTextAlignment {
        switch alignment(for: column) {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
    }

    private func applyTheme() {
        let surface = theme.surface
        frameView.layer?.backgroundColor = surface.tableBodyBackground.cgColor
        frameView.layer?.borderColor = surface.tableBorder.cgColor
        frameView.layer?.borderWidth = surface.borderWidth
        frameView.layer?.cornerRadius = surface.cornerRadius
        headerBackground.layer?.backgroundColor = surface.tableHeaderBackground.cgColor
        popOutButton.contentTintColor = surface.controlTint
        surface.installTooltip(popOutButton, "Pop Out Table")
        for divider in dividers {
            divider.layer?.backgroundColor = surface.tableRowDivider.cgColor
        }
        reloadCells()
    }

    /// Renders every cell again, such as after the cell renderer's typography changed.
    public func reloadCells() {
        let baseFont = theme.bodyFont
        for (rowIndex, row) in allRows.enumerated() where rowIndex < cells.count {
            for (column, text) in row.enumerated() where column < cells[rowIndex].count {
                // The field's own font (selection, empty cells) is set before the text so it
                // can't flatten the rendered runs.
                cells[rowIndex][column].font = baseFont
                cells[rowIndex][column].attributedStringValue = cellRenderer(text, rowIndex == 0, alignment(for: column))
            }
        }
        measuredWidth = -1
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private var borderWidth: CGFloat { theme.surface.borderWidth }

    private func buttonSpace(row: Int, column: Int) -> CGFloat {
        !isInPreview && row == 0 && column == table.columnCount - 1 ? Self.popOutButtonSpace : 0
    }

    private func measure(_ text: NSAttributedString, width: CGFloat) -> NSSize {
        guard text.length > 0 else {
            let font = theme.bodyFont
            return NSSize(width: 0, height: ceil(font.ascender - font.descender + font.leading))
        }
        let rect = text.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return NSSize(width: ceil(rect.width), height: ceil(rect.height))
    }

    /// Column widths and row heights for `availableWidth`. Width beyond what the content
    /// needs is not consumed; when content exceeds the space, columns shrink in proportion
    /// to their slack down to `minimumColumnWidth`.
    private func computeLayout(availableWidth: CGFloat) {
        let columnCount = table.columnCount
        guard columnCount > 0 else {
            columnWidths = []
            rowHeights = []
            tableWidth = 0
            tableHeight = 0
            measuredWidth = availableWidth
            return
        }

        let horizontalPadding = Self.horizontalCellPadding * 2 + Self.fieldInset
        var natural = [CGFloat](repeating: 0, count: columnCount)
        for (rowIndex, row) in cells.enumerated() {
            for (column, field) in row.enumerated() where column < columnCount {
                let width = measure(field.attributedStringValue, width: .greatestFiniteMagnitude).width
                natural[column] = max(natural[column], width + horizontalPadding + buttonSpace(row: rowIndex, column: column))
            }
        }

        let inner = availableWidth > 0 ? availableWidth - borderWidth * 2 : .greatestFiniteMagnitude
        var widths = natural
        let totalNatural = natural.reduce(0, +)
        if totalNatural > inner {
            let minimums = natural.map { min($0, Self.minimumColumnWidth + horizontalPadding) }
            var excess = totalNatural - inner
            for _ in 0..<columnCount {
                let flexible = (0..<columnCount).filter { widths[$0] > minimums[$0] + 0.5 }
                guard !flexible.isEmpty, excess > 0.5 else { break }
                let slack = flexible.reduce(0) { $0 + (widths[$1] - minimums[$1]) }
                guard slack > 0 else { break }
                for column in flexible {
                    let share = (widths[column] - minimums[column]) / slack * excess
                    widths[column] -= min(share, widths[column] - minimums[column])
                }
                excess = widths.reduce(0, +) - inner
            }
            widths = widths.map { floor($0) }
        }

        var heights: [CGFloat] = []
        for (rowIndex, row) in cells.enumerated() {
            var rowHeight: CGFloat = 0
            for (column, field) in row.enumerated() where column < columnCount {
                let textWidth = max(widths[column] - horizontalPadding - buttonSpace(row: rowIndex, column: column), 1)
                rowHeight = max(rowHeight, measure(field.attributedStringValue, width: textWidth).height)
            }
            heights.append(ceil(max(rowHeight + Self.verticalCellPadding * 2, rowIndex == 0 && !isInPreview ? 28 : 0)))
        }

        columnWidths = widths
        rowHeights = heights
        tableWidth = widths.reduce(0, +) + borderWidth * 2
        tableHeight = heights.reduce(0, +) + borderWidth * 2 + CGFloat(dividers.count) * borderWidth
        measuredWidth = availableWidth
    }

    private func ensureLayout(for width: CGFloat) {
        if measuredWidth != width {
            computeLayout(availableWidth: width)
        }
    }

    public override var intrinsicContentSize: NSSize {
        ensureLayout(for: bounds.width)
        return NSSize(width: NSView.noIntrinsicMetric, height: tableHeight)
    }

    public override func layout() {
        super.layout()
        let previousHeight = tableHeight
        ensureLayout(for: bounds.width)

        let border = borderWidth
        frameView.frame = NSRect(x: 0, y: 0, width: tableWidth, height: tableHeight)
        popOutButton.isHidden = isInPreview
        popOutButton.frame = NSRect(x: frameView.bounds.width - 28, y: 3, width: 24, height: 22)

        var y = border
        for (rowIndex, row) in cells.enumerated() {
            let rowHeight = rowIndex < rowHeights.count ? rowHeights[rowIndex] : 0
            if rowIndex == 0 {
                headerBackground.frame = NSRect(x: 0, y: 0, width: frameView.bounds.width, height: y + rowHeight)
            }
            var x = border
            for (column, field) in row.enumerated() where column < columnWidths.count {
                let width = columnWidths[column]
                field.frame = NSRect(
                    x: x + Self.horizontalCellPadding,
                    y: y + Self.verticalCellPadding,
                    width: max(width - Self.horizontalCellPadding * 2 - buttonSpace(row: rowIndex, column: column), 1),
                    height: max(rowHeight - Self.verticalCellPadding * 2, 1)
                )
                x += width
            }
            y += rowHeight
            if rowIndex < dividers.count {
                dividers[rowIndex].frame = NSRect(x: 0, y: y, width: frameView.bounds.width, height: border)
                y += border
            }
        }

        if abs(previousHeight - tableHeight) > 0.5 {
            invalidateIntrinsicContentSize()
        }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            measuredWidth = -1
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    @objc private func popOut() {
        let preview = MarkdownTableView(table: table, theme: theme, cellRenderer: cellRenderer)
        preview.isInPreview = true
        previewPanel = .present(
            title: "Table Preview",
            previewView: preview,
            background: theme.surface.previewBackground,
            from: self,
            replacing: previewPanel
        )
    }
}

/// Lays out top-down so row frames read in source order.
private final class FlippedTableContainerView: NSView {
    override var isFlipped: Bool { true }
}
#endif
