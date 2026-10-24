#if os(macOS)
import AppKit
import ScriblMarkdownUI

/// Inline drawings in rendered text, drawn with the same shapes the live editor draws:
/// checklist boxes, keycaps and disclosure chevrons.
final class MarkdownMarkerAttachmentCell: NSTextAttachmentCell {
    enum Marker {
        case checklist(isChecked: Bool)
        case keycap(String, font: NSFont)
        case disclosure(isExpanded: Bool)
    }

    private let marker: Marker
    private let palette: MarkdownEditorPalette
    /// The surrounding text's font, which the marker sits on.
    private let textFont: NSFont
    private let size: NSSize

    init(marker: Marker, palette: MarkdownEditorPalette, textFont: NSFont, scale: CGFloat) {
        self.marker = marker
        self.palette = palette
        self.textFont = textFont
        switch marker {
        case .checklist:
            let side = MarkdownDrawnMarkers.checklistBoxSize(for: textFont)
            size = NSSize(width: MarkdownDrawnMarkers.checklistSlotWidth(for: textFont), height: side)
        case .keycap(let text, let font):
            size = MarkdownDrawnMarkers.keycapSize(for: text, font: font, scale: scale)
        case .disclosure:
            size = NSSize(width: 16, height: 12)
        }
        super.init(textCell: "")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A one-character string holding this marker.
    static func string(
        _ marker: Marker,
        palette: MarkdownEditorPalette,
        textFont: NSFont,
        scale: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) -> NSMutableAttributedString {
        let attachment = NSTextAttachment()
        attachment.attachmentCell = MarkdownMarkerAttachmentCell(marker: marker, palette: palette, textFont: textFont, scale: scale)
        let string = NSMutableAttributedString(attachment: attachment)
        string.addAttributes(attributes, range: NSRange(location: 0, length: string.length))
        return string
    }

    override func cellSize() -> NSSize {
        size
    }

    /// Centers the marker on the text's capital letters, as the editor does.
    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: textFont.capHeight / 2 - size.height / 2)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let flipped = controlView?.isFlipped ?? NSGraphicsContext.current?.isFlipped ?? false
        switch marker {
        case .checklist(let isChecked):
            let side = MarkdownDrawnMarkers.checklistBoxSize(for: textFont)
            let box = NSRect(x: cellFrame.minX, y: cellFrame.midY - side / 2, width: side, height: side)
            MarkdownDrawnMarkers.drawChecklistBox(in: box, isChecked: isChecked, palette: palette, flipped: flipped)
        case .keycap(let text, let font):
            MarkdownDrawnMarkers.drawKeycap(text, in: cellFrame, font: font, palette: palette)
        case .disclosure(let isExpanded):
            MarkdownDrawnMarkers.drawDisclosureChevron(
                at: NSPoint(x: cellFrame.minX + 6, y: cellFrame.midY),
                isExpanded: isExpanded,
                color: palette.secondaryText,
                flipped: flipped
            )
        }
    }
}
#endif
