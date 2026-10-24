import AppKit
import ScriblMarkdown

/// A scrolling live Markdown editor: a `MarkdownEditorTextView` driven by a
/// `MarkdownEditorController`. Embed it directly in AppKit, or wrap it for SwiftUI.
public final class MarkdownEditorView: NSScrollView {
    public let controller: MarkdownEditorController
    let markdownTextView: MarkdownEditorTextView
    private var resetsToTopBeforeNextDraw = false

    public var textView: NSTextView { markdownTextView }

    /// The Markdown source. Setting it replaces the document and restyles it; the
    /// controller's `onTextChange` is only called for user edits.
    public var text: String {
        get { markdownTextView.string }
        set {
            guard markdownTextView.string != newValue else { return }
            markdownTextView.string = newValue
            controller.applyPresentation(to: markdownTextView)
        }
    }

    public var presentation: MarkdownEditorController.Presentation {
        get { controller.presentation }
        set {
            guard controller.presentation != newValue else { return }
            controller.presentation = newValue
            controller.applyPresentation(to: markdownTextView)
            controller.refreshPresentationLayout(in: markdownTextView)
        }
    }

    /// Setting a style restyles the whole document, so set it only when something changed.
    public var style: MarkdownEditorStyle {
        get { controller.style }
        set {
            controller.style = newValue
            markdownTextView.textContainerInset = newValue.textContainerInset
            controller.applyPresentation(to: markdownTextView)
            controller.refreshPresentationLayout(in: markdownTextView)
        }
    }

    public init(controller: MarkdownEditorController = MarkdownEditorController(), text: String = "") {
        self.controller = controller
        self.markdownTextView = MarkdownEditorTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        automaticallyAdjustsContentInsets = false

        markdownTextView.isRichText = false
        markdownTextView.allowsUndo = true
        markdownTextView.isAutomaticQuoteSubstitutionEnabled = false
        markdownTextView.isAutomaticDashSubstitutionEnabled = false
        markdownTextView.drawsBackground = false
        markdownTextView.textContainerInset = controller.style.textContainerInset
        markdownTextView.textContainer?.lineFragmentPadding = 0
        markdownTextView.textContainer?.widthTracksTextView = true
        markdownTextView.isVerticallyResizable = true
        markdownTextView.isHorizontallyResizable = false
        markdownTextView.autoresizingMask = [.width]
        markdownTextView.string = text
        controller.attach(to: markdownTextView)
        controller.applyPresentation(to: markdownTextView)

        documentView = markdownTextView
        prepareForInitialDisplay()
    }

    required init?(coder: NSCoder) { nil }

    /// The formatting at the caret.
    public var formatting: MarkdownEditorFormatting {
        controller.formatting(in: markdownTextView)
    }

    public func perform(_ action: MarkdownEditorCommand.Action) {
        controller.apply(action, to: markdownTextView)
    }

    /// Focuses the editor once per `requestID`, placing the caret in an empty title.
    public func handleFocusRequest(_ requestID: UUID?) {
        controller.handleFocusRequest(requestID, in: markdownTextView)
    }

    /// Restyles with the current style, such as after the host's theme resolved new colors.
    public func refreshStyle() {
        controller.applyPresentation(to: markdownTextView)
        controller.refreshPresentationLayout(in: markdownTextView)
    }

    /// Scrolls to the top on the first draw that has a real height.
    public func prepareForInitialDisplay() {
        resetsToTopBeforeNextDraw = true
    }

    public override func viewWillDraw() {
        super.viewWillDraw()
        guard resetsToTopBeforeNextDraw, contentView.bounds.height > 0 else { return }
        resetsToTopBeforeNextDraw = false
        scrollToTop()
    }

    public func scrollToTop() {
        let clipView = contentView
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: 0))
        reflectScrolledClipView(clipView)
    }
}
