#if os(macOS)
import AppKit

/// A scrollable child window for reading a code block or table at a useful width: the
/// "pop out" behind every block's full-screen button.
public final class MarkdownContentPreviewPanel: NSPanel, NSWindowDelegate {
    private let scrollView = NSScrollView()
    private let documentView = FlippedPreviewDocumentView()
    public let previewView: NSView

    public init(title: String, previewView: NSView, background: NSColor, availableFrame: NSRect? = nil) {
        self.previewView = previewView
        let visibleFrame = availableFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let size = NSSize(width: min(960, visibleFrame.width * 0.8),
                          height: min(720, visibleFrame.height * 0.72))
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
                   backing: .buffered, defer: true)

        self.title = title
        isReleasedWhenClosed = false
        contentMinSize = NSSize(width: 320, height: 200)
        setFrameOrigin(NSPoint(x: visibleFrame.midX - frame.width / 2,
                               y: visibleFrame.midY - frame.height / 2))

        scrollView.frame = NSRect(origin: .zero, size: size)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        // Block views opt into Auto Layout, which would ignore the frames set in
        // updateDocumentSize() and collapse them to their minimum width.
        previewView.translatesAutoresizingMaskIntoConstraints = true
        documentView.addSubview(previewView)
        documentView.wantsLayer = true
        documentView.layer?.backgroundColor = background.cgColor
        scrollView.documentView = documentView
        contentView = scrollView
        delegate = self
        updateDocumentSize()
    }

    public func present(over ownerWindow: NSWindow) {
        ownerWindow.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
    }

    /// Shows the panel over `view`'s window, replacing `previous`, and returns it so the
    /// presenter can keep it alive.
    public static func present(
        title: String,
        previewView: NSView,
        background: NSColor,
        from view: NSView,
        replacing previous: MarkdownContentPreviewPanel?
    ) -> MarkdownContentPreviewPanel {
        let panel = MarkdownContentPreviewPanel(
            title: title,
            previewView: previewView,
            background: background,
            availableFrame: view.window?.screen?.visibleFrame
        )
        previous?.close()
        if let window = view.window {
            panel.present(over: window)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        return panel
    }

    public func windowDidResize(_ notification: Notification) {
        updateDocumentSize()
    }

    private func updateDocumentSize() {
        let width = max(scrollView.contentSize.width, 1)
        let contentWidth = max(width - 40, 1)
        previewView.setFrameSize(NSSize(width: contentWidth, height: 1))
        let height = max(previewView.intrinsicContentSize.height, 1)
        previewView.frame = NSRect(x: 20, y: 20, width: contentWidth, height: height)
        documentView.frame = NSRect(x: 0, y: 0, width: width,
                                    height: max(scrollView.contentSize.height, height + 40))
        previewView.layoutSubtreeIfNeeded()
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
}

private final class FlippedPreviewDocumentView: NSView {
    override var isFlipped: Bool { true }
}
#endif
