#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// The full-screen view of an image block: the image on black, aspect-fit, with Save and
/// Copy buttons. Every surface's images open here, including the live editor's.
public final class MarkdownImagePreviewPanel: NSPanel {
    let previewView: MarkdownImagePreviewContentView

    public init(
        image: NSImage,
        originalData: Data?,
        mediaType: String?,
        title: String = "Image Preview",
        pasteboard: NSPasteboard = .general,
        availableFrame: NSRect? = nil
    ) {
        let visibleFrame = availableFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let availableContentSize = NSSize(
            width: min(1200, visibleFrame.width * 0.8),
            height: min(820, max(240, visibleFrame.height * 0.72 - 28))
        )
        let contentSize = Self.contentSize(for: image.size, availableContentSize: availableContentSize)
        previewView = MarkdownImagePreviewContentView(
            image: image,
            originalData: originalData,
            mediaType: mediaType,
            pasteboard: pasteboard
        )
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: true
        )
        self.title = title
        previewView.frame = NSRect(origin: .zero, size: contentSize)
        previewView.autoresizingMask = [.width, .height]
        contentView = previewView
        setContentSize(contentSize)
        contentAspectRatio = image.size
        isReleasedWhenClosed = false
        contentMinSize = Self.contentSize(
            for: image.size,
            availableContentSize: NSSize(width: 280, height: 280),
            preferredLongEdge: 280
        )
        setFrameOrigin(NSPoint(x: visibleFrame.midX - frame.width / 2, y: visibleFrame.midY - frame.height / 2))
    }

    public func present(over ownerWindow: NSWindow) {
        ownerWindow.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
    }

    /// Keep file I/O off the click handler; copy and save use the original bytes once loaded.
    public func loadOriginalData(from url: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = try? Data(contentsOf: url, options: .mappedIfSafe)
            DispatchQueue.main.async { [weak self] in
                self?.previewView.originalData = data
            }
        }
    }

    /// Shows a preview over `view`'s window and returns it so the presenter can keep it.
    public static func present(
        image: NSImage,
        originalData: Data?,
        mediaType: String?,
        title: String = "Image Preview",
        from view: NSView
    ) -> MarkdownImagePreviewPanel {
        let panel = MarkdownImagePreviewPanel(
            image: image,
            originalData: originalData,
            mediaType: mediaType,
            title: title,
            availableFrame: view.window?.screen?.visibleFrame
        )
        if let window = view.window {
            panel.present(over: window)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        return panel
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    public override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    /// The image's size scaled to fit `availableContentSize`, enlarging small images up
    /// to `preferredLongEdge`.
    public static func contentSize(
        for imageSize: NSSize,
        availableContentSize: NSSize,
        preferredLongEdge: CGFloat = 480
    ) -> NSSize {
        guard imageSize.width > 0, imageSize.height > 0,
              availableContentSize.width > 0, availableContentSize.height > 0 else {
            return NSSize(width: preferredLongEdge, height: preferredLongEdge)
        }
        let fitScale = min(availableContentSize.width / imageSize.width, availableContentSize.height / imageSize.height)
        let preferredScale = max(1, preferredLongEdge / max(imageSize.width, imageSize.height))
        let scale = min(fitScale, preferredScale)
        return NSSize(width: floor(imageSize.width * scale), height: floor(imageSize.height * scale))
    }
}

/// Draws an image aspect-fit and centered.
final class MarkdownAspectFitImageView: NSView {
    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let image else { return }
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: Self.aspectFitRect(imageSize: image.size, bounds: bounds),
            from: NSRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    static func aspectFitRect(imageSize: NSSize, bounds: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
}

final class MarkdownImagePreviewContentView: NSView {
    let actionBar = NSVisualEffectView()
    let saveButton = MarkdownImagePreviewContentView.makeButton(symbol: "square.and.arrow.down", label: "Save Image")
    let copyButton = MarkdownImagePreviewContentView.makeButton(symbol: "doc.on.doc", label: "Copy Image")

    private let imageView = MarkdownAspectFitImageView()
    private let image: NSImage
    var originalData: Data?
    private let mediaType: String?
    private let pasteboard: NSPasteboard

    init(image: NSImage, originalData: Data?, mediaType: String?, pasteboard: NSPasteboard) {
        self.image = image
        self.originalData = originalData
        self.mediaType = mediaType
        self.pasteboard = pasteboard
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        imageView.image = image
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        actionBar.material = .hudWindow
        actionBar.blendingMode = .withinWindow
        actionBar.state = .active
        actionBar.wantsLayer = true
        actionBar.layer?.cornerRadius = 10
        actionBar.layer?.masksToBounds = true
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actionBar)

        saveButton.target = self
        saveButton.action = #selector(saveImage)
        copyButton.target = self
        copyButton.action = #selector(copyImage)
        actionBar.addSubview(saveButton)
        actionBar.addSubview(copyButton)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            actionBar.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            actionBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            actionBar.heightAnchor.constraint(equalToConstant: 38),
            saveButton.leadingAnchor.constraint(equalTo: actionBar.leadingAnchor, constant: 5),
            saveButton.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor),
            saveButton.widthAnchor.constraint(equalToConstant: 28),
            saveButton.heightAnchor.constraint(equalToConstant: 28),
            copyButton.leadingAnchor.constraint(equalTo: saveButton.trailingAnchor, constant: 2),
            copyButton.trailingAnchor.constraint(equalTo: actionBar.trailingAnchor, constant: -5),
            copyButton.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 28),
            copyButton.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private static func makeButton(symbol: String, label: String) -> NSButton {
        let button = NSButton(frame: .zero)
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    @objc func copyImage() {
        let item = NSPasteboardItem()
        if let originalData, let mediaType {
            item.setData(originalData, forType: NSPasteboard.PasteboardType(Self.contentType(for: mediaType).identifier))
        }
        if let tiffData = image.tiffRepresentation {
            item.setData(tiffData, forType: .tiff)
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        let originalImage = copyButton.image
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak copyButton] in
            copyButton?.image = originalImage
        }
    }

    @objc private func saveImage() {
        guard let window, let data = Self.imageDataForSaving(image: image, originalData: originalData) else { return }
        let savePanel = NSSavePanel()
        let contentType = Self.contentType(for: mediaType)
        savePanel.allowedContentTypes = [contentType]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = "image.\(contentType.preferredFilenameExtension ?? "png")"
        savePanel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = savePanel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    static func imageDataForSaving(image: NSImage, originalData: Data?) -> Data? {
        if let originalData { return originalData }
        guard let tiffData = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    static func contentType(for mediaType: String?) -> UTType {
        switch mediaType?.lowercased() {
        case "image/jpeg", "image/jpg": .jpeg
        case "image/gif": .gif
        case "image/webp": .webP
        case "image/tiff": .tiff
        default: .png
        }
    }
}
#endif
