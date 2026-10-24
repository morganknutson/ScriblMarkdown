#if os(macOS)
import AppKit
import Foundation
import ScriblMarkdown

/// What a link card shows: a web page preview (or its loading state) or a linked document.
public enum MarkdownLinkCardContent: Equatable {
    case loading(url: URL)
    case web(WebLinkMetadata)
    case document(MarkdownLinkedDocument, isBroken: Bool)

    public var accessibilityLabel: String {
        switch self {
        case .loading(let url): "Loading link preview for \(url.host ?? url.absoluteString)"
        case .web(let metadata):
            [metadata.title, metadata.siteName, metadata.summary]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        case .document(let document, let isBroken):
            isBroken
                ? "Missing note, \(document.title)"
                : "\(document.kindLabel), \(document.title), \(document.preview)"
        }
    }

    public var displaySummary: String? {
        let value: String
        switch self {
        case .loading:
            return nil
        case .web(let metadata):
            value = metadata.summary ?? ""
        case .document(let document, _):
            value = document.preview
        }
        let cleaned = value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The card's height: taller when a web preview has a summary.
    public var preferredHeight: CGFloat {
        switch self {
        case .web where displaySummary != nil:
            return 100
        case .loading, .web, .document:
            return 88
        }
    }
}

/// The card a URL or document link alone on its line becomes: media on the left, an
/// eyebrow, title and summary, and an arrow. Clicking activates it; when the host
/// supplies `dragPasteboardItem`, dragging it starts a drag with that item (the editor uses
/// this to reorder cards).
public final class MarkdownLinkCardView: NSView, NSDraggingSource {
    public static let noteHeight: CGFloat = 88

    public var onActivate: (() -> Void)?
    public var theme: MarkdownTheme {
        didSet { palette = theme.palette }
    }
    /// The pasteboard item a drag carries; nil makes the card click-only.
    public var dragPasteboardItem: (() -> NSPasteboardItem?)?

    private var palette: MarkdownEditorPalette {
        didSet {
            guard palette != oldValue else { return }
            applyPalette()
        }
    }

    private let mediaBackdrop = NSView()
    private let imageView = MarkdownLinkCardMediaView()
    private let eyebrowLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let trailingImage = NSImageView()
    private var mediaWidthConstraint: NSLayoutConstraint!
    private var mediaIconWidthConstraint: NSLayoutConstraint!
    private var mediaIconHeightConstraint: NSLayoutConstraint!
    private var mediaIconConstraints: [NSLayoutConstraint] = []
    private var mediaFillConstraints: [NSLayoutConstraint] = []
    private var trackingAreaReference: NSTrackingArea?
    private var isHovered = false
    private var mouseDownPoint: NSPoint?
    private var didBeginDrag = false
    private var usesThumbnail = false

    public init(theme: MarkdownTheme) {
        self.theme = theme
        palette = theme.palette
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.75
        layer?.masksToBounds = true

        mediaBackdrop.wantsLayer = true
        mediaBackdrop.translatesAutoresizingMaskIntoConstraints = false

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 10
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        imageView.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        imageView.translatesAutoresizingMaskIntoConstraints = false

        eyebrowLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        eyebrowLabel.lineBreakMode = .byTruncatingTail
        eyebrowLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 15.5, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = .systemFont(ofSize: 12.5, weight: .regular)
        summaryLabel.maximumNumberOfLines = 2
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        trailingImage.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        trailingImage.image = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil)
        trailingImage.translatesAutoresizingMaskIntoConstraints = false

