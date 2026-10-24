import AppKit
import Foundation
import ScriblMarkdown
import UniformTypeIdentifiers

struct PasteboardImagePayload: Equatable {
    let data: Data
    let preferredFileName: String
    let mimeType: String

    static func read(from pasteboard: NSPasteboard) -> Self? {
        let formats: [(NSPasteboard.PasteboardType, String, String)] = [
            (.init("public.png"), "Pasted Image.png", "image/png"),
            (.init("public.jpeg"), "Pasted Image.jpg", "image/jpeg"),
            (.init("public.heic"), "Pasted Image.heic", "image/heic"),
            (.init("com.compuserve.gif"), "Pasted Image.gif", "image/gif"),
            (.init("org.webmproject.webp"), "Pasted Image.webp", "image/webp"),
            (.tiff, "Pasted Image.tiff", "image/tiff")
        ]
        for (type, fileName, mimeType) in formats {
            if let data = pasteboard.data(forType: type), !data.isEmpty {
                return .init(data: data, preferredFileName: fileName, mimeType: mimeType)
            }
        }

        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let data = representation.representation(using: .png, properties: [:]) else {
            return nil
        }
        return .init(data: data, preferredFileName: "Pasted Image.png", mimeType: "image/png")
    }
}

extension MarkdownImageReorderPayload {
    static let pasteboardType = NSPasteboard.PasteboardType("ing.scribl.image-reorder")
}

extension MarkdownImageAssetStore {
    func importImage(_ image: NSImage, for noteURL: URL) throws -> String {
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let data = representation.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let destination = try importImageData(
            data,
            preferredName: "Pasted Image.png",
            for: noteURL
        )
        return markdown(destination: destination, alternateText: "Pasted Image")
    }

    func importPastedImage(_ payload: PasteboardImagePayload, for noteURL: URL) throws -> String {
        let destination = try importImageData(
            payload.data,
            preferredName: payload.preferredFileName,
            for: noteURL
        )
        return markdown(destination: destination, alternateText: "Pasted Image")
    }
}

final class MarkdownEditorTextView: NSTextView {
    struct TitlePlaceholder {
        let text: String
        let font: NSFont
        let color: NSColor
    }

    struct RenderedImage {
        let range: NSRange
        let url: URL
        let image: NSImage
        let size: NSSize
    }

    struct RenderedArtifact {
        let artifact: MarkdownArtifact
        let content: ArtifactCardContent
        let height: CGFloat
    }

    struct RenderedChecklist {
        let markerRange: NSRange
        let stateRange: NSRange
        let isChecked: Bool
        let font: NSFont
        let controlSize: CGFloat
        let controlSlotWidth: CGFloat
    }

    struct RenderedOrderedList {
        let markerRange: NSRange
        let label: String
        let font: NSFont
        let markerSlotWidth: CGFloat
        let trailingGap: CGFloat
    }

    struct RenderedCodeBlock {
        let sourceRange: NSRange
        let contentRange: NSRange
    }

    struct RenderedHorizontalRule {
        let sourceRange: NSRange
    }

    struct RenderedMath {
        let sourceRange: NSRange
        let displayText: String
        let font: NSFont
        let size: NSSize
        let isBlock: Bool
    }

    struct RenderedInlineReplacement {
        let sourceRange: NSRange
        let displayText: String
        let font: NSFont
        let size: NSSize
        let baselineOffset: CGFloat
        let color: NSColor
    }

    struct RenderedKeycap {
        let sourceRange: NSRange
        let displayText: String
        let font: NSFont
        let size: NSSize
    }

    struct RenderedFootnoteReference {
        let sourceRange: NSRange
        let displayText: String
        let font: NSFont
        let size: NSSize
    }

    struct RenderedFootnoteDefinition {
        let prefixRange: NSRange
        let displayText: String
        let font: NSFont
        let slotWidth: CGFloat
        let isFirst: Bool
    }

    struct RenderedDetails {
        let openingTagRange: NSRange
        let summaryContentRange: NSRange
        let markerRanges: [NSRange]
        let bodyRange: NSRange
        let isExpanded: Bool
    }

    struct RenderedBlockQuoteLine {
        let lineRange: NSRange
        let markerRange: NSRange
        let depth: Int
    }

