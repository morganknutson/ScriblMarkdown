import AppKit

@MainActor
final class ImagePreviewWindowController: NSObject, NSWindowDelegate {
    static let shared = ImagePreviewWindowController()

    private weak var previewWindow: NSWindow?

    func present(image: NSImage, fileURL: URL, from parentWindow: NSWindow) {
        dismissCurrentPreview()

        let screenFrame = parentWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let maximumSize = NSSize(
            width: max(640, (screenFrame?.width ?? 1200) * 0.8),
            height: max(480, (screenFrame?.height ?? 800) * 0.8)
        )
        let imageRatio = max(image.size.width, 1) / max(image.size.height, 1)
        var contentSize = NSSize(
            width: min(max(image.size.width, 560), maximumSize.width),
            height: min(max(image.size.height, 380), maximumSize.height)
        )
        if contentSize.width / contentSize.height > imageRatio {
            contentSize.width = max(560, contentSize.height * imageRatio)
        } else {
            contentSize.height = max(380, contentSize.width / imageRatio)
        }
        contentSize.width = min(contentSize.width, maximumSize.width)
        contentSize.height = min(contentSize.height, maximumSize.height)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = fileURL.deletingPathExtension().lastPathComponent
        window.minSize = NSSize(width: 420, height: 280)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentView = makeImageView(image: image, size: contentSize)
        previewWindow = window
        parentWindow.beginSheet(window)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let parent = sender.sheetParent {
            parent.endSheet(sender)
            sender.orderOut(nil)
            previewWindow = nil
            return false
        }
        previewWindow = nil
        return true
    }

    private func makeImageView(image: NSImage, size: NSSize) -> NSView {
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let imageView = NSImageView(frame: .zero)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.setAccessibilityLabel("Image preview")

        let closeButton = NSButton(
            image: NSImage(
                systemSymbolName: "xmark",
                accessibilityDescription: "Close image preview"
            ) ?? NSImage(),
            target: self,
            action: #selector(closePreview)
        )
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.contentTintColor = .white
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.toolTip = "Close image preview (Esc)"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.wantsLayer = true
        closeButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.68).cgColor
        closeButton.layer?.cornerRadius = 16
        closeButton.layer?.cornerCurve = .continuous
        closeButton.setAccessibilityLabel("Close image preview")

        container.addSubview(imageView)
        container.addSubview(closeButton)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            imageView.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),

            closeButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32)
        ])
        return container
    }

    @objc private func closePreview() {
        dismissCurrentPreview()
    }

    private func dismissCurrentPreview() {
        guard let previewWindow else { return }
        if let parent = previewWindow.sheetParent {
            parent.endSheet(previewWindow)
        }
        previewWindow.orderOut(nil)
        self.previewWindow = nil
    }
}