        addSubview(mediaBackdrop)
        mediaBackdrop.addSubview(imageView)
        for view in [eyebrowLabel, titleLabel, summaryLabel, trailingImage] {
            addSubview(view)
        }
        mediaIconWidthConstraint = imageView.widthAnchor.constraint(equalToConstant: 44)
        mediaIconHeightConstraint = imageView.heightAnchor.constraint(equalToConstant: 44)
        mediaIconWidthConstraint.identifier = "artifact.media.icon.width"
        mediaIconHeightConstraint.identifier = "artifact.media.icon.height"
        mediaIconConstraints = [
            imageView.centerXAnchor.constraint(equalTo: mediaBackdrop.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: mediaBackdrop.centerYAnchor),
            mediaIconWidthConstraint,
            mediaIconHeightConstraint
        ]
        mediaFillConstraints = [
            imageView.leadingAnchor.constraint(equalTo: mediaBackdrop.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: mediaBackdrop.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: mediaBackdrop.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: mediaBackdrop.bottomAnchor)
        ]
        NSLayoutConstraint.activate(mediaIconConstraints)
        mediaWidthConstraint = mediaBackdrop.widthAnchor.constraint(equalToConstant: 112)
        NSLayoutConstraint.activate([
            mediaBackdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            mediaBackdrop.topAnchor.constraint(equalTo: topAnchor),
            mediaBackdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            mediaWidthConstraint,

            eyebrowLabel.leadingAnchor.constraint(equalTo: mediaBackdrop.trailingAnchor, constant: 16),
            eyebrowLabel.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            eyebrowLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingImage.leadingAnchor, constant: -8),

            titleLabel.leadingAnchor.constraint(equalTo: eyebrowLabel.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: eyebrowLabel.bottomAnchor, constant: 3),
            titleLabel.trailingAnchor.constraint(equalTo: trailingImage.leadingAnchor, constant: -8),

            summaryLabel.leadingAnchor.constraint(equalTo: eyebrowLabel.leadingAnchor),
            summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            summaryLabel.trailingAnchor.constraint(equalTo: trailingImage.leadingAnchor, constant: -8),
            summaryLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),

