#if os(macOS)
import AppKit
import ScriblMarkdown

/// The drawn pieces of the shared look that aren't text: checklist boxes, rules, keycaps
/// and disclosure chevrons. The live editor draws them over hidden source; the display
/// renderer draws the same shapes through text attachments.
public enum MarkdownDrawnMarkers {
    /// The checklist box's side for text in `font`.
    public static func checklistBoxSize(for font: NSFont) -> CGFloat {
        max(14, min(17, ceil(font.pointSize * 0.88)))
    }

    /// The width a checklist marker occupies: the box and the gap after it.
    public static func checklistSlotWidth(for font: NSFont) -> CGFloat {
        checklistBoxSize(for: font) + 9
    }

    /// A rounded box, stroked when open and filled with a checkmark when checked.
    public static func drawChecklistBox(in rect: NSRect, isChecked: Bool, palette: MarkdownEditorPalette, flipped: Bool) {
        let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3)
        guard isChecked else {
            palette.tertiaryText.setStroke()
            box.lineWidth = 1.5
            box.stroke()
            return
        }
        palette.accent.setFill()
        box.fill()
        // The check's points, from the top-left in a flipped view.
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + rect.width * x, y: flipped ? rect.minY + rect.height * y : rect.maxY - rect.height * y)
        }
        let check = NSBezierPath()
        check.move(to: point(0.25, 0.5))
        check.line(to: point(0.43, 0.68))
        check.line(to: point(0.76, 0.32))
        check.lineWidth = 1.8
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        palette.onAccent.setStroke()
        check.stroke()
    }

    /// A horizontal rule: a hairline across `rect`, centered vertically.
    public static func drawRule(in rect: NSRect, palette: MarkdownEditorPalette) {
        palette.separator.setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.midY - 0.5, width: rect.width, height: 1), xRadius: 0.5, yRadius: 0.5).fill()
    }

    /// A keycap's size for `text` in the keycap font.
    public static func keycapSize(for text: String, font: NSFont, scale: CGFloat) -> NSSize {
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(textSize.width + 12 * scale), height: ceil(max(22 * scale, textSize.height + 4 * scale)))
    }

    /// A `<kbd>` keycap: a rounded, bordered cap with the label centered.
    public static func drawKeycap(_ text: String, in rect: NSRect, font: NSFont, palette: MarkdownEditorPalette) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        palette.text.withAlphaComponent(0.10).setFill()
        path.fill()
        palette.separator.withAlphaComponent(0.72).setStroke()
        path.lineWidth = 1
        path.stroke()
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: palette.text]
        let textSize = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
            withAttributes: attributes
        )
    }

    /// A `<details>` disclosure chevron centered at `center`: pointing down when expanded.
    public static func drawDisclosureChevron(at center: NSPoint, isExpanded: Bool, color: NSColor, flipped: Bool) {
        let direction: CGFloat = flipped ? 1 : -1
        let chevron = NSBezierPath()
        if isExpanded {
            chevron.move(to: NSPoint(x: center.x - 4, y: center.y - 2 * direction))
            chevron.line(to: NSPoint(x: center.x, y: center.y + 2 * direction))
            chevron.line(to: NSPoint(x: center.x + 4, y: center.y - 2 * direction))
        } else {
            chevron.move(to: NSPoint(x: center.x - 2, y: center.y - 4))
            chevron.line(to: NSPoint(x: center.x + 2, y: center.y))
            chevron.line(to: NSPoint(x: center.x - 2, y: center.y + 4))
        }
        chevron.lineWidth = 1.6
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        color.setStroke()
        chevron.stroke()
    }

    /// The math font: STIX Two Math when installed.
    public static func mathFont(ofSize size: CGFloat) -> NSFont {
        NSFont(name: "STIX Two Math", size: size)
            ?? NSFont(name: "Times New Roman", size: size)
            ?? NSFont.systemFont(ofSize: size)
    }
}
#endif
