#if os(macOS)
import AppKit

/// The shared link editor: a popover with the link's text and address, opened by ⌘K or
/// the editor's link command. Return applies, Escape cancels, and Remove unlinks an
/// existing link.
public final class MarkdownLinkPopover: NSObject, NSPopoverDelegate {
    public typealias ApplyHandler = (_ title: String?, _ destination: String) -> Void

    private let popover = NSPopover()
    private let controller: MarkdownLinkPopoverController

    public init(theme: MarkdownTheme) {
        controller = MarkdownLinkPopoverController(theme: theme)
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = controller
        popover.delegate = self
        controller.onClose = { [weak self] in self?.popover.performClose(nil) }
    }

    public var isShown: Bool { popover.isShown }

    /// Shows the popover pointing at `rect` in `view`. `title` and `destination` prefill
    /// the fields; `onRemove` shows a Remove button for an existing link.
    public func show(
        relativeTo rect: NSRect,
        of view: NSView,
        title: String?,
        destination: String?,
        onApply: @escaping ApplyHandler,
        onRemove: (() -> Void)? = nil
    ) {
        controller.configure(title: title, destination: destination, onApply: onApply, onRemove: onRemove)
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        controller.focusFirstField()
    }

    public func close() {
        popover.performClose(nil)
    }
}

private final class MarkdownLinkPopoverController: NSViewController, NSTextFieldDelegate {
    var onClose: (() -> Void)?

    private let theme: MarkdownTheme
    private let titleField = NSTextField()
    private let destinationField = NSTextField()
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private var onApply: MarkdownLinkPopover.ApplyHandler?
    private var onRemove: (() -> Void)?

    init(theme: MarkdownTheme) {
        self.theme = theme
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let font = theme.typeface.font(ofSize: 13)
        let titleLabel = NSTextField(labelWithString: "Text")
        let destinationLabel = NSTextField(labelWithString: "Link")
        for label in [titleLabel, destinationLabel] {
            label.font = theme.typeface.font(ofSize: 12, trait: .boldFontMask)
            label.textColor = theme.palette.secondaryText
            label.alignment = .right
        }
        titleField.placeholderString = "Link text"
        destinationField.placeholderString = "https://"
        for field in [titleField, destinationField] {
            field.font = font
            field.delegate = self
            field.lineBreakMode = .byTruncatingMiddle
            field.cell?.usesSingleLineMode = true
        }
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(remove)
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.target = self
        applyButton.action = #selector(apply)

        let grid = NSGridView(views: [
            [titleLabel, titleField],
            [destinationLabel, destinationField],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 8
        grid.rowSpacing = 8
        let buttons = NSStackView(views: [removeButton, NSView(), applyButton])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        NSLayoutConstraint.activate([
            destinationField.widthAnchor.constraint(equalToConstant: 260),
            buttons.widthAnchor.constraint(equalTo: grid.widthAnchor),
        ])
        view = stack
    }

    func configure(
        title: String?,
        destination: String?,
        onApply: @escaping MarkdownLinkPopover.ApplyHandler,
        onRemove: (() -> Void)?
    ) {
        loadViewIfNeeded()
        titleField.stringValue = title ?? ""
        destinationField.stringValue = destination ?? ""
        self.onApply = onApply
        self.onRemove = onRemove
        removeButton.isHidden = onRemove == nil
        updateApplyButton()
    }

    func focusFirstField() {
        let field = destinationField.stringValue.isEmpty && !titleField.stringValue.isEmpty ? destinationField : titleField
        view.window?.makeFirstResponder(field)
    }

    func controlTextDidChange(_ notification: Notification) {
        updateApplyButton()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            apply()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onClose?()
            return true
        }
        return false
    }

    private func updateApplyButton() {
        applyButton.isEnabled = !destinationField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc private func apply() {
        let destination = destinationField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else { return }
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let onApply = onApply
        onClose?()
        onApply?(title.isEmpty ? nil : title, destination)
    }

    @objc private func remove() {
        let onRemove = onRemove
        onClose?()
        onRemove?()
    }
}
#endif
