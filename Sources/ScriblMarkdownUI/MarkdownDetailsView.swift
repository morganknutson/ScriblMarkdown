#if os(macOS)
import AppKit

/// A read-only `<details>` block. The summary toggles its fully rendered Markdown body.
public final class MarkdownDetailsView: NSStackView {
    public var theme: MarkdownTheme {
        didSet {
            header.theme = theme
            spacing = theme.scaled(5)
            bodyIndent.constant = theme.scaled(20)
        }
    }

    public var summary: NSAttributedString {
        didSet { header.summary = summary }
    }

    public var isExpanded: Bool {
        didSet {
            header.isExpanded = isExpanded
            bodyContainer.isHidden = !isExpanded
            invalidateIntrinsicContentSize()
        }
    }

    private let header: MarkdownDetailsHeaderView
    private let bodyContainer = NSView()
    private var bodyIndent: NSLayoutConstraint!

    public init(summary: NSAttributedString, body: NSView, theme: MarkdownTheme, isExpanded: Bool) {
        self.summary = summary
        self.theme = theme
        self.isExpanded = isExpanded
        header = MarkdownDetailsHeaderView(summary: summary, theme: theme, isExpanded: isExpanded)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = theme.scaled(5)
        translatesAutoresizingMaskIntoConstraints = false

        header.onToggle = { [weak self] in self?.isExpanded.toggle() }
        addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: widthAnchor).isActive = true

        body.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.addSubview(body)
        bodyIndent = body.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor, constant: theme.scaled(20))
        NSLayoutConstraint.activate([
            bodyIndent,
            body.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            body.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
        ])
        addArrangedSubview(bodyContainer)
        bodyContainer.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        bodyContainer.isHidden = !isExpanded
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

private final class MarkdownDetailsHeaderView: NSView {
    var onToggle: (() -> Void)?
    var theme: MarkdownTheme {
        didSet { needsDisplay = true }
    }
    var summary: NSAttributedString {
        didSet {
            label.attributedStringValue = summary
            invalidateIntrinsicContentSize()
        }
    }
    var isExpanded: Bool {
        didSet {
            needsDisplay = true
            setAccessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        }
    }

    private let label = NSTextField(wrappingLabelWithString: "")

    init(summary: NSAttributedString, theme: MarkdownTheme, isExpanded: Bool) {
        self.summary = summary
        self.theme = theme
        self.isExpanded = isExpanded
        super.init(frame: .zero)
        label.isSelectable = false
        label.maximumNumberOfLines = 0
        label.attributedStringValue = summary
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: max(22, label.fittingSize.height))
    }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width - 20)
        if abs(label.preferredMaxLayoutWidth - width) > 0.5 {
            label.preferredMaxLayoutWidth = width
            invalidateIntrinsicContentSize()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        MarkdownDrawnMarkers.drawDisclosureChevron(
            at: NSPoint(x: 8, y: bounds.midY),
            isExpanded: isExpanded,
            color: theme.palette.accent,
            flipped: true
        )
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onToggle?()
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.charactersIgnoringModifiers == "\r" {
            onToggle?()
        } else {
            super.keyDown(with: event)
        }
    }
}
#endif
