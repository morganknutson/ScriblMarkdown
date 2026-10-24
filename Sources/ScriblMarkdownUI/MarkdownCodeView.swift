#if os(macOS)
import AppKit

/// Syntax-colored, selectable code with a sticky line-number gutter. Long lines scroll
/// sideways; vertical scrolling passes to whatever the view sits in. The view reports its
/// full height as its intrinsic size.
final class MarkdownCodeView: NSView {
    static let contentPadding = MarkdownCodeBlockLayout.gutterPadding

    private let scrollView = MarkdownHorizontalScrollView()
    private let textStorage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let textContainer = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
    private let textView: NSTextView
    private let gutterView = MarkdownLineNumberGutterView()

    private var code = ""
    private var language: String?
    private var theme: MarkdownTheme?

    override init(frame frameRect: NSRect) {
        textContainer.widthTracksTextView = false
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        textView = NSTextView(frame: .zero, textContainer: textContainer)
        super.init(frame: frameRect)

        translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 0, height: Self.contentPadding)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        gutterView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gutterView)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            gutterView.topAnchor.constraint(equalTo: topAnchor),
            gutterView.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutterView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: gutterView.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(code: String, language: String?, theme: MarkdownTheme) {
        self.code = code
        self.language = language
        self.theme = theme
        render()
    }

    private func render() {
        guard let theme else { return }
        let font = theme.surface.codeFont
        let highlighter = MarkdownSyntaxHighlighter(colors: theme.syntax)
        textStorage.setAttributedString(highlighter.highlight(code, language: language, font: font))
        let lineCount = max(1, code.components(separatedBy: "\n").count)
        gutterView.configure(lineCount: lineCount, font: font, color: theme.surface.gutterText, padding: Self.contentPadding)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        layoutManager.ensureLayout(for: textContainer)
        let height = layoutManager.usedRect(for: textContainer).height
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(height) + Self.contentPadding * 2)
    }

    override func layout() {
        super.layout()
        textView.minSize = NSSize(width: scrollView.contentSize.width, height: 0)
        layoutManager.ensureLayout(for: textContainer)
        gutterView.syncLinePositions(with: layoutManager, textInset: textView.textContainerInset.height)
        invalidateIntrinsicContentSize()
    }
}

/// Right-aligned line numbers drawn level with the code's lines. It sits outside the
/// horizontal scroller, so it stays put while long lines scroll.
private final class MarkdownLineNumberGutterView: NSView {
    private var lineCount = 0
    private var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var color = NSColor.secondaryLabelColor
    private var padding: CGFloat = 14
    private var lineOrigins: [CGFloat] = []
    private var widthConstraint: NSLayoutConstraint!

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        widthConstraint = widthAnchor.constraint(equalToConstant: 0)
        widthConstraint.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(lineCount: Int, font: NSFont, color: NSColor, padding: CGFloat) {
        self.lineCount = lineCount
        self.font = font
        self.color = color
        self.padding = padding
        widthConstraint.constant = MarkdownCodeBlockLayout.gutterWidth(lineCount: lineCount, font: font)
        needsDisplay = true
    }

    private var numberWidth: CGFloat {
        (String(repeating: "0", count: String(max(lineCount, 1)).count) as NSString)
            .size(withAttributes: [.font: font]).width
    }

    /// Reads each source line's first line fragment, so wrapped or tall lines number at
    /// their top.
    func syncLinePositions(with layoutManager: NSLayoutManager, textInset: CGFloat) {
        lineOrigins.removeAll(keepingCapacity: true)
        guard let text = layoutManager.textStorage?.string as NSString?, text.length > 0 else {
            needsDisplay = true
            return
        }
        var location = 0
        while location < text.length, lineOrigins.count < lineCount {
            let glyph = layoutManager.glyphIndexForCharacter(at: location)
            lineOrigins.append(layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + textInset)
            let next = text.range(of: "\n", options: .literal, range: NSRange(location: location, length: text.length - location))
            guard next.location != NSNotFound else { break }
            location = NSMaxRange(next)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let width = numberWidth
        for (index, y) in lineOrigins.enumerated() {
            let number = "\(index + 1)" as NSString
            let size = number.size(withAttributes: attributes)
            number.draw(at: NSPoint(x: padding + width - size.width, y: y), withAttributes: attributes)
        }
    }
}

/// A scroller that scrolls sideways and hands vertical scrolling to the view it sits in.
///
/// A trackpad swipe is one gesture (began, changed…, ended) followed by momentum events.
/// Each gesture is locked to the axis it starts on and every event of it, momentum
/// included, goes to the same scroller, so a sideways swipe keeps its inertia and a slightly
/// diagonal one isn't split between the two. Events before the axis is known (a gesture's
/// zero-delta start) go to both, so whichever scroller wins has seen the gesture begin.
/// A mouse wheel has no gestures, so each of its events goes by its own dominant axis
/// (Shift turns the wheel sideways).
final class MarkdownHorizontalScrollView: NSScrollView {
    private enum Axis {
        case horizontal
        case vertical

        init(_ event: NSEvent) {
            self = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? .horizontal : .vertical
        }
    }

    /// The axis the current trackpad gesture (and its momentum) is locked to.
    private var gestureAxis: Axis?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .allowed
        usesPredominantAxisScrolling = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func scrollWheel(with event: NSEvent) {
        let isGesture = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        guard isGesture else {
            route(event, to: Axis(event))
            return
        }
        if event.phase.contains(.mayBegin) || event.phase.contains(.began) {
            gestureAxis = nil
        }
        if gestureAxis == nil, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
            gestureAxis = Axis(event)
        }
        if let gestureAxis {
            route(event, to: gestureAxis)
            // Both scrollers saw the gesture begin, so both should see it end.
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                route(event, to: gestureAxis == .horizontal ? .vertical : .horizontal)
            }
        } else {
            super.scrollWheel(with: event)
            nextResponder?.scrollWheel(with: event)
        }
        if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
            gestureAxis = nil
        }
    }

    private func route(_ event: NSEvent, to axis: Axis) {
        switch axis {
        case .horizontal: super.scrollWheel(with: event)
        case .vertical: nextResponder?.scrollWheel(with: event)
        }
    }
}
#endif
