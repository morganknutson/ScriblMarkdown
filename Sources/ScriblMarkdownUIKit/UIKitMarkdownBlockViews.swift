#if canImport(UIKit)
import UIKit

/// An overlay above editable Markdown source. Only its controls receive touches.
public class UIKitMarkdownBlockOverlayView: UIView {
    public let expandButton = UIButton(type: .system)
    public var theme: UIKitMarkdownTheme {
        didSet { applyTheme() }
    }
    public var onExpand: (() -> Void)?

    public init(theme: UIKitMarkdownTheme) {
        self.theme = theme
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        expandButton.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right"), for: .normal)
        expandButton.accessibilityLabel = "Open full screen"
        expandButton.addTarget(self, action: #selector(expand), for: .touchUpInside)
        addSubview(expandButton)
        applyTheme()
    }

    public required init?(coder: NSCoder) { nil }

    public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, isUserInteractionEnabled, alpha > 0.01 else { return nil }
        for button in interactiveButtons where !button.isHidden && button.isEnabled {
            let buttonFrame = button.frame.insetBy(dx: -8, dy: -8)
            if buttonFrame.contains(point) { return button }
        }
        return nil
    }

    public override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        interactiveButtons.contains { $0.frame.insetBy(dx: -8, dy: -8).contains(point) }
    }

    var interactiveButtons: [UIButton] { [expandButton] }

    func applyTheme() {
        tintColor = theme.quoteBar
        setNeedsDisplay()
    }

    public override func draw(_ rect: CGRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let inset = theme.borderWidth / 2
        let border = UIBezierPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset),
            cornerRadius: theme.cornerRadius
        )
        border.lineWidth = theme.borderWidth
        theme.codeBlockBorder.setStroke()
        border.stroke()
    }

    @objc private func expand() { onExpand?() }
}

/// Language header, copy, and expand controls over editable code source.
public final class UIKitMarkdownCodeBlockView: UIKitMarkdownBlockOverlayView {
    public let languageLabel = UILabel()
    public let copyButton = UIButton(type: .system)
    public private(set) var code = ""

    override var interactiveButtons: [UIButton] { [copyButton, expandButton] }

    public override init(theme: UIKitMarkdownTheme) {
        super.init(theme: theme)
        addSubview(languageLabel)
        copyButton.setImage(UIImage(systemName: "doc.on.doc"), for: .normal)
        copyButton.accessibilityLabel = "Copy code"
        copyButton.addTarget(self, action: #selector(copyCode), for: .touchUpInside)
        addSubview(copyButton)
        applyTheme()
    }

    public required init?(coder: NSCoder) { nil }

    public func configure(code: String, language: String?) {
        self.code = code
        languageLabel.text = language?.uppercased() ?? "CODE"
        accessibilityLabel = "Code block, \(language ?? "plain text")"
    }

    override func applyTheme() {
        super.applyTheme()
        languageLabel.font = theme.headerFont
        languageLabel.textColor = theme.secondaryText
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let headerHeight: CGFloat = 28
        let buttonSize: CGFloat = 24
        expandButton.frame = CGRect(x: bounds.maxX - buttonSize - 4, y: 2, width: buttonSize, height: buttonSize)
        copyButton.frame = CGRect(x: expandButton.frame.minX - buttonSize - 2, y: 2, width: buttonSize, height: buttonSize)
        languageLabel.frame = CGRect(x: 12, y: 0, width: max(0, copyButton.frame.minX - 18), height: headerHeight)
    }

    public override func draw(_ rect: CGRect) {
        super.draw(rect)
        theme.codeBlockBorder.setFill()
        UIRectFill(CGRect(x: 0, y: 27.5, width: bounds.width, height: 0.5))
    }

    @objc private func copyCode() { UIPasteboard.general.string = code }
}

/// Grid and expand control over editable table source.
public final class UIKitMarkdownTableView: UIKitMarkdownBlockOverlayView {
    public private(set) var rowDividers: [CGFloat] = []
    public private(set) var columnDividers: [CGFloat] = []

    public func configure(rowDividers: [CGFloat], columnDividers: [CGFloat]) {
        self.rowDividers = rowDividers
        self.columnDividers = columnDividers
        setNeedsDisplay()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        expandButton.frame = CGRect(x: bounds.maxX - 28, y: 2, width: 24, height: 24)
    }

    public override func draw(_ rect: CGRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        super.draw(rect)
        theme.tableBorder.setFill()
        for y in rowDividers {
            UIRectFill(CGRect(x: 0, y: y, width: bounds.width, height: 0.5))
        }
        for x in columnDividers {
            UIRectFill(CGRect(x: x, y: 0, width: 0.5, height: bounds.height))
        }
    }
}
#endif
