#if os(macOS)
import AppKit

/// A code block's header bar: the language on the left, an optional file path in the
/// middle, and pop-out and copy buttons on the right, over a hairline border. Shared by
/// `MarkdownCodeBlockView` and the live editor's code block overlay.
public final class MarkdownCodeBlockHeaderView: NSView {
    public static let height: CGFloat = 28

    /// Called by the pop-out button; nil hides it.
    public var onPopOut: (() -> Void)? {
        didSet { popOutButton.isHidden = onPopOut == nil }
    }
    /// The text the copy button puts on the pasteboard.
    public var copyText: (() -> String)?
    /// Hides the language label, for the live editor, which shows the fence's own
    /// editable language text under the header instead.
    public var hidesLanguage = false {
        didSet { languageLabel.isHidden = hidesLanguage || languageLabel.stringValue.isEmpty }
    }

    private let border = NSView()
    private let languageLabel = NSTextField(labelWithString: "")
    private let filePathLabel = NSTextField(labelWithString: "")
    private let popOutButton = MarkdownHoverButton(symbolName: "arrow.up.left.and.arrow.down.right", accessibilityLabel: "Pop Out Code")
    private let copyButton = MarkdownHoverButton(symbolName: "doc.on.doc", accessibilityLabel: "Copy Code")
    private var theme: MarkdownTheme?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        border.wantsLayer = true
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)

        languageLabel.translatesAutoresizingMaskIntoConstraints = false
        languageLabel.isSelectable = false
        languageLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        languageLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        addSubview(languageLabel)

        filePathLabel.translatesAutoresizingMaskIntoConstraints = false
        filePathLabel.isSelectable = false
        filePathLabel.lineBreakMode = .byTruncatingHead
        filePathLabel.maximumNumberOfLines = 1
        filePathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        filePathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        filePathLabel.isHidden = true
        addSubview(filePathLabel)

        popOutButton.target = self
        popOutButton.action = #selector(popOut)
        popOutButton.isHidden = true
        copyButton.target = self
        copyButton.action = #selector(copy(_:))
        addSubview(popOutButton)
        addSubview(copyButton)

        let filePathCenter = filePathLabel.centerXAnchor.constraint(equalTo: centerXAnchor)
        filePathCenter.priority = .defaultHigh
        let copyWidth = copyButton.widthAnchor.constraint(equalToConstant: 24)
        copyWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            languageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            languageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            filePathLabel.leadingAnchor.constraint(greaterThanOrEqualTo: languageLabel.trailingAnchor, constant: 8),
            filePathCenter,
            filePathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            filePathLabel.trailingAnchor.constraint(lessThanOrEqualTo: popOutButton.leadingAnchor, constant: -8),
            popOutButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -2),
            popOutButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            popOutButton.widthAnchor.constraint(equalToConstant: 24),
            popOutButton.heightAnchor.constraint(equalToConstant: 20),
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            copyButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            copyWidth,
            copyButton.heightAnchor.constraint(equalToConstant: 20),
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public func configure(language: String?, filePath: String?, theme: MarkdownTheme) {
        let language = language?.trimmingCharacters(in: .whitespaces) ?? ""
        languageLabel.stringValue = language.uppercased()
        languageLabel.isHidden = hidesLanguage || language.isEmpty
        if let filePath, !filePath.isEmpty {
            filePathLabel.stringValue = (filePath as NSString).pathComponents.suffix(2).joined(separator: "/")
            filePathLabel.isHidden = false
        } else {
            filePathLabel.stringValue = ""
            filePathLabel.isHidden = true
        }
        apply(theme)
    }

    public func apply(_ theme: MarkdownTheme) {
        self.theme = theme
        let surface = theme.surface
        border.layer?.backgroundColor = surface.border.cgColor
        languageLabel.font = surface.headerFont
        languageLabel.textColor = surface.headerText
        filePathLabel.font = surface.filePathFont
        filePathLabel.textColor = surface.filePathText
        for button in [popOutButton, copyButton] {
            button.contentTintColor = surface.controlTint
        }
        surface.installTooltip(popOutButton, "Pop Out Code")
        surface.installTooltip(copyButton, "Copy Code")
    }

    /// Only the buttons take clicks; the rest of the bar lets them through to what is
    /// underneath, such as the editor's text.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is NSButton ? hit : nil
    }

    @objc private func popOut() {
        onPopOut?()
    }

    @objc private func copy(_ sender: Any?) {
        guard let text = copyText?() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyButton.showConfirmation("Copied")
    }
}

/// A borderless symbol button that brightens on hover, used in block headers and the
/// editor's block overlays.
public final class MarkdownHoverButton: NSButton {
    private static let restingAlpha: CGFloat = 0.6
    private let symbolImage: NSImage?
    private var hoverArea: NSTrackingArea?
    private var confirmationGeneration = 0

    /// Called on click when the button has no target and action of its own.
    public var onPress: (() -> Void)?

    public init(symbolName: String, accessibilityLabel: String) {
        symbolImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        super.init(frame: .zero)
        bezelStyle = .inline
        isBordered = false
        image = symbolImage
        imagePosition = .imageOnly
        title = ""
        alphaValue = Self.restingAlpha
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel(accessibilityLabel)
        target = self
        action = #selector(press)
    }

    @objc private func press() {
        onPress?()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Swaps the symbol for `text` briefly, such as "Copied".
    public func showConfirmation(_ text: String) {
        confirmationGeneration += 1
        let generation = confirmationGeneration
        title = text
        image = nil
        imagePosition = .noImage
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.confirmationGeneration == generation else { return }
            self.title = ""
            self.image = self.symbolImage
            self.imagePosition = .imageOnly
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    public override func mouseEntered(with event: NSEvent) {
        alphaValue = 1
    }

    public override func mouseExited(with event: NSEvent) {
        alphaValue = Self.restingAlpha
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}
#endif

#if os(macOS)
/// The metrics a code block's gutter and padding share between the display view and the
/// live editor.
public enum MarkdownCodeBlockLayout {
    /// Space on each side of the line numbers, and above and below the code.
    public static let gutterPadding: CGFloat = 14

    /// The gutter's width for `lineCount` lines numbered in `font`.
    public static func gutterWidth(lineCount: Int, font: NSFont) -> CGFloat {
        let digits = String(repeating: "0", count: String(max(lineCount, 1)).count) as NSString
        return ceil(gutterPadding + digits.size(withAttributes: [.font: font]).width + gutterPadding)
    }
}
#endif
