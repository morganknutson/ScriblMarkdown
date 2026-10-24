#if os(macOS)
import AppKit

/// A fenced code block: a header with the language, file path, pop-out and copy buttons,
/// syntax-colored code with line numbers, and a "Show N more lines" toggle for long code.
/// Size it by width; it reports its height as its intrinsic size.
public final class MarkdownCodeBlockView: NSView {
    /// Code longer than this many lines starts collapsed.
    public static let collapseThreshold = 25
    /// Lines shown while collapsed.
    public static let previewLineCount = 12

    public var theme: MarkdownTheme {
        didSet { applyTheme() }
    }
    /// A pop-out preview shows everything, with no pop-out button or collapsing.
    public var isInPreview = false {
        didSet { configure(code: code, language: language, filePath: filePath) }
    }
    /// Called when expanding or collapsing changes the view's height, so an enclosing list
    /// or table can re-measure.
    public var onContentSizeChanged: (() -> Void)?

    public private(set) var code = ""
    public private(set) var language: String?
    public private(set) var filePath: String?

    private let header = MarkdownCodeBlockHeaderView()
    private let codeView = MarkdownCodeView()
    private let toggleLabel = NSTextField(labelWithString: "")
    private var isExpanded = false
    private var isCollapsible = false
    private var previewPanel: MarkdownContentPreviewPanel?
    /// The code ends the block, or the toggle below it does.
    private var codeAtBottom: [NSLayoutConstraint] = []
    private var toggleAtBottom: [NSLayoutConstraint] = []

    public init(theme: MarkdownTheme) {
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true

        header.copyText = { [weak self] in self?.code ?? "" }
        header.onPopOut = { [weak self] in self?.popOut() }
        addSubview(header)
        addSubview(codeView)

        toggleLabel.translatesAutoresizingMaskIntoConstraints = false
        toggleLabel.isSelectable = false
        toggleLabel.isHidden = true
        toggleLabel.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(toggleExpanded)))
        addSubview(toggleLabel)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            codeView.topAnchor.constraint(equalTo: header.bottomAnchor),
            codeView.leadingAnchor.constraint(equalTo: leadingAnchor),
            codeView.trailingAnchor.constraint(equalTo: trailingAnchor),
            toggleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
        codeAtBottom = [codeView.bottomAnchor.constraint(equalTo: bottomAnchor)]
        toggleAtBottom = [
            toggleLabel.topAnchor.constraint(equalTo: codeView.bottomAnchor, constant: 2),
            toggleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ]
        NSLayoutConstraint.activate(codeAtBottom)
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public func configure(code: String, language: String?, filePath: String? = nil) {
        self.code = code
        self.language = language
        self.filePath = filePath
        isCollapsible = !isInPreview && code.components(separatedBy: "\n").count > Self.collapseThreshold
        isExpanded = !isCollapsible
        header.onPopOut = isInPreview ? nil : { [weak self] in self?.popOut() }
        header.configure(language: language, filePath: filePath, theme: theme)
        updateDisplayedCode()
        updateToggle()
    }

    private func applyTheme() {
        layer?.backgroundColor = theme.surface.background.cgColor
        layer?.cornerRadius = theme.surface.cornerRadius
        header.apply(theme)
        toggleLabel.font = theme.surface.labelFont
        toggleLabel.textColor = theme.surface.toggleText
        updateDisplayedCode()
        needsLayout = true
    }

    private func updateDisplayedCode() {
        let shown = isCollapsible && !isExpanded
            ? code.components(separatedBy: "\n").prefix(Self.previewLineCount).joined(separator: "\n")
            : code
        codeView.configure(code: shown, language: language, theme: theme)
        invalidateIntrinsicContentSize()
    }

    private func updateToggle() {
        toggleLabel.isHidden = !isCollapsible
        NSLayoutConstraint.deactivate(isCollapsible ? codeAtBottom : toggleAtBottom)
        NSLayoutConstraint.activate(isCollapsible ? toggleAtBottom : codeAtBottom)
        guard isCollapsible else { return }
        let hidden = code.components(separatedBy: "\n").count - Self.previewLineCount
        toggleLabel.stringValue = isExpanded ? "Show less" : "Show \(hidden) more lines"
    }

    @objc private func toggleExpanded() {
        isExpanded.toggle()
        updateDisplayedCode()
        updateToggle()
        var ancestor = superview
        while let view = ancestor {
            if let stack = view as? NSStackView { stack.needsLayout = true }
            ancestor = view.superview
        }
        onContentSizeChanged?()
    }

    private func popOut() {
        let preview = MarkdownCodeBlockView(theme: theme)
        preview.isInPreview = true
        preview.configure(code: code, language: language, filePath: filePath)
        previewPanel = .present(
            title: "Code Preview",
            previewView: preview,
            background: theme.surface.previewBackground,
            from: self,
            replacing: previewPanel
        )
    }

    public override var intrinsicContentSize: NSSize {
        let toggleHeight: CGFloat = toggleLabel.isHidden ? 0 : 22
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: MarkdownCodeBlockHeaderView.height + codeView.intrinsicContentSize.height + toggleHeight
        )
    }

    public override func resetCursorRects() {
        if !toggleLabel.isHidden {
            addCursorRect(toggleLabel.frame, cursor: .arrow)
        }
    }
}
#endif