            trailingImage.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            trailingImage.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingImage.widthAnchor.constraint(equalToConstant: 12),
            trailingImage.heightAnchor.constraint(equalToConstant: 12)
        ])
        applyPalette()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public func configure(_ content: MarkdownLinkCardContent) {
        setAccessibilityLabel(content.accessibilityLabel)
        let summary = content.displaySummary
        summaryLabel.stringValue = summary ?? ""
        summaryLabel.isHidden = summary == nil
        switch content {
        case .loading(let url):
            imageView.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
            imageView.symbolConfiguration = .init(pointSize: 16, weight: .regular)
            imageView.contentTintColor = palette.secondaryText
            configureMedia(width: 96, iconSize: 32, usesThumbnail: false)
            eyebrowLabel.stringValue = url.host ?? "Link"
            titleLabel.stringValue = "Loading preview…"
            trailingImage.image = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil)
        case .web(let metadata):
            let thumbnail = metadata.thumbnailData.flatMap(NSImage.init(data:))
            imageView.image = thumbnail
                ?? NSImage(systemSymbolName: "link", accessibilityDescription: nil)
            imageView.symbolConfiguration = .init(pointSize: 16, weight: .regular)
            imageView.contentTintColor = palette.secondaryText
            configureMedia(
                width: thumbnail == nil ? 96 : 112,
                iconSize: 32,
                usesThumbnail: thumbnail != nil
            )
            eyebrowLabel.stringValue = metadata.siteName.isEmpty
                ? (metadata.url.host ?? "Website")
                : metadata.siteName
            titleLabel.stringValue = metadata.title ?? metadata.url.host ?? metadata.url.absoluteString
            summaryLabel.maximumNumberOfLines = 2
            trailingImage.image = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil)
        case .document(let document, let isBroken):
            imageView.image = isBroken
                ? NSImage(systemSymbolName: "doc.badge.ellipsis", accessibilityDescription: nil)
                : document.image
            imageView.symbolConfiguration = .init(pointSize: 16, weight: .regular)
            imageView.contentTintColor = isBroken ? palette.warning : palette.secondaryText
            configureMedia(width: 96, iconSize: 32, usesThumbnail: false)
            eyebrowLabel.stringValue = isBroken ? "Missing note" : document.kindLabel
            titleLabel.stringValue = document.title
            summaryLabel.maximumNumberOfLines = 1
            trailingImage.image = NSImage(
                systemSymbolName: isBroken ? "exclamationmark.triangle" : "chevron.right",
                accessibilityDescription: nil
            )
        }
    }

    private func configureMedia(
        width: CGFloat,
        iconSize: CGFloat,
        usesThumbnail: Bool
    ) {
        mediaWidthConstraint.constant = width
        mediaIconWidthConstraint.constant = iconSize
        mediaIconHeightConstraint.constant = iconSize
        self.usesThumbnail = usesThumbnail
        imageView.fillsBounds = usesThumbnail
        imageView.layer?.cornerRadius = 0
        NSLayoutConstraint.deactivate(mediaIconConstraints + mediaFillConstraints)
        NSLayoutConstraint.activate(usesThumbnail ? mediaFillConstraints : mediaIconConstraints)
        updateMediaAppearance()
        needsLayout = true
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        return self
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [
                .activeInKeyWindow,
                .mouseEnteredAndExited,
                .mouseMoved,
                .cursorUpdate,
                .inVisibleRect
            ],
            owner: self
        )
        addTrackingArea(tracking)
        trackingAreaReference = tracking
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    public override func mouseEntered(with event: NSEvent) {
        isHovered = true
        activeCursor.set()
        updateAppearance()
    }

    public override func mouseMoved(with event: NSEvent) {
        activeCursor.set()
    }

    public override func cursorUpdate(with event: NSEvent) {
        activeCursor.set()
    }

    public override func mouseExited(with event: NSEvent) {
        isHovered = false
        NSCursor.arrow.set()
        updateAppearance()
    }

    public override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        didBeginDrag = false
    }

    public override func mouseDragged(with event: NSEvent) {
        guard !didBeginDrag,
              let mouseDownPoint,
              hypot(convert(event.locationInWindow, from: nil).x - mouseDownPoint.x,
                    convert(event.locationInWindow, from: nil).y - mouseDownPoint.y) > 4,
              let item = dragPasteboardItem?() else { return }
        didBeginDrag = true
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let image = bitmapImageRepForCachingDisplay(in: bounds).map { representation -> NSImage in
            cacheDisplay(in: bounds, to: representation)
            let image = NSImage(size: bounds.size)
            image.addRepresentation(representation)
            return image
        } ?? NSImage(size: bounds.size)
        draggingItem.setDraggingFrame(bounds, contents: image)
        NSCursor.closedHand.set()
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    public override func mouseUp(with event: NSEvent) {
        if !didBeginDrag { onActivate?() }
        mouseDownPoint = nil
    }

    public override func accessibilityPerformPress() -> Bool {
        onActivate?()
        return true
    }

    public func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation { .move }

    public func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        mouseDownPoint = nil
        didBeginDrag = false
        NSCursor.arrow.set()
    }

    private func applyPalette() {
        eyebrowLabel.textColor = palette.secondaryText
        titleLabel.textColor = palette.text
        summaryLabel.textColor = palette.secondaryText
        trailingImage.contentTintColor = palette.tertiaryText
        updateAppearance()
    }

    private func updateAppearance() {
        layer?.backgroundColor = palette.text
            .withAlphaComponent(isHovered ? 0.11 : 0.075).cgColor
        layer?.borderColor = palette.text
            .withAlphaComponent(isHovered ? 0.24 : 0.14).cgColor
        updateMediaAppearance()
    }

    private func updateMediaAppearance() {
        mediaBackdrop.layer?.backgroundColor = usesThumbnail
            ? NSColor.clear.cgColor
            : palette.text.withAlphaComponent(isHovered ? 0.09 : 0.065).cgColor
        imageView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    private var activeCursor: NSCursor {
        didBeginDrag ? .closedHand : .pointingHand
    }
}

private final class MarkdownLinkCardMediaView: NSImageView {
    var fillsBounds = false {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard fillsBounds,
              let image,
              image.size.width > 0,
              image.size.height > 0,
              bounds.width > 0,
              bounds.height > 0 else {
            super.draw(dirtyRect)
            return
        }

        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let destinationSize = NSSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        let destination = NSRect(
            x: (bounds.width - destinationSize.width) / 2,
            y: (bounds.height - destinationSize.height) / 2,
            width: destinationSize.width,
            height: destinationSize.height
        )

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        image.draw(
            in: destination,
            from: NSRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        NSGraphicsContext.restoreGraphicsState()
    }
}
#endif