    var renderedImages: [RenderedImage] = [] {
        didSet {
            if let mouseDownImage,
               !renderedImages.contains(where: { $0.range == mouseDownImage.range }) {
                self.mouseDownImage = nil
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.invalidateCursorRects(for: self)
            }
            needsDisplay = true
        }
    }
    var renderedArtifacts: [RenderedArtifact] = [] {
        didSet {
            synchronizeArtifactViews()
            needsLayout = true
        }
    }
    var renderedChecklists: [RenderedChecklist] = [] {
        didSet {
            if let mouseDownChecklist,
               !renderedChecklists.contains(where: { $0.stateRange == mouseDownChecklist.stateRange }) {
                self.mouseDownChecklist = nil
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.invalidateCursorRects(for: self)
            }
            needsDisplay = true
        }
    }
    var renderedOrderedLists: [RenderedOrderedList] = [] {
        didSet { needsDisplay = true }
    }
    var renderedCodeBlocks: [RenderedCodeBlock] = [] {
        didSet { needsDisplay = true }
    }
    var renderedHorizontalRules: [RenderedHorizontalRule] = [] {
        didSet { needsDisplay = true }
    }
    var renderedMath: [RenderedMath] = [] {
        didSet { needsDisplay = true }
    }
    var renderedInlineReplacements: [RenderedInlineReplacement] = [] {
        didSet { needsDisplay = true }
    }
    var renderedKeycaps: [RenderedKeycap] = [] {
        didSet { needsDisplay = true }
    }
    var renderedFootnoteReferences: [RenderedFootnoteReference] = [] {
        didSet { needsDisplay = true }
    }
    var renderedFootnoteDefinitions: [RenderedFootnoteDefinition] = [] {
        didSet { needsDisplay = true }
    }
    var renderedDetails: [RenderedDetails] = [] {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.invalidateCursorRects(for: self)
            }
            needsDisplay = true
        }
    }
    var renderedInlineMarkerRanges: [NSRange] = []
    var renderedBlockQuoteLines: [RenderedBlockQuoteLine] = [] {
        didSet { needsDisplay = true }
    }
    var renderedLinkMarkerRanges: [NSRange] = []
    var titlePlaceholder: TitlePlaceholder? {
        didSet { needsDisplay = true }
    }
    var palette: MarkdownEditorPalette = .system {
        didSet {
            guard palette != oldValue else { return }
            artifactViews.values.forEach { $0.palette = palette }
            needsDisplay = true
        }
    }
    var recordEditorEvent: ((String, [String: String]) -> Void)?
    /// Lowercased extensions of files that drop in as linked-document cards.
    var linkableDocumentExtensions: Set<String> = ["md", "markdown"]
    var importImages: (([URL], PasteboardImagePayload?, NSRange) -> Bool)?
    var insertWebURLs: (([URL], NSRange) -> Bool)?
    var insertNotePayload: ((MarkdownDocumentDragPayload, NSRange) -> Bool)?
    var reorderImage: ((MarkdownImageReorderPayload, Int) -> Bool)?
    var reorderArtifact: ((ArtifactReorderDragPayload, Int) -> Bool)?
    var toggleChecklist: ((NSRange, Bool) -> Void)?
    var toggleDetails: ((NSRange, Bool) -> Void)?
    var activateArtifact: ((MarkdownArtifact) -> Void)?
    var widthDidChange: (() -> Void)?
    private var reportedWidth: CGFloat = 0
    private var artifactViews: [String: ArtifactCardView] = [:]
    private var artifactInsertionY: CGFloat?
    private var imageInsertionRect: NSRect?
    private var pasteEventMonitor: Any?
    private var imageCursorTrackingArea: NSTrackingArea?
    private var mouseDownImage: RenderedImage?
    private var mouseDownChecklist: RenderedChecklist?
    private var mouseDownDetails: RenderedDetails?
    private var mouseDownPoint: NSPoint?
    private var didBeginImageDrag = false
    private var isNormalizingImageSelection = false
    private var pendingTextEditSelection: NSRange?
    private var previousSelection = NSRange(location: 0, length: 0)

    deinit {
        if let pasteEventMonitor {
            NSEvent.removeMonitor(pasteEventMonitor)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([
            .fileURL,
            .URL,
            .string,
            .tiff,
            NSPasteboard.PasteboardType("public.png"),
            MarkdownDocumentDragPayload.pasteboardType,
            MarkdownImageReorderPayload.pasteboardType,
            ArtifactReorderDragPayload.pasteboardType
        ])
        updatePasteEventMonitor()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let imageCursorTrackingArea {
            removeTrackingArea(imageCursorTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .cursorUpdate, .mouseMoved],
            owner: self
        )
        addTrackingArea(trackingArea)
        imageCursorTrackingArea = trackingArea
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let cursor = renderedObjectCursor(at: point) {
            cursor.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let cursor = renderedObjectCursor(at: point) {
            cursor.set()
        } else {
            NSCursor.iBeam.set()
            super.mouseMoved(with: event)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard abs(newSize.width - reportedWidth) > 1 else { return }
        reportedWidth = newSize.width
        DispatchQueue.main.async { [weak self] in
            self?.widthDidChange?()
        }
    }

    override func layout() {
        super.layout()
        layoutArtifactViews()
    }

    override func drawInsertionPoint(
        in rect: NSRect,
        color: NSColor,
        turnedOn flag: Bool
    ) {
        super.drawInsertionPoint(
            in: insertionPointRect(for: rect),
            color: color,
            turnedOn: flag
        )
    }

    func insertionPointRect(for proposedRect: NSRect) -> NSRect {
        let selection = selectedRange()
        guard let titlePlaceholder,
              string.hasPrefix("# "),
              selection == NSRange(location: 2, length: 0) else {
            return proposedRect
        }

        var rect = proposedRect
        rect.size.width = max(rect.width, 2)
        rect.size.height = ceil(
            titlePlaceholder.font.ascender
                - titlePlaceholder.font.descender
                + titlePlaceholder.font.leading
        )
        return rect
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        recordImagePasteEvent("Markdown paste action received", pasteboard: pasteboard)
        if pasteImage(from: pasteboard) {
            return
        }
        if let payload = notePayload(from: pasteboard),
           insertNotePayload?(payload, selectedRange()) == true {
            return
        }
        let webURLs = publicWebURLs(from: pasteboard)
        if !webURLs.isEmpty,
           currentLineIsEmpty(at: selectedRange()),
           insertWebURLs?(webURLs, selectedRange()) == true {
            return
        }
        super.paste(sender)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for rendered in renderedImages {
            guard let rect = imageRect(for: rendered) else { continue }
            addCursorRect(rect, cursor: .pointingHand)
        }
        for rendered in renderedChecklists {
            guard let rect = checklistRect(for: rendered) else { continue }
            addCursorRect(rect, cursor: .pointingHand)
        }
        for rendered in renderedDetails {
            guard let rect = detailsSummaryRect(for: rendered) else { continue }
            addCursorRect(rect, cursor: .pointingHand)
        }
        for view in artifactViews.values where !view.isHidden {
            addCursorRect(view.frame, cursor: .pointingHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let rendered = renderedDetails(at: point) {
            mouseDownImage = nil
            mouseDownChecklist = nil
            mouseDownDetails = rendered
            mouseDownPoint = nil
            didBeginImageDrag = false
            window?.makeFirstResponder(self)
            return
        }
        mouseDownDetails = nil
        if let rendered = renderedChecklist(at: point) {
            mouseDownImage = nil
            mouseDownChecklist = rendered
            mouseDownPoint = nil
            didBeginImageDrag = false
            window?.makeFirstResponder(self)
            return
        }
        mouseDownChecklist = nil
        guard let rendered = renderedImage(at: point) else {
            mouseDownImage = nil
            mouseDownPoint = nil
            didBeginImageDrag = false
            super.mouseDown(with: event)
            return
        }

        window?.makeFirstResponder(self)
        setSelectedRange(rendered.range)
        mouseDownImage = rendered
        mouseDownPoint = point
        didBeginImageDrag = false
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if mouseDownChecklist != nil || mouseDownDetails != nil { return }
        guard !didBeginImageDrag,
              let rendered = mouseDownImage,
              let mouseDownPoint,
              hypot(
                  convert(event.locationInWindow, from: nil).x - mouseDownPoint.x,
                  convert(event.locationInWindow, from: nil).y - mouseDownPoint.y
              ) > 4,
              NSMaxRange(rendered.range) <= (string as NSString).length else {
            if mouseDownImage == nil { super.mouseDragged(with: event) }
            return
        }

        let source = (string as NSString).substring(with: rendered.range)
        let payload = MarkdownImageReorderPayload(
            referenceLocation: rendered.range.location,
            referenceLength: rendered.range.length,
            source: source
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        didBeginImageDrag = true

        let item = NSPasteboardItem()
        item.setData(data, forType: MarkdownImageReorderPayload.pasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let sourceRect = imageRect(for: rendered) ?? NSRect(origin: mouseDownPoint, size: rendered.size)
        let scale = min(1, 180 / max(sourceRect.width, sourceRect.height))
        let draggingSize = NSSize(width: sourceRect.width * scale, height: sourceRect.height * scale)
        let draggingFrame = NSRect(
            x: mouseDownPoint.x - draggingSize.width / 2,
            y: mouseDownPoint.y - draggingSize.height / 2,
            width: draggingSize.width,
            height: draggingSize.height
        )
        draggingItem.setDraggingFrame(draggingFrame, contents: rendered.image)
        NSCursor.closedHand.set()
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if let rendered = mouseDownDetails {
            let point = convert(event.locationInWindow, from: nil)
            if renderedDetails(at: point)?.openingTagRange == rendered.openingTagRange {
                toggleDetails?(rendered.openingTagRange, !rendered.isExpanded)
            }
        } else if let rendered = mouseDownChecklist {
            let point = convert(event.locationInWindow, from: nil)
            if renderedChecklist(at: point)?.stateRange == rendered.stateRange {
                toggleChecklist?(rendered.stateRange, !rendered.isChecked)
            }
        } else if let rendered = mouseDownImage, !didBeginImageDrag, let window {
            ImagePreviewWindowController.shared.present(
                image: rendered.image,
                fileURL: rendered.url,
                from: window
            )
        } else if mouseDownImage == nil {
            super.mouseUp(with: event)
        }
        mouseDownDetails = nil
        mouseDownChecklist = nil
        mouseDownImage = nil
        mouseDownPoint = nil
        didBeginImageDrag = false
    }

    override func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation { .move }

    override func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        mouseDownImage = nil
        mouseDownPoint = nil
        didBeginImageDrag = false
        NSCursor.arrow.set()
    }

    @discardableResult
    func normalizeRenderedObjectSelection() -> Bool {
        guard !isNormalizingImageSelection else { return false }
        let selection = selectedRange()
        if selection == pendingTextEditSelection {
            previousSelection = selection
            needsDisplay = true
            return false
        }
        let ranges = renderedObjectRanges
        var normalized = selection

        if selection.length > 0 {
            normalized = MarkdownImageEditing.expandedSelection(selection, imageRanges: ranges)
        } else if let range = renderedNavigationRanges.first(where: {
            selection.location > $0.location && selection.location < NSMaxRange($0)
        }) {
            normalized = NSRange(
                location: selection.location >= previousSelection.location
                    ? NSMaxRange(range)
                    : range.location,
                length: 0
            )
        }

        previousSelection = normalized
        guard normalized != selection else {
            needsDisplay = true
            return false
        }
        isNormalizingImageSelection = true
        setSelectedRange(normalized)
        isNormalizingImageSelection = false
        needsDisplay = true
        return true
    }

    func prepareForTextChange(in range: NSRange, replacement: String) {
        pendingTextEditSelection = NSRange(
            location: range.location + (replacement as NSString).length,
            length: 0
        )
    }

    func finishTextChange() {
        previousSelection = selectedRange()
        pendingTextEditSelection = nil
    }

    @discardableResult
    func moveAcrossRenderedObject(forward: Bool) -> Bool {
        guard let destination = MarkdownImageEditing.movementDestination(
            for: selectedRange(),
            forward: forward,
            imageRanges: renderedObjectRanges
        ) else { return false }
        setSelectedRange(NSRange(location: destination, length: 0))
        previousSelection = selectedRange()
        needsDisplay = true
        return true
    }

    @discardableResult
    func deleteRenderedObject(forward: Bool) -> Bool {
        let selection = selectedRange()
        let ranges = renderedObjectRanges
        let deletion: NSRange?
        if selection.length > 0,
           ranges.contains(where: { NSIntersectionRange(selection, $0).length > 0 }) {
            deletion = MarkdownImageEditing.expandedSelection(selection, imageRanges: ranges)
        } else {
            deletion = MarkdownImageEditing.deletionRange(
                for: selection,
                forward: forward,
                imageRanges: ranges
            )
        }
        guard let deletion else { return false }
        insertText("", replacementRange: deletion)
        setSelectedRange(NSRange(location: deletion.location, length: 0))
        previousSelection = selectedRange()
        return true
    }

    private var renderedObjectRanges: [NSRange] {
        (renderedImages.map(\.range) + renderedArtifacts.map(\.artifact.sourceRange))
            .sorted { $0.location < $1.location }
    }

    private var renderedNavigationRanges: [NSRange] {
        var ranges = renderedObjectRanges
        ranges.append(contentsOf: renderedChecklists.map(\.markerRange))
        ranges.append(contentsOf: renderedOrderedLists.map(\.markerRange))
        ranges.append(contentsOf: renderedMath.map(\.sourceRange))
        ranges.append(contentsOf: renderedBlockQuoteLines.map(\.markerRange))
        ranges.append(contentsOf: renderedInlineReplacements.map(\.sourceRange))
        ranges.append(contentsOf: renderedKeycaps.map(\.sourceRange))
        ranges.append(contentsOf: renderedFootnoteReferences.map(\.sourceRange))
        ranges.append(contentsOf: renderedFootnoteDefinitions.map(\.prefixRange))
        for details in renderedDetails {
            ranges.append(contentsOf: details.markerRanges)
            if !details.isExpanded {
                ranges.append(details.bodyRange)
            }
        }
        ranges.append(contentsOf: renderedInlineMarkerRanges)
        ranges.append(contentsOf: renderedLinkMarkerRanges)
        return ranges.sorted { $0.location < $1.location }
    }

    @discardableResult
    func pasteImage(from pasteboard: NSPasteboard) -> Bool {
        let urls = imageFileURLs(from: pasteboard)
        let image = urls.isEmpty ? PasteboardImagePayload.read(from: pasteboard) : nil
        guard !urls.isEmpty || image != nil else { return false }
        let handled = importImages?(urls, image, selectedRange()) == true
        recordImagePasteEvent(
            handled ? "Markdown image paste handled" : "Markdown image paste rejected",
            pasteboard: pasteboard
        )
        return handled
    }

    private func updatePasteEventMonitor() {
        if let pasteEventMonitor {
            NSEvent.removeMonitor(pasteEventMonitor)
            self.pasteEventMonitor = nil
        }
        guard window != nil else { return }
        pasteEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.window === self.window,
                  self.containsFirstResponder,
                  Self.isCommandV(event) else { return event }
            let pasteboard = NSPasteboard.general
            self.recordImagePasteEvent("Markdown Command-V received", pasteboard: pasteboard)
            return self.pasteImage(from: pasteboard) ? nil : event
        }
    }

    private var containsFirstResponder: Bool {
        guard var view = window?.firstResponder as? NSView else { return false }
        while true {
            if view === self { return true }
            guard let parent = view.superview else { return false }
            view = parent
        }
    }

    private static func isCommandV(_ event: NSEvent) -> Bool {
        let relevant = event.modifierFlags.intersection([.command, .option, .control, .shift])
        return relevant == .command && event.charactersIgnoringModifiers?.lowercased() == "v"
    }

    private func recordImagePasteEvent(_ message: String, pasteboard: NSPasteboard) {
        recordEditorEvent?(
            message,
            ["pasteboardTypes": pasteboard.types?.map(\.rawValue).joined(separator: ",") ?? ""]
        )
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pasteboard = sender.draggingPasteboard
        if pasteboard.data(forType: MarkdownImageReorderPayload.pasteboardType) != nil { return .move }
        if pasteboard.data(forType: ArtifactReorderDragPayload.pasteboardType) != nil { return .move }
        if notePayload(from: pasteboard) != nil { return .copy }
        if !imageFileURLs(from: pasteboard).isEmpty || !publicWebURLs(from: pasteboard).isEmpty { return .copy }
        return super.draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if acceptsEditorReorderDrop(from: sender.draggingPasteboard) {
            return true
        }
        return super.prepareForDragOperation(sender)
    }

    func acceptsEditorReorderDrop(from pasteboard: NSPasteboard) -> Bool {
        pasteboard.data(forType: MarkdownImageReorderPayload.pasteboardType) != nil
            || pasteboard.data(forType: ArtifactReorderDragPayload.pasteboardType) != nil
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pasteboard = sender.draggingPasteboard
        let point = convert(sender.draggingLocation, from: nil)
        if pasteboard.data(forType: MarkdownImageReorderPayload.pasteboardType) != nil {
            let range = insertionRange(at: point)
            imageInsertionRect = insertionIndicatorRect(at: range.location)
            artifactInsertionY = nil
            autoscrollNearEdge(point)
            needsDisplay = true
            return .move
        }
        if pasteboard.data(forType: ArtifactReorderDragPayload.pasteboardType) != nil {
            let location = insertionRange(at: point).location
            artifactInsertionY = insertionY(at: location)
            autoscrollNearEdge(point)
            needsDisplay = true
            return .move
        }
        if notePayload(from: pasteboard) != nil || !publicWebURLs(from: pasteboard).isEmpty {
            let location = artifactDropLocation(at: point)
            artifactInsertionY = insertionY(at: location)
            imageInsertionRect = nil
            autoscrollNearEdge(point)
            needsDisplay = true
            return .copy
        }
        if !imageFileURLs(from: pasteboard).isEmpty {
            let range = insertionRange(at: point)
            imageInsertionRect = insertionIndicatorRect(at: range.location)
            artifactInsertionY = nil
            autoscrollNearEdge(point)
            needsDisplay = true
            return .copy
        }
        return draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        artifactInsertionY = nil
        imageInsertionRect = nil
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer {
            artifactInsertionY = nil
            imageInsertionRect = nil
            needsDisplay = true
        }
        let pasteboard = sender.draggingPasteboard
        let point = convert(sender.draggingLocation, from: nil)
        let range = insertionRange(at: point)
        if let data = pasteboard.data(forType: MarkdownImageReorderPayload.pasteboardType),
           let payload = try? JSONDecoder().decode(MarkdownImageReorderPayload.self, from: data) {
            return reorderImage?(payload, range.location) == true
        }
        if let data = pasteboard.data(forType: ArtifactReorderDragPayload.pasteboardType),
           let payload = try? JSONDecoder().decode(ArtifactReorderDragPayload.self, from: data) {
            return reorderArtifact?(payload, blockBoundary(at: range.location)) == true
        }
        if let payload = notePayload(from: pasteboard) {
            let location = artifactDropLocation(at: point)
            return insertNotePayload?(payload, NSRange(location: location, length: 0)) == true
        }
        let urls = imageFileURLs(from: pasteboard)
        if !urls.isEmpty {
            return importImages?(urls, nil, range) == true
        }
        let webURLs = publicWebURLs(from: pasteboard)
        if !webURLs.isEmpty {
            let location = artifactDropLocation(at: point)
            return insertWebURLs?(webURLs, NSRange(location: location, length: 0)) == true
        }
        return super.performDragOperation(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawBlockBackgrounds(in: dirtyRect)
        drawBlockQuoteBars(in: dirtyRect)
        super.draw(dirtyRect)
        guard let layoutManager, textContainer != nil else { return }
        if let titlePlaceholder, string.hasPrefix("# ") {
            let source = string as NSString
            let characterIndex = min(2, source.length)
            if characterIndex < source.length {
                let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
                let line = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
                let point = NSPoint(
                    x: textContainerOrigin.x + line.minX,
                    y: textContainerOrigin.y + line.minY
                )
                titlePlaceholder.text.draw(at: point, withAttributes: [
                    .font: titlePlaceholder.font,
                    .foregroundColor: titlePlaceholder.color
                ])
            }
        }
        for rendered in renderedChecklists {
            guard let rect = checklistRect(for: rendered), rect.intersects(dirtyRect) else { continue }
            drawChecklist(rendered, in: rect)
        }
        for rendered in renderedOrderedLists {
            guard let rect = orderedListRect(for: rendered), rect.intersects(dirtyRect) else { continue }
            drawOrderedListMarker(rendered, in: rect)
        }
        for rendered in renderedHorizontalRules {
            guard let rect = horizontalRuleRect(for: rendered), rect.intersects(dirtyRect) else { continue }
            palette.separator.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 0.5, yRadius: 0.5).fill()
        }
        for rendered in renderedMath {
            guard let rect = mathRect(for: rendered), rect.intersects(dirtyRect) else { continue }
            rendered.displayText.draw(at: rect.origin, withAttributes: [
                .font: rendered.font,
                .foregroundColor: palette.text
            ])
        }
        for rendered in renderedInlineReplacements {
            guard let rect = inlineReplacementRect(
                for: rendered.sourceRange,
                font: rendered.font,
                size: rendered.size,
                baselineOffset: rendered.baselineOffset
            ), rect.intersects(dirtyRect) else { continue }
            rendered.displayText.draw(at: rect.origin, withAttributes: [
                .font: rendered.font,
                .foregroundColor: rendered.color
            ])
        }
        for rendered in renderedKeycaps {
            guard let rect = keycapRect(for: rendered), rect.intersects(dirtyRect) else { continue }
            let background = palette.text.withAlphaComponent(0.10)
            let border = palette.separator.withAlphaComponent(0.72)
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            background.setFill()
            path.fill()
            border.setStroke()
            path.lineWidth = 1
            path.stroke()
            let textSize = (rendered.displayText as NSString).size(withAttributes: [
                .font: rendered.font
            ])
            rendered.displayText.draw(at: NSPoint(
                x: rect.midX - textSize.width / 2,
                y: rect.midY - textSize.height / 2
            ), withAttributes: [
                .font: rendered.font,
                .foregroundColor: palette.text
            ])
        }
        for rendered in renderedFootnoteReferences {
            guard let rect = inlineReplacementRect(
                for: rendered.sourceRange,
                font: rendered.font,
                size: rendered.size,
                baselineOffset: 5
            ), rect.intersects(dirtyRect) else { continue }
            rendered.displayText.draw(at: rect.origin, withAttributes: [
                .font: rendered.font,
                .foregroundColor: palette.accent
            ])
        }
        for rendered in renderedFootnoteDefinitions {
            guard let rect = footnoteDefinitionRect(for: rendered),
                  rect.intersects(dirtyRect) else { continue }
            if rendered.isFirst {
                palette.separator.withAlphaComponent(0.65).setFill()
                NSBezierPath.fill(NSRect(
                    x: textContainerOrigin.x,
                    y: rect.minY - 11,
                    width: min(160, max(40, bounds.width - textContainerOrigin.x * 2)),
                    height: 1
                ))
            }
            let textSize = (rendered.displayText as NSString).size(withAttributes: [
                .font: rendered.font
            ])
            rendered.displayText.draw(at: NSPoint(
                x: rect.maxX - 6 - textSize.width,
                y: rect.minY
            ), withAttributes: [
                .font: rendered.font,
                .foregroundColor: palette.secondaryText
            ])
        }
        for rendered in renderedDetails {
            guard let rect = detailsSummaryRect(for: rendered), rect.intersects(dirtyRect) else {
                continue
            }
            let center = NSPoint(x: textContainerOrigin.x + 7, y: rect.midY)
            let chevron = NSBezierPath()
            if rendered.isExpanded {
                chevron.move(to: NSPoint(x: center.x - 4, y: center.y - 2))
                chevron.line(to: NSPoint(x: center.x, y: center.y + 2))
                chevron.line(to: NSPoint(x: center.x + 4, y: center.y - 2))
            } else {
                chevron.move(to: NSPoint(x: center.x - 2, y: center.y - 4))
                chevron.line(to: NSPoint(x: center.x + 2, y: center.y))
                chevron.line(to: NSPoint(x: center.x - 2, y: center.y + 4))
            }
            chevron.lineWidth = 1.6
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            palette.secondaryText.setStroke()
            chevron.stroke()
        }
        for rendered in renderedImages {
            guard let rect = imageRect(for: rendered) else { continue }
            guard rect.intersects(dirtyRect) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).addClip()
            rendered.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()

            if NSIntersectionRange(selectedRange(), rendered.range).length > 0 {
                palette.accent.setStroke()
                let outline = NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -2), xRadius: 10, yRadius: 10)
                outline.lineWidth = 3
                outline.stroke()
            }
        }
        if let artifactInsertionY {
            palette.accent.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: textContainerOrigin.x, y: artifactInsertionY - 1, width: max(40, bounds.width - textContainerOrigin.x * 2), height: 2),
                xRadius: 1,
                yRadius: 1
            ).fill()
        }
        if let imageInsertionRect {
            palette.accent.setFill()
            NSBezierPath(roundedRect: imageInsertionRect, xRadius: 1, yRadius: 1).fill()
        }
    }

    private func drawBlockBackgrounds(in dirtyRect: NSRect) {
        guard !renderedCodeBlocks.isEmpty else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        palette.text.withAlphaComponent(isDark ? 0.09 : 0.055).setFill()
        for rendered in renderedCodeBlocks {
            guard let rect = codeBlockRect(for: rendered), rect.intersects(dirtyRect) else { continue }
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        }
    }

    private func drawBlockQuoteBars(in dirtyRect: NSRect) {
        palette.secondaryText.withAlphaComponent(0.42).setFill()
        for rect in blockQuoteBarRects() where rect.intersects(dirtyRect) {
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }
    }

    func blockQuoteBarRects() -> [NSRect] {
        guard let layoutManager, textContainer != nil else { return [] }
        let source = string as NSString
        let maximumDepth = renderedBlockQuoteLines.map(\.depth).max() ?? 0
        var rects: [NSRect] = []
        for level in 0..<maximumDepth {
            var run: [RenderedBlockQuoteLine] = []

            func drawRun() {
                guard let first = run.first,
                      let last = run.last,
                      first.markerRange.location < source.length,
                      last.lineRange.location < source.length else {
                    run.removeAll()
                    return
                }
                let firstGlyph = layoutManager.glyphIndexForCharacter(
                    at: first.markerRange.location
                )
                let lastCharacter = min(
                    source.length - 1,
                    max(last.markerRange.location, NSMaxRange(last.lineRange) - 1)
                )
                let lastGlyph = layoutManager.glyphIndexForCharacter(at: lastCharacter)
                let firstLine = layoutManager.lineFragmentRect(
                    forGlyphAt: firstGlyph,
                    effectiveRange: nil
                )
                let lastLine = layoutManager.lineFragmentRect(
                    forGlyphAt: lastGlyph,
                    effectiveRange: nil
                )
                let rect = NSRect(
                    x: textContainerOrigin.x + CGFloat(level) * 16,
                    y: textContainerOrigin.y + firstLine.minY - 2,
                    width: 2,
                    height: lastLine.maxY - firstLine.minY + 4
                )
                rects.append(rect)
                run.removeAll()
            }

            for rendered in renderedBlockQuoteLines {
                guard rendered.depth > level else {
                    drawRun()
                    continue
                }
                if let previous = run.last,
                   NSMaxRange(previous.lineRange) != rendered.lineRange.location {
                    drawRun()
                }
                run.append(rendered)
            }
            drawRun()
        }
        return rects
    }

    private func inlineReplacementRect(
        for sourceRange: NSRange,
        font: NSFont,
        size: NSSize,
        baselineOffset: CGFloat
    ) -> NSRect? {
        guard let layoutManager, let textContainer,
              sourceRange.location < (string as NSString).length else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: sourceRange.location)
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1),
            in: textContainer
        )
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let baseline = textContainerOrigin.y
            + line.minY
            + layoutManager.defaultBaselineOffset(for: font)
            - baselineOffset
        return NSRect(
            x: textContainerOrigin.x + glyphRect.minX,
            y: baseline - font.ascender,
            width: size.width,
            height: size.height
        )
    }

    private func keycapRect(for rendered: RenderedKeycap) -> NSRect? {
        guard let layoutManager, let textContainer,
              rendered.sourceRange.location < (string as NSString).length else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: rendered.sourceRange.location)
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1),
            in: textContainer
        )
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return NSRect(
            x: textContainerOrigin.x + glyphRect.minX,
            y: textContainerOrigin.y + line.midY - rendered.size.height / 2,
            width: rendered.size.width,
            height: rendered.size.height
        )
    }

    private func footnoteDefinitionRect(for rendered: RenderedFootnoteDefinition) -> NSRect? {
        guard let layoutManager, let textContainer,
              rendered.prefixRange.location < (string as NSString).length else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: rendered.prefixRange.location)
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1),
            in: textContainer
        )
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let baseline = textBaselineY(after: rendered.prefixRange)
            ?? (textContainerOrigin.y
                + line.minY
                + layoutManager.defaultBaselineOffset(for: rendered.font))
        return NSRect(
            x: textContainerOrigin.x + glyphRect.minX,
            y: baseline - rendered.font.ascender,
            width: rendered.slotWidth,
            height: rendered.font.ascender - rendered.font.descender + rendered.font.leading
        )
    }

    func detailsSummaryRect(for rendered: RenderedDetails) -> NSRect? {
        guard let layoutManager, let textContainer,
              rendered.summaryContentRange.location < (string as NSString).length else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: rendered.summaryContentRange.location)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return NSRect(
            x: textContainerOrigin.x,
            y: textContainerOrigin.y + line.minY,
            width: max(40, textContainer.size.width),
            height: line.height
        )
    }

    private func codeBlockRect(for rendered: RenderedCodeBlock) -> NSRect? {
        guard let layoutManager, let textContainer,
              rendered.contentRange.length > 0,
              rendered.contentRange.location < (string as NSString).length else { return nil }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: rendered.contentRange,
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 else { return nil }
        let firstLine = layoutManager.lineFragmentRect(
            forGlyphAt: glyphRange.location,
            effectiveRange: nil
        )
        let lastLine = layoutManager.lineFragmentRect(
            forGlyphAt: max(glyphRange.location, NSMaxRange(glyphRange) - 1),
            effectiveRange: nil
        )
        return NSRect(
            x: textContainerOrigin.x,
            y: textContainerOrigin.y + firstLine.minY - 5,
            width: max(40, textContainer.size.width),
            height: lastLine.maxY - firstLine.minY + 10
        )
    }

    private func horizontalRuleRect(for rendered: RenderedHorizontalRule) -> NSRect? {
        guard let layoutManager, let textContainer,
              rendered.sourceRange.location < (string as NSString).length else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: rendered.sourceRange.location)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return NSRect(
            x: textContainerOrigin.x,
            y: textContainerOrigin.y + line.midY,
            width: max(40, textContainer.size.width),
            height: 1
        )
    }

    private func mathRect(for rendered: RenderedMath) -> NSRect? {
        guard let layoutManager, let textContainer,
              rendered.sourceRange.location < (string as NSString).length else { return nil }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: rendered.sourceRange.location, length: 1),
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 else { return nil }
        let glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        let x = rendered.isBlock
            ? textContainerOrigin.x + max(0, (textContainer.size.width - rendered.size.width) / 2)
            : textContainerOrigin.x + glyphRect.minX
        let baseline = textContainerOrigin.y
            + line.minY
            + layoutManager.defaultBaselineOffset(for: rendered.font)
        return NSRect(
            x: x,
            y: baseline - rendered.font.ascender,
            width: rendered.size.width,
            height: rendered.size.height
        )
    }

    private func imageFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.filter { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return type.conforms(to: .image)
        }
    }

    private func publicWebURLs(from pasteboard: NSPasteboard) -> [URL] {
        let candidates = (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? [])
            + (pasteboard.string(forType: .string)?.split(whereSeparator: \Character.isNewline)
                .compactMap { URL(string: String($0).trimmingCharacters(in: .whitespaces)) } ?? [])
        var seen = Set<URL>()
        return candidates.filter { url in
            guard !url.isFileURL,
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  url.host?.isEmpty == false,
                  url.user == nil,
                  url.password == nil,
                  !seen.contains(url) else { return false }
            seen.insert(url)
            return true
        }
    }

    private func notePayload(from pasteboard: NSPasteboard) -> MarkdownDocumentDragPayload? {
        MarkdownDocumentDragPayload.read(from: pasteboard, linkableExtensions: linkableDocumentExtensions)
    }

    private func autoscrollNearEdge(_ point: NSPoint) {
        guard let scrollView = enclosingScrollView else { return }
        let visible = visibleRect
        let edge: CGFloat = 34
        if point.y < visible.minY + edge {
            scrollView.contentView.scroll(to: NSPoint(x: visible.minX, y: max(0, visible.minY - 20)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else if point.y > visible.maxY - edge {
            scrollView.contentView.scroll(to: NSPoint(x: visible.minX, y: visible.minY + 20))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func insertionRange(at point: NSPoint) -> NSRange {
        if let rendered = renderedImage(at: point),
           let rect = imageRect(for: rendered) {
            return NSRange(
                location: point.x < rect.midX ? rendered.range.location : NSMaxRange(rendered.range),
                length: 0
            )
        }
        guard let layoutManager, let textContainer else { return selectedRange() }
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        let characterIndex = min(layoutManager.characterIndexForGlyph(at: glyphIndex), (string as NSString).length)
        return NSRange(location: characterIndex, length: 0)
    }

    private func renderedImage(at point: NSPoint) -> RenderedImage? {
        renderedImages.reversed().first { rendered in
            imageRect(for: rendered)?.contains(point) == true
        }
    }

    private func renderedChecklist(at point: NSPoint) -> RenderedChecklist? {
        renderedChecklists.first { rendered in
            checklistRect(for: rendered)?.contains(point) == true
        }
    }

    private func renderedDetails(at point: NSPoint) -> RenderedDetails? {
        renderedDetails.first { rendered in
            detailsSummaryRect(for: rendered)?.contains(point) == true
        }
    }

    private func renderedObjectCursor(at point: NSPoint) -> NSCursor? {
        if renderedImage(at: point) != nil {
            return didBeginImageDrag ? .closedHand : .pointingHand
        }
        if renderedChecklist(at: point) != nil {
            return .pointingHand
        }
        if renderedDetails(at: point) != nil {
            return .pointingHand
        }
        if artifactViews.values.contains(where: { !$0.isHidden && $0.frame.contains(point) }) {
            return .pointingHand
        }
        return nil
    }

    private func imageRect(for rendered: RenderedImage) -> NSRect? {
        guard let layoutManager, let textContainer,
              rendered.range.location < (string as NSString).length else { return nil }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: rendered.range.location, length: 1),
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 else { return nil }
        let glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        return NSRect(
            x: textContainerOrigin.x + glyphRect.minX,
            y: textContainerOrigin.y + line.minY + max(0, (line.height - rendered.size.height) / 2),
            width: rendered.size.width,
            height: rendered.size.height
        )
    }

    func checklistRect(for rendered: RenderedChecklist) -> NSRect? {
        guard let layoutManager, let textContainer,
              rendered.markerRange.location < (string as NSString).length else { return nil }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: rendered.markerRange.location, length: 1),
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 else { return nil }
        let glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        let markerBaselineY = textContainerOrigin.y
            + line.minY
            + layoutManager.defaultBaselineOffset(for: rendered.font)
        let centerY: CGFloat
        if let baselineY = textBaselineY(after: rendered.markerRange) {
            centerY = baselineY - rendered.font.capHeight / 2
        } else {
            centerY = markerBaselineY - rendered.font.capHeight / 2
        }
        return NSRect(
            x: textContainerOrigin.x + glyphRect.maxX - rendered.controlSlotWidth,
            y: centerY - rendered.controlSize / 2,
            width: rendered.controlSize,
            height: rendered.controlSize
        )
    }

    private func drawChecklist(_ rendered: RenderedChecklist, in rect: NSRect) {
        let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3)
        if rendered.isChecked {
            palette.accent.setFill()
            box.fill()

            let check = NSBezierPath()
            check.move(to: NSPoint(x: rect.minX + rect.width * 0.25, y: rect.midY))
            check.line(to: NSPoint(x: rect.minX + rect.width * 0.43, y: rect.minY + rect.height * 0.68))
            check.line(to: NSPoint(x: rect.minX + rect.width * 0.76, y: rect.minY + rect.height * 0.32))
            check.lineWidth = 1.8
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            palette.onAccent.setStroke()
            check.stroke()
        } else {
            palette.tertiaryText.setStroke()
            box.lineWidth = 1.5
            box.stroke()
        }
    }

    func orderedListRect(for rendered: RenderedOrderedList) -> NSRect? {
        guard let layoutManager, let textContainer,
              rendered.markerRange.location < (string as NSString).length else { return nil }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: rendered.markerRange.location, length: 1),
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 else { return nil }
        let glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        let markerBaselineY = textContainerOrigin.y
            + line.minY
            + layoutManager.defaultBaselineOffset(for: rendered.font)
        let baselineY = textBaselineY(after: rendered.markerRange)
            ?? markerBaselineY
        return NSRect(
            x: textContainerOrigin.x + glyphRect.maxX - rendered.markerSlotWidth,
            y: baselineY - rendered.font.ascender,
            width: rendered.markerSlotWidth,
            height: rendered.font.ascender - rendered.font.descender + rendered.font.leading
        )
    }

    private func drawOrderedListMarker(_ rendered: RenderedOrderedList, in rect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: rendered.font,
            .foregroundColor: palette.text
        ]
        let labelSize = (rendered.label as NSString).size(withAttributes: attributes)
        rendered.label.draw(
            at: NSPoint(
                x: rect.maxX - rendered.trailingGap - labelSize.width,
                y: rect.minY
            ),
            withAttributes: attributes
        )
    }

    private func textBaselineY(after markerRange: NSRange) -> CGFloat? {
        let source = string as NSString
        let contentLocation = NSMaxRange(markerRange)
        guard let layoutManager,
              markerRange.location != NSNotFound,
              contentLocation < source.length,
              ![unichar(10), unichar(13)].contains(source.character(at: contentLocation))
        else { return nil }
        let contentGlyph = layoutManager.glyphIndexForCharacter(at: contentLocation)
        let contentLine = layoutManager.lineFragmentRect(
            forGlyphAt: contentGlyph,
            effectiveRange: nil
        )
        let baselineOffset = layoutManager.location(forGlyphAt: contentGlyph).y
        return textContainerOrigin.y + contentLine.minY + baselineOffset
    }

    private func insertionIndicatorRect(at location: Int) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let sourceLength = (string as NSString).length
        if sourceLength == 0 {
            return NSRect(x: textContainerOrigin.x, y: textContainerOrigin.y, width: 2, height: 22)
        }
        let characterIndex = min(max(location, 0), sourceLength - 1)
        let glyph = layoutManager.glyphIndexForCharacter(at: characterIndex)
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1),
            in: textContainer
        )
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let x = location >= sourceLength ? line.maxX : glyphRect.minX
        return NSRect(
            x: textContainerOrigin.x + x - 1,
            y: textContainerOrigin.y + line.minY,
            width: 2,
            height: line.height
        )
    }

    private func currentLineIsEmpty(at range: NSRange) -> Bool {
        let source = string as NSString
        let lineRange = source.lineRange(for: NSRange(location: min(range.location, source.length), length: 0))
        return source.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func blockBoundary(at location: Int) -> Int {
        let source = string as NSString
        guard source.length > 0 else { return 0 }
        if location >= source.length { return source.length }
        return source.lineRange(for: NSRange(location: max(0, location), length: 0)).location
    }

    private func artifactDropLocation(at point: NSPoint) -> Int {
        MarkdownArtifactInsertion.blockLocation(
            in: string,
            near: insertionRange(at: point).location
        )
    }

    private func insertionY(at location: Int) -> CGFloat? {
        guard let layoutManager, let textContainer else { return nil }
        if location >= (string as NSString).length {
            return layoutManager.usedRect(for: textContainer).maxY + textContainerOrigin.y
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: max(0, location))
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + textContainerOrigin.y
    }

    private func synchronizeArtifactViews() {
        let validIDs = Set(renderedArtifacts.map(\.artifact.id))
        for (id, view) in artifactViews where !validIDs.contains(id) {
            view.removeFromSuperview()
            artifactViews[id] = nil
        }
        for rendered in renderedArtifacts {
            let view = artifactViews[rendered.artifact.id] ?? {
                let view = ArtifactCardView(frame: .zero)
                addSubview(view)
                artifactViews[rendered.artifact.id] = view
                return view
            }()
            view.palette = palette
            view.configure(rendered.content)
            view.reorderPayload = .init(
                blockLocation: rendered.artifact.blockRange.location,
                blockLength: rendered.artifact.blockRange.length,
                source: rendered.artifact.source
            )
            view.onActivate = { [weak self] in self?.activateArtifact?(rendered.artifact) }
        }
    }

    private func layoutArtifactViews() {
        guard let layoutManager, textContainer != nil else { return }
        let availableWidth = max(180, min(300, bounds.width - textContainerOrigin.x * 2 - 4))
        for rendered in renderedArtifacts {
            guard let view = artifactViews[rendered.artifact.id],
                  rendered.artifact.sourceRange.location < (string as NSString).length else { continue }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: rendered.artifact.sourceRange,
                actualCharacterRange: nil
            )
            guard glyphRange.length > 0 else { continue }
            let glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer!)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            view.frame = NSRect(
                x: textContainerOrigin.x + glyphRect.minX + 4,
                y: textContainerOrigin.y + line.minY + 5,
                width: availableWidth,
                height: rendered.height
            ).integral
        }
    }
}
