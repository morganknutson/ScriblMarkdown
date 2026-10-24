import AppKit
import ScriblMarkdown

/// Drives a `MarkdownEditorTextView`: restyles the Markdown source after every edit,
/// lays out rendered objects (images, cards, checklists, tables, math), and implements
/// list continuation, formatting commands, drops and reordering. The source text is
/// never rewritten into rich text; styling only decorates it.
public final class MarkdownEditorController: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
    public enum Presentation: Equatable {
        case styled
        case source
    }

    /// Called with the new source after every user edit.
    public var onTextChange: ((String) -> Void)?
    /// Called after the selection moves, such as to refresh a toolbar from `formatting(in:)`.
    public var onSelectionChange: (() -> Void)?
    /// The document's file, which relative image and note links resolve against.
    public var documentURL: URL?
    public var presentation: Presentation
    public var style: MarkdownEditorStyle
    public var titlePolicy: MarkdownEditorTitlePolicy
    public weak var host: (any MarkdownEditorHost)?
    var lastFocusRequestID: UUID?
    public var onFocusRequestHandled: ((UUID) -> Void)?
    private var isStyling = false
    private var bulletCharacterIndexes: Set<Int> = []
    private var softBreakCharacterIndexes: Set<Int> = []
    private struct RenderedObjectGlyphLayout {
        let range: NSRange
        let size: NSSize
    }
    private var imageGlyphLayouts: [RenderedObjectGlyphLayout] = []
    private var artifactGlyphLayouts: [RenderedObjectGlyphLayout] = []
    private var checklistGlyphLayouts: [RenderedObjectGlyphLayout] = []
    private var orderedListGlyphLayouts: [RenderedObjectGlyphLayout] = []
    private var tableGlyphLayouts: [RenderedObjectGlyphLayout] = []
    private var mathGlyphLayouts: [RenderedObjectGlyphLayout] = []
    private var quoteGlyphLayouts: [RenderedObjectGlyphLayout] = []
    private var inlineReplacementGlyphLayouts: [RenderedObjectGlyphLayout] = []
    private var keycapGlyphLayouts: [RenderedObjectGlyphLayout] = []
    private var footnoteGlyphLayouts: [RenderedObjectGlyphLayout] = []
    private var webMetadata: [URL: WebLinkMetadata] = [:]
    private var metadataTasks: [URL: Task<Void, Never>] = [:]

    private final class WeakArtifactTextView: @unchecked Sendable {
        weak var value: MarkdownEditorTextView?
        init(_ value: MarkdownEditorTextView) { self.value = value }
    }

    public init(
        documentURL: URL? = nil,
        presentation: Presentation = .styled,
        style: MarkdownEditorStyle = MarkdownEditorStyle(),
        titlePolicy: MarkdownEditorTitlePolicy = .none,
        host: (any MarkdownEditorHost)? = nil,
        onTextChange: ((String) -> Void)? = nil
    ) {
        self.documentURL = documentURL
        self.presentation = presentation
        self.style = style
        self.titlePolicy = titlePolicy
        self.host = host
        self.onTextChange = onTextChange
    }

    deinit {
        metadataTasks.values.forEach { $0.cancel() }
    }

    private var palette: MarkdownEditorPalette { style.palette }
    private var typeface: any MarkdownEditorTypeface { style.typeface }
    private var linkableDocumentURLs: [URL] { host?.linkableDocumentURLs ?? [] }

    private var artifactParser: MarkdownArtifactParser {
        MarkdownArtifactParser(
            linkableDocumentExtensions: host?.linkableDocumentExtensions ?? ["md", "markdown"]
        )
    }

    /// Whether the first line is a protected title in the current presentation.
    private var protectsLeadingTitle: Bool {
        guard presentation == .styled,
              case .protectedLeadingHeading = titlePolicy else { return false }
        return true
    }

    private var titlePlaceholder: String? {
        guard case .protectedLeadingHeading(let placeholder) = titlePolicy else { return nil }
        return placeholder
    }

    /// Makes this controller `textView`'s delegate and routes its drops, clicks and
    /// rendered-object interactions back here.
    func attach(to textView: MarkdownEditorTextView) {
        textView.delegate = self
        textView.layoutManager?.delegate = self
        textView.importImages = { [weak self, weak textView] urls, image, range in
            guard let self, let textView else { return false }
            return self.importImages(at: urls, pastedImage: image, range: range, into: textView)
        }
        textView.insertWebURLs = { [weak self, weak textView] urls, range in
            guard let self, let textView else { return false }
            return self.insertWebURLs(urls, at: range, into: textView)
        }
        textView.insertNotePayload = { [weak self, weak textView] payload, range in
            guard let self, let textView else { return false }
            return self.insertNotePayload(payload, at: range, into: textView)
        }
        textView.reorderImage = { [weak self, weak textView] payload, destination in
            guard let self, let textView else { return false }
            return self.reorderImage(payload, to: destination, in: textView)
        }
        textView.reorderArtifact = { [weak self, weak textView] payload, destination in
            guard let self, let textView else { return false }
            return self.reorderArtifact(payload, to: destination, in: textView)
        }
        textView.toggleChecklist = { [weak self, weak textView] stateRange, checked in
            guard let self, let textView else { return }
            self.setChecklistState(checked, stateRange: stateRange, in: textView)
        }
        textView.toggleDetails = { [weak self, weak textView] openingRange, expanded in
            guard let self, let textView else { return }
            self.setDetailsExpanded(expanded, openingTagRange: openingRange, in: textView)
        }
        textView.activateArtifact = { [weak self] artifact in
            self?.activate(artifact)
        }
        textView.widthDidChange = { [weak self, weak textView] in
            guard let self, let textView else { return }
            self.applyPresentation(to: textView)
        }
        textView.recordEditorEvent = { [weak self] message, metadata in
            self?.host?.recordEditorEvent(message, metadata: metadata)
        }
    }

    func handleFocusRequest(_ requestID: UUID?, in textView: NSTextView) {
        guard let requestID, lastFocusRequestID != requestID else { return }
        lastFocusRequestID = requestID
        if hasEmptyTitle(in: textView) {
            focusEmptyTitle(in: textView)
        }
        let onFocusRequestHandled = onFocusRequestHandled
        DispatchQueue.main.async {
            onFocusRequestHandled?(requestID)
        }
    }

    public func textDidChange(_ notification: Notification) {
        guard !isStyling, let textView = notification.object as? NSTextView else { return }
        let bulletRanges = MarkdownListNormalizer.literalBulletMarkerRanges(in: textView.string)
        if let storage = textView.textStorage, !bulletRanges.isEmpty {
            isStyling = true
            storage.beginEditing()
            for range in bulletRanges.reversed() {
                storage.replaceCharacters(in: range, with: "-")
            }
            storage.endEditing()
            isStyling = false
        }
        onTextChange?(textView.string)
        applyPresentation(to: textView)
        (textView as? MarkdownEditorTextView)?.finishTextChange()
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        if presentation == .styled {
            (textView as? MarkdownEditorTextView)?.normalizeRenderedObjectSelection()
        }
        protectTitlePrefixSelection(in: textView)
        onSelectionChange?()
    }

    /// The formatting at the caret, read from the source line and the styled text.
    func formatting(in textView: NSTextView) -> MarkdownEditorFormatting {
        let source = textView.string as NSString
        let selection = textView.selectedRange()
        let location = min(selection.location, source.length)
        let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
        let line = source.substring(with: lineRange)
        let headingMarker = line.prefix { $0 == "#" }.count
        let headingLevel = (1...6).contains(headingMarker)
            && line.dropFirst(headingMarker).first.map { $0 == " " || $0 == "\t" } == true
            ? headingMarker
            : nil
        let isQuote = line.drop { $0 == " " || $0 == "\t" }.first == ">"
        let isCodeBlock = (textView as? MarkdownEditorTextView)?.renderedCodeBlocks.contains {
            NSLocationInRange(location, $0.contentRange)
        } == true

        // Inline styles come from the character the next keystroke would extend.
        let probe = selection.length > 0 ? location : location - 1
        var font: NSFont?
        if presentation == .styled, probe >= 0, probe < source.length {
            font = textView.textStorage?.attribute(.font, at: probe, effectiveRange: nil) as? NSFont
        }
        let traits = font?.fontDescriptor.symbolicTraits ?? []
        return MarkdownEditorFormatting(
            headingLevel: headingLevel,
            isBold: headingLevel == nil && traits.contains(.bold),
            isItalic: traits.contains(.italic),
            isInlineCode: !isCodeBlock && traits.contains(.monoSpace),
            isQuote: isQuote,
            isCodeBlock: isCodeBlock
        )
    }

    public func textView(
        _ textView: NSTextView,
        clickedOnLink link: Any,
        at charIndex: Int
    ) -> Bool {
        let url: URL?
        if let link = link as? URL {
            url = link
        } else if let link = link as? String {
            url = URL(string: link)
        } else {
            url = nil
        }
        guard let url else { return false }
        if url.scheme == "scribl-footnote",
           let location = Int(url.lastPathComponent) {
            let target = min(max(0, location), (textView.string as NSString).length)
            textView.setSelectedRange(NSRange(location: target, length: 0))
            textView.scrollRangeToVisible(NSRange(location: target, length: 0))
            textView.window?.makeFirstResponder(textView)
            return true
        }
        if url.isFileURL,
           let documentURL = linkedDocumentURL(matching: url),
           host?.openLinkedDocument(at: documentURL) == true {
            return true
        }
        return NSWorkspace.shared.open(url)
    }

    public func textView(
        _ textView: NSTextView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        guard host?.shouldChangeText(
            in: textView,
            range: affectedCharRange,
            replacement: replacementString
        ) != false else { return false }
        let replacement = replacementString ?? ""
        let changesProtectedTitlePrefix = protectsLeadingTitle
            && textView.string.hasPrefix("# ")
            && NSIntersectionRange(
                affectedCharRange,
                NSRange(location: 0, length: 2)
            ).length > 0
            && !replacement.hasPrefix("# ")
        if changesProtectedTitlePrefix {
            replaceProtectedTitleSelection(
                in: textView,
                range: affectedCharRange,
                replacement: replacement
            )
            return false
        }
        if presentation == .styled {
            (textView as? MarkdownEditorTextView)?.prepareForTextChange(
                in: affectedCharRange,
                replacement: replacement
            )
        }
        return true
    }

    public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
            if presentation == .styled,
               (textView as? MarkdownEditorTextView)?.deleteRenderedObject(forward: false) == true {
                return true
            }
            if presentation == .styled,
               handleListMarkerDeletion(in: textView, forward: false) {
                return true
            }
            return preserveTitlePrefixDuringDeletion(in: textView, forward: false)
        }
        if commandSelector == #selector(NSResponder.deleteForward(_:)) {
            if presentation == .styled,
               (textView as? MarkdownEditorTextView)?.deleteRenderedObject(forward: true) == true {
                return true
            }
            if presentation == .styled,
               handleListMarkerDeletion(in: textView, forward: true) {
                return true
            }
            return preserveTitlePrefixDuringDeletion(in: textView, forward: true)
        }
        if presentation == .styled,
           ["moveRight:", "moveForward:"].contains(NSStringFromSelector(commandSelector)),
           (textView as? MarkdownEditorTextView)?.moveAcrossRenderedObject(forward: true) == true {
            return true
        }
        if presentation == .styled,
           ["moveLeft:", "moveBackward:"].contains(NSStringFromSelector(commandSelector)),
           (textView as? MarkdownEditorTextView)?.moveAcrossRenderedObject(forward: false) == true {
            return true
        }
        if hasEmptyTitle(in: textView),
           commandSelector == #selector(NSResponder.insertNewline(_:))
            || commandSelector == #selector(NSResponder.moveDown(_:)) {
            solidifyEmptyTitle(in: textView)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            return continueListAfterNewline(in: textView)
        }
        if commandSelector == #selector(NSResponder.insertTab(_:))
            || commandSelector == NSSelectorFromString("insertTabIgnoringFieldEditor:") {
            return adjustListIndent(in: textView, outdent: false)
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            return adjustListIndent(in: textView, outdent: true)
        }
        return false
    }

    func apply(_ action: MarkdownEditorCommand.Action, to textView: NSTextView) {
        textView.window?.makeFirstResponder(textView)
        host?.recordEditorEvent(
            "Formatting action applied",
            metadata: ["action": String(describing: action)]
        )

        switch action {
        case .title:
            applyTitleStyle(to: textView)
        case .heading:
            applyLineStyle("## ", to: textView)
        case .subheading:
            applyLineStyle("### ", to: textView)
        case .smallHeading:
            applyLineStyle("#### ", to: textView)
        case .body:
            applyLineStyle(nil, to: textView)
        case .quote:
            applyQuoteStyle(to: textView)
        case .bold:
            wrapSelection(prefix: "**", suffix: "**", in: textView)
        case .italic:
            wrapSelection(prefix: "*", suffix: "*", in: textView)
        case .inlineCode:
            wrapSelection(prefix: "`", suffix: "`", in: textView)
        case .bulletedList:
            applyListStyle(to: textView)
        case .numberedList:
            applyNumberedListStyle(to: textView)
        case .checklist:
            applyChecklistStyle(to: textView)
        case .codeBlock:
            applyCodeBlock(to: textView)
        case .link(let title, let destination):
            apply(MarkdownInsertion.link(
                title: title,
                destination: destination,
                in: textView.string,
                selection: textView.selectedRange()
            ), to: textView)
        case .horizontalRule:
            apply(MarkdownInsertion.horizontalRule(
                in: textView.string,
                selection: textView.selectedRange()
            ), to: textView)
        }
    }

    /// Applies a shared source edit through the text view so it is undoable and restyled.
    private func apply(_ edit: MarkdownEdit, to textView: NSTextView) {
        textView.insertText(edit.replacement, replacementRange: edit.range)
        textView.setSelectedRange(edit.selection)
    }

    func applyPresentation(to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        isStyling = true
        defer { isStyling = false }

        updateBulletCharacterIndexes(in: storage.string)
        if let markdownTextView = textView as? MarkdownEditorTextView {
            markdownTextView.palette = palette
            markdownTextView.linkableDocumentExtensions = artifactParser.linkableDocumentExtensions
        }

        let selectedRange = textView.selectedRange()
        let fullRange = NSRange(location: 0, length: storage.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = presentation == .styled ? 5 : 4
        paragraph.paragraphSpacing = presentation == .styled ? 7 : 0
        let bodyFont = presentation == .styled
            ? typeface.font(ofSize: scaled(17))
            : typeface.monospacedFont(ofSize: scaled(15), weight: .regular)

        storage.beginEditing()
        storage.setAttributes([
            .font: bodyFont,
            .foregroundColor: palette.text,
            .paragraphStyle: paragraph
        ], range: fullRange)

        if presentation == .styled {
            let allCodeBlocks = MarkdownCodeBlock.blocks(in: storage.string)
            let codeRanges = allCodeBlocks.map(\.sourceRange)
            let detailsBlocks = MarkdownDetailsBlock.blocks(
                in: storage.string,
                excluding: codeRanges
            )
            let collapsedDetailsRanges = detailsBlocks
                .filter { !$0.isExpanded }
                .map(\.bodyRange)
            let visibleCodeBlocks = allCodeBlocks.filter {
                !intersects($0.sourceRange, collapsedDetailsRanges)
            }
            styleCodeBlocks(visibleCodeBlocks, in: storage, textView: textView)
            let blockExclusions = codeRanges + collapsedDetailsRanges
            styleTables(in: storage, font: bodyFont, excluding: blockExclusions)
            styleHorizontalRules(in: storage, font: bodyFont, excluding: blockExclusions, textView: textView)
            styleFootnotes(
                in: storage,
                excluding: blockExclusions,
                textView: textView
            )
            styleDefinitionLists(in: storage, excluding: blockExclusions)
            let mathRanges = styleMath(
                in: storage,
                excluding: blockExclusions,
                textView: textView
            )
            let htmlProtectedRanges = styleHTML(
                detailsBlocks,
                in: storage,
                excluding: codeRanges + mathRanges,
                textView: textView
            )
            let protectedRanges = blockExclusions + mathRanges + htmlProtectedRanges
            style(pattern: #"(?m)^(#{1}[ \t]+)(.*)$"#, in: storage, markerGroup: 1, contentGroup: 2, size: 32, excluding: protectedRanges)
            style(pattern: #"(?m)^(#{2}[ \t]+)(.+)$"#, in: storage, markerGroup: 1, contentGroup: 2, size: 24, excluding: protectedRanges)
            style(pattern: #"(?m)^(#{3}[ \t]+)(.+)$"#, in: storage, markerGroup: 1, contentGroup: 2, size: 19, excluding: protectedRanges)
            style(pattern: #"(?m)^(#{4,6}[ \t]+)(.+)$"#, in: storage, markerGroup: 1, contentGroup: 2, size: 17, excluding: protectedRanges)
            styleLists(in: storage, font: bodyFont, excluding: protectedRanges)
            styleOrderedLists(
                in: storage,
                font: bodyFont,
                textView: textView,
                excluding: protectedRanges
            )
            styleChecklists(in: storage, font: bodyFont, textView: textView, excluding: protectedRanges)
            styleBlockQuotes(
                in: storage,
                font: bodyFont,
                excluding: protectedRanges,
                textView: textView
            )
            let inlineCodeRanges = styleCode(in: storage, excluding: protectedRanges)
            let inlineProtectedRanges = protectedRanges + inlineCodeRanges
            let inlineMarkerRanges = styleInlineMarkdown(
                in: storage,
                excluding: inlineProtectedRanges
            )
            styleLinks(in: storage, excluding: inlineProtectedRanges, textView: textView)
            styleEscapesAndEntities(
                in: storage,
                excluding: inlineProtectedRanges,
                existingMarkerRanges: inlineMarkerRanges,
                textView: textView
            )
            layoutTables(in: storage, excluding: blockExclusions)
            styleImages(in: storage, textView: textView, excluding: protectedRanges)
            styleArtifacts(in: storage, textView: textView, excluding: protectedRanges)
            updateSoftBreakCharacterIndexes(
                in: storage.string,
                excluding: codeRanges
                    + MarkdownTable.tables(in: storage.string, excluding: codeRanges).map(\.sourceRange)
                    + detailsBlocks.map(\.sourceRange)
                    + MarkdownBlockQuoteLine.lines(
                        in: storage.string,
                        excluding: codeRanges
                    ).map(\.lineRange)
                    + MarkdownFootnotePresentation.parse(
                        in: storage.string,
                        excluding: codeRanges
                    ).definitions.map(\.lineRange)
            )
            styleEmptyTitle(in: storage)
        } else {
            (textView as? MarkdownEditorTextView)?.renderedImages = []
            (textView as? MarkdownEditorTextView)?.renderedArtifacts = []
            (textView as? MarkdownEditorTextView)?.renderedChecklists = []
            (textView as? MarkdownEditorTextView)?.renderedOrderedLists = []
            (textView as? MarkdownEditorTextView)?.renderedCodeBlocks = []
            (textView as? MarkdownEditorTextView)?.renderedHorizontalRules = []
            (textView as? MarkdownEditorTextView)?.renderedMath = []
            (textView as? MarkdownEditorTextView)?.renderedBlockQuoteLines = []
            (textView as? MarkdownEditorTextView)?.renderedInlineReplacements = []
            (textView as? MarkdownEditorTextView)?.renderedKeycaps = []
            (textView as? MarkdownEditorTextView)?.renderedFootnoteReferences = []
            (textView as? MarkdownEditorTextView)?.renderedFootnoteDefinitions = []
            (textView as? MarkdownEditorTextView)?.renderedDetails = []
            (textView as? MarkdownEditorTextView)?.renderedInlineMarkerRanges = []
            (textView as? MarkdownEditorTextView)?.renderedLinkMarkerRanges = []
            softBreakCharacterIndexes = []
            imageGlyphLayouts = []
            artifactGlyphLayouts = []
            checklistGlyphLayouts = []
            orderedListGlyphLayouts = []
            tableGlyphLayouts = []
            mathGlyphLayouts = []
            quoteGlyphLayouts = []
            inlineReplacementGlyphLayouts = []
            keycapGlyphLayouts = []
            footnoteGlyphLayouts = []
            styleSource(in: storage)
        }
        storage.endEditing()
        updateTitlePlaceholder(in: textView)

        if selectedRange.location <= storage.length {
            textView.setSelectedRange(selectedRange)
        }
        textView.typingAttributes = [
            .font: bodyFont,
            .foregroundColor: palette.text,
            .paragraphStyle: paragraph
        ]
    }

    func refreshPresentationLayout(in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        let fullRange = NSRange(location: 0, length: textView.textStorage?.length ?? 0)
        layoutManager.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
        layoutManager.invalidateDisplay(forCharacterRange: fullRange)
        layoutManager.ensureLayout(for: textContainer)
        textView.needsDisplay = true
    }


    func hasEmptyTitle(in textView: NSTextView) -> Bool {
        guard protectsLeadingTitle else { return false }
        let source = textView.string as NSString
        guard source.hasPrefix("# ") else { return false }
        let firstLine = source.substring(with: source.lineRange(for: NSRange(location: 0, length: 0)))
        return firstLine.trimmingCharacters(in: .whitespacesAndNewlines) == "#"
    }

    private func styleEmptyTitle(in storage: NSTextStorage) {
        let source = storage.string as NSString
        guard protectsLeadingTitle, source.hasPrefix("# ") else { return }
        let lineRange = source.lineRange(for: NSRange(location: 0, length: 0))
        guard source.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines) == "#",
              source.length > 2 else { return }
        let titleFont = typeface.font(ofSize: scaled(32), trait: .boldFontMask)
        let paragraph = (
            storage.attribute(.paragraphStyle, at: 2, effectiveRange: nil) as? NSParagraphStyle
        )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        paragraph.minimumLineHeight = ceil(
            titleFont.ascender - titleFont.descender + titleFont.leading
        )
        storage.addAttribute(.paragraphStyle, value: paragraph, range: lineRange)
    }

    private func updateTitlePlaceholder(in textView: NSTextView) {
        guard let imageTextView = textView as? MarkdownEditorTextView,
              let titlePlaceholder,
              hasEmptyTitle(in: textView) else {
            (textView as? MarkdownEditorTextView)?.titlePlaceholder = nil
            return
        }
        imageTextView.titlePlaceholder = .init(
            text: titlePlaceholder,
            font: typeface.font(ofSize: scaled(32), trait: .boldFontMask),
            color: palette.tertiaryText
        )
    }

    func focusEmptyTitle(in textView: NSTextView) {
        guard hasEmptyTitle(in: textView) else { return }
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        DispatchQueue.main.async { [weak textView] in
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
        }
    }

    func protectTitlePrefixSelection(in textView: NSTextView) {
        guard protectsLeadingTitle,
              textView.string.hasPrefix("# ") else { return }
        let selection = textView.selectedRange()
        guard selection.length == 0, selection.location < 2 else { return }
        textView.setSelectedRange(NSRange(location: 2, length: 0))
    }

    private func solidifyEmptyTitle(in textView: NSTextView) {
        guard let titlePlaceholder, hasEmptyTitle(in: textView) else { return }
        textView.insertText(titlePlaceholder, replacementRange: NSRange(location: 2, length: 0))
        let source = textView.string as NSString
        let titleLine = source.lineRange(for: NSRange(location: 0, length: 0))
        if NSMaxRange(titleLine) <= source.length, titleLine.length > 0,
           source.substring(with: NSRange(location: NSMaxRange(titleLine) - 1, length: 1)) == "\n" {
            textView.setSelectedRange(NSRange(location: NSMaxRange(titleLine), length: 0))
        } else {
            textView.insertText("\n\n", replacementRange: NSRange(location: source.length, length: 0))
            textView.setSelectedRange(NSRange(location: source.length + 1, length: 0))
        }
    }

    private func preserveTitlePrefixDuringDeletion(
        in textView: NSTextView,
        forward: Bool
    ) -> Bool {
        guard protectsLeadingTitle, textView.string.hasPrefix("# ") else { return false }
        let selection = textView.selectedRange()
        let prefixRange = NSRange(location: 0, length: 2)

        if selection.length > 0, NSIntersectionRange(selection, prefixRange).length > 0 {
            replaceProtectedTitleSelection(
                in: textView,
                range: selection,
                replacement: ""
            )
            return true
        }
        if selection.length == 0 {
            if !forward, selection.location <= 2 { return true }
            if forward, selection.location < 2 { return true }
        }
        return false
    }

    private func replaceProtectedTitleSelection(
        in textView: NSTextView,
        range: NSRange,
        replacement: String
    ) {
        let source = textView.string as NSString
        let sourceLength = source.length
        let end = min(NSMaxRange(range), sourceLength)
        guard end > 2 else {
            textView.setSelectedRange(NSRange(location: 2, length: 0))
            return
        }

        let titleLineRange = source.lineRange(for: NSRange(location: 0, length: 0))
        let crossesTitleLine = end >= NSMaxRange(titleLineRange)
        if crossesTitleLine {
            let remaining = source.substring(from: end)
                .drop(while: { $0 == "\n" || $0 == "\r" })
            let titleAndBody = replacement
                + "\n\n"
                + String(remaining)
            textView.insertText(
                titleAndBody,
                replacementRange: NSRange(location: 2, length: sourceLength - 2)
            )
        } else {
            textView.insertText(
                replacement,
                replacementRange: NSRange(location: 2, length: end - 2)
            )
        }
        textView.setSelectedRange(NSRange(
            location: 2 + (replacement as NSString).length,
            length: 0
        ))
    }

    private func style(
        pattern: String,
        in storage: NSTextStorage,
        markerGroup: Int,
        contentGroup: Int,
        size: CGFloat,
        excluding excludedRanges: [NSRange]
    ) {
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: storage.length)
        regex.enumerateMatches(in: storage.string, range: range) { match, _, _ in
            guard let match, !intersects(match.range, excludedRanges) else { return }
            hideMarker(in: storage, range: match.range(at: markerGroup))
            storage.addAttribute(
                .font,
                value: typeface.font(ofSize: scaled(size), trait: .boldFontMask),
                range: match.range(at: contentGroup)
            )
        }
    }

    @discardableResult
    private func styleInlineMarkdown(
        in storage: NSTextStorage,
        excluding excludedRanges: [NSRange]
    ) -> [NSRange] {
        var markerRanges: [NSRange] = []
        let spans = MarkdownInlineSyntax.emphasisSpans(in: storage.string, excluding: excludedRanges)
        for span in spans {
            switch span.style {
            case .strongEmphasis:
                addFontTraits([.boldFontMask, .italicFontMask], to: span.contentRange, in: storage)
            case .strong:
                addFontTraits([.boldFontMask], to: span.contentRange, in: storage)
            case .emphasis:
                addFontTraits([.italicFontMask], to: span.contentRange, in: storage)
            case .strikethrough:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span.contentRange)
            case .highlight:
                storage.addAttribute(.backgroundColor, value: palette.highlight.withAlphaComponent(0.24), range: span.contentRange)
            case .subscript:
                storage.addAttribute(.baselineOffset, value: scaled(-3), range: span.contentRange)
            case .superscript:
                storage.addAttribute(.baselineOffset, value: scaled(5), range: span.contentRange)
            case .code:
                continue
            }
            for marker in span.markerRanges {
                hideMarker(in: storage, range: marker)
                markerRanges.append(marker)
            }
        }
        for span in spans where span.style == .subscript || span.style == .superscript {
            resizeFonts(in: span.contentRange, to: scaled(13), storage: storage)
        }
        return markerRanges
    }

    private func addFontTraits(
        _ traits: [NSFontTraitMask],
        to range: NSRange,
        in storage: NSTextStorage
    ) {
        var runs: [(NSRange, NSFont)] = []
        storage.enumerateAttribute(.font, in: range) { value, runRange, _ in
            if let font = value as? NSFont { runs.append((runRange, font)) }
        }
        for (runRange, originalFont) in runs {
            let font = traits.reduce(originalFont) { partial, trait in
                NSFontManager.shared.convert(partial, toHaveTrait: trait)
            }
            storage.addAttribute(.font, value: font, range: runRange)
        }
    }

    private func resizeFonts(
        in range: NSRange,
        to size: CGFloat,
        storage: NSTextStorage
    ) {
        var runs: [(NSRange, NSFont)] = []
        storage.enumerateAttribute(.font, in: range) { value, runRange, _ in
            if let font = value as? NSFont { runs.append((runRange, font)) }
        }
        for (runRange, font) in runs {
            let resized = NSFont(descriptor: font.fontDescriptor, size: size) ?? font
            storage.addAttribute(.font, value: resized, range: runRange)
        }
    }

    @discardableResult
    private func styleCode(
        in storage: NSTextStorage,
        excluding excludedRanges: [NSRange]
    ) -> [NSRange] {
        let spans = MarkdownInlineSyntax.codeSpans(in: storage.string, excluding: excludedRanges)
        for span in spans {
            storage.addAttributes([
                .font: typeface.monospacedFont(ofSize: scaled(15), weight: .regular),
                .backgroundColor: palette.quaternaryText.withAlphaComponent(0.35)
            ], range: span.contentRange)
            span.markerRanges.forEach { hideMarker(in: storage, range: $0) }
        }
        return spans.map(\.range)
    }

    private func styleEscapesAndEntities(
        in storage: NSTextStorage,
        excluding excludedRanges: [NSRange],
        existingMarkerRanges: [NSRange],
        textView: NSTextView
    ) {
        guard let markdownTextView = textView as? MarkdownEditorTextView else {
            inlineReplacementGlyphLayouts = []
            return
        }
        var markerRanges = existingMarkerRanges
        var rendered: [MarkdownEditorTextView.RenderedInlineReplacement] = []
        var glyphLayouts: [RenderedObjectGlyphLayout] = []
        for replacement in MarkdownInlineSyntax.replacements(in: storage.string, excluding: excludedRanges) {
            switch replacement.kind {
            case .escape:
                let slash = NSRange(location: replacement.range.location, length: 1)
                hideMarker(in: storage, range: slash)
                markerRanges.append(slash)
            case .entity:
                let font = storage.attribute(
                    .font,
                    at: replacement.range.location,
                    effectiveRange: nil
                ) as? NSFont ?? typeface.font(ofSize: scaled(17))
                let size = (replacement.replacement as NSString).size(withAttributes: [.font: font])
                hideMarker(in: storage, range: replacement.range)
                storage.addAttribute(
                    .font,
                    value: font,
                    range: NSRange(location: replacement.range.location, length: 1)
                )
                let measured = NSSize(width: ceil(size.width), height: ceil(size.height))
                rendered.append(.init(
                    sourceRange: replacement.range,
                    displayText: replacement.replacement,
                    font: font,
                    size: measured,
                    baselineOffset: 0,
                    color: palette.text
                ))
                glyphLayouts.append(.init(range: replacement.range, size: measured))
            }
        }
        inlineReplacementGlyphLayouts = glyphLayouts
        markdownTextView.renderedInlineReplacements = rendered
        markdownTextView.renderedInlineMarkerRanges = markerRanges
    }

    private func styleLinks(
        in storage: NSTextStorage,
        excluding excludedRanges: [NSRange],
        textView: NSTextView
    ) {
        let artifactRanges = artifactParser.artifacts(
            in: storage.string,
            noteURL: documentURL,
            libraryURLs: linkableDocumentURLs
        ).map(\.sourceRange)
        let presentation = MarkdownLinkPresentation.parse(
            in: storage.string,
            excluding: excludedRanges + artifactRanges
        )
        for range in presentation.definitionRanges {
            collapseLine(in: storage, range: range)
        }

        var markerRanges: [NSRange] = []
        for link in presentation.links {
            guard let url = resolvedLinkURL(for: link.destination) else { continue }
            for markerRange in link.markerRanges {
                hideMarker(in: storage, range: markerRange)
                markerRanges.append(markerRange)
            }
            storage.addAttributes([
                .link: url,
                .foregroundColor: palette.link,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: link.labelRange)
        }
        (textView as? MarkdownEditorTextView)?.renderedLinkMarkerRanges = markerRanges
    }

    private func resolvedLinkURL(for destination: String) -> URL? {
        let decoded = destination.removingPercentEncoding ?? destination
        if let url = URL(string: destination),
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto"].contains(scheme) {
            return url
        }
        guard let documentURL,
              let url = URL(string: decoded, relativeTo: documentURL) else { return nil }
        return url.absoluteURL
    }

    private func styleBlockQuotes(
        in storage: NSTextStorage,
        font: NSFont,
        excluding excludedRanges: [NSRange],
        textView: NSTextView
    ) {
        guard let markdownTextView = textView as? MarkdownEditorTextView else {
            quoteGlyphLayouts = []
            return
        }
        let source = storage.string as NSString
        let lines = MarkdownBlockQuoteLine.lines(
            in: storage.string,
            excluding: excludedRanges
        )
        var glyphLayouts: [RenderedObjectGlyphLayout] = []
        for line in lines {
            let quoteIndent = CGFloat(line.depth * 16 + 8)
            hideMarker(in: storage, range: line.markerRange)
            storage.addAttribute(
                .font,
                value: font,
                range: NSRange(location: line.markerRange.location, length: 1)
            )
            glyphLayouts.append(.init(
                range: line.markerRange,
                size: NSSize(width: quoteIndent, height: font.pointSize)
            ))

            if line.contentRange.length > 0 {
                storage.addAttributes([
                    .font: typeface.font(ofSize: scaled(17), trait: .italicFontMask),
                    .foregroundColor: palette.secondaryText
                ], range: line.contentRange)
            }

            let paragraph = (
                storage.attribute(
                    .paragraphStyle,
                    at: line.markerRange.location,
                    effectiveRange: nil
                ) as? NSParagraphStyle
            )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = 0
            paragraph.headIndent = quoteIndent
            paragraph.lineSpacing = 2
            paragraph.paragraphSpacing = 3
            if let listMarker = line.listMarker {
                let markerText: String
                switch listMarker {
                case .unordered:
                    markerText = "• "
                case .ordered(let range):
                    markerText = source.substring(with: range)
                }
                paragraph.headIndent += ceil(
                    (markerText as NSString).size(withAttributes: [.font: font]).width
                )
            }
            if line.contentRange.length == 0 {
                let lineHeight = textView.layoutManager?.defaultLineHeight(for: font)
                    ?? (font.ascender - font.descender + font.leading)
                paragraph.minimumLineHeight = lineHeight
                paragraph.maximumLineHeight = lineHeight
                paragraph.lineSpacing = 0
            }
            storage.addAttribute(.paragraphStyle, value: paragraph, range: line.lineRange)
        }
        quoteGlyphLayouts = glyphLayouts
        markdownTextView.renderedBlockQuoteLines = lines.map {
            .init(
                lineRange: $0.lineRange,
                markerRange: $0.markerRange,
                depth: $0.depth
            )
        }
    }

    private func styleLists(
        in storage: NSTextStorage,
        font: NSFont,
        excluding excludedRanges: [NSRange]
    ) {
        let expression = try! NSRegularExpression(
            pattern: #"(?m)^(([ \t]*)(?:[-*+][ \t]+(?:\[[ xX]\][ \t]+)?|\d+\.[ \t]+))"#
        )
        let source = storage.string as NSString
        let range = NSRange(location: 0, length: source.length)
        let matches = expression.matches(in: storage.string, range: range)
        let indentationWidths = matches.map { match in
            indentationColumns(in: source.substring(with: match.range(at: 2)))
        }

        for (match, indentationWidth) in zip(matches, indentationWidths)
        where !intersects(match.range, excludedRanges) {
            let markerRange = match.range(at: 1)
            let indentationRange = match.range(at: 2)
            let markerWithoutIndentation = source.substring(with: NSRange(
                location: NSMaxRange(indentationRange),
                length: NSMaxRange(markerRange) - NSMaxRange(indentationRange)
            ))
            let indentationLevel = indentationWidth == 0
                ? 0
                : (indentationWidth + 3) / 4
            let visualMarker = String(repeating: " ", count: indentationLevel * 4)
                + markerWithoutIndentation
            let paragraphRange = source.lineRange(for: NSRange(
                location: markerRange.location,
                length: 0
            ))
            let paragraph = (
                storage.attribute(.paragraphStyle, at: markerRange.location, effectiveRange: nil)
                    as? NSParagraphStyle
            )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = 0
            paragraph.headIndent = ceil((visualMarker as NSString).size(
                withAttributes: [.font: font]
            ).width)
            paragraph.lineSpacing = 2
            storage.addAttribute(.paragraphStyle, value: paragraph, range: paragraphRange)
        }
    }

    private func styleOrderedLists(
        in storage: NSTextStorage,
        font: NSFont,
        textView: NSTextView,
        excluding excludedRanges: [NSRange]
    ) {
        guard let markdownTextView = textView as? MarkdownEditorTextView else {
            orderedListGlyphLayouts = []
            return
        }
        let items = MarkdownOrderedListItem.items(in: storage.string)
            .filter { !intersects($0.markerRange, excludedRanges) }
        let source = storage.string as NSString
        let trailingGap = ceil((" " as NSString).size(withAttributes: [.font: font]).width)
        var widestLabels: [String: CGFloat] = [:]

        for item in items {
            let key = "\(item.listID):\(item.indentationLevel)"
            let label = item.displayLabel
            widestLabels[key] = max(
                widestLabels[key] ?? 0,
                ceil((label as NSString).size(withAttributes: [.font: font]).width)
            )
        }

        var rendered: [MarkdownEditorTextView.RenderedOrderedList] = []
        var glyphLayouts: [RenderedObjectGlyphLayout] = []
        for item in items {
            let key = "\(item.listID):\(item.indentationLevel)"
            let indentation = String(repeating: " ", count: item.indentationLevel * 4)
            let indentationWidth = ceil(
                (indentation as NSString).size(withAttributes: [.font: font]).width
            )
            let markerSlotWidth = (widestLabels[key] ?? 0) + trailingGap
            let markerWidth = indentationWidth + markerSlotWidth
            let paragraphRange = source.lineRange(for: NSRange(
                location: item.markerRange.location,
                length: 0
            ))
            let paragraph = (
                storage.attribute(
                    .paragraphStyle,
                    at: item.markerRange.location,
                    effectiveRange: nil
                ) as? NSParagraphStyle
            )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = 0
            paragraph.headIndent = markerWidth
            paragraph.lineSpacing = 2
            if item.contentRange.length == 0 {
                let emptyLineHeight = semanticListLineHeight(
                    font: font,
                    paragraph: paragraph,
                    layoutManager: textView.layoutManager
                )
                paragraph.minimumLineHeight = emptyLineHeight
                paragraph.maximumLineHeight = emptyLineHeight
                paragraph.lineSpacing = 0
                paragraph.paragraphSpacing = 0
            }
            storage.addAttribute(.paragraphStyle, value: paragraph, range: paragraphRange)
            hideMarker(in: storage, range: item.markerRange)
            storage.addAttribute(
                .font,
                value: font,
                range: NSRange(location: item.markerRange.location, length: 1)
            )
            rendered.append(.init(
                markerRange: item.markerRange,
                label: item.displayLabel,
                font: font,
                markerSlotWidth: markerSlotWidth,
                trailingGap: trailingGap
            ))
            glyphLayouts.append(.init(
                range: item.markerRange,
                size: NSSize(width: markerWidth, height: font.pointSize)
            ))
        }

        orderedListGlyphLayouts = glyphLayouts
        markdownTextView.renderedOrderedLists = rendered
    }

    private func styleChecklists(
        in storage: NSTextStorage,
        font: NSFont,
        textView: NSTextView,
        excluding excludedRanges: [NSRange]
    ) {
        guard let checklistTextView = textView as? MarkdownEditorTextView else {
            checklistGlyphLayouts = []
            return
        }
        let source = storage.string as NSString
        let items = MarkdownChecklistItem.items(in: storage.string)
        let controlSize = max(14, min(17, ceil(font.pointSize * 0.88)))
        let controlSlotWidth = controlSize + 9
        var rendered: [MarkdownEditorTextView.RenderedChecklist] = []
        var glyphLayouts: [RenderedObjectGlyphLayout] = []

        for item in items where !intersects(item.markerRange, excludedRanges) {
            let indentation = source.substring(with: item.indentationRange)
            let indentationWidth = indentationColumns(in: indentation)
            let indentationLevel = indentationWidth == 0
                ? 0
                : (indentationWidth + 3) / 4
            let visualIndentation = String(repeating: " ", count: indentationLevel * 4)
            let visualIndentationWidth = (visualIndentation as NSString).size(
                withAttributes: [.font: font]
            ).width
            let markerWidth = ceil(visualIndentationWidth + controlSlotWidth)
            let paragraphRange = source.lineRange(for: NSRange(
                location: item.markerRange.location,
                length: 0
            ))
            let paragraph = (
                storage.attribute(
                    .paragraphStyle,
                    at: item.markerRange.location,
                    effectiveRange: nil
                ) as? NSParagraphStyle
            )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = 0
            paragraph.headIndent = markerWidth
            if item.contentRange.length == 0 {
                let emptyLineHeight = semanticListLineHeight(
                    font: font,
                    paragraph: paragraph,
                    layoutManager: textView.layoutManager
                )
                paragraph.minimumLineHeight = emptyLineHeight
                paragraph.maximumLineHeight = emptyLineHeight
                paragraph.lineSpacing = 0
                paragraph.paragraphSpacing = 0
            }
            storage.addAttribute(.paragraphStyle, value: paragraph, range: paragraphRange)
            hideMarker(in: storage, range: item.markerRange)
            storage.addAttribute(
                .font,
                value: font,
                range: NSRange(location: item.markerRange.location, length: 1)
            )
            if item.isChecked, item.contentRange.length > 0 {
                storage.addAttributes([
                    .foregroundColor: palette.secondaryText,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue
                ], range: item.contentRange)
            }
            rendered.append(.init(
                markerRange: item.markerRange,
                stateRange: item.stateRange,
                isChecked: item.isChecked,
                font: font,
                controlSize: controlSize,
                controlSlotWidth: controlSlotWidth
            ))
            glyphLayouts.append(.init(
                range: item.markerRange,
                size: NSSize(width: markerWidth, height: controlSize)
            ))
        }

        checklistGlyphLayouts = glyphLayouts
        checklistTextView.renderedChecklists = rendered
    }

    private func indentationColumns(in indentation: String) -> Int {
        indentation.reduce(into: 0) { columns, character in
            columns += character == "\t" ? 4 - (columns % 4) : 1
        }
    }

    private func semanticListLineHeight(
        font: NSFont,
        paragraph: NSParagraphStyle,
        layoutManager: NSLayoutManager?
    ) -> CGFloat {
        (layoutManager?.defaultLineHeight(for: font)
            ?? (font.ascender - font.descender + font.leading))
            + paragraph.lineSpacing
            + paragraph.paragraphSpacing
    }

    private func styleCodeBlocks(
        _ blocks: [MarkdownCodeBlock],
        in storage: NSTextStorage,
        textView: NSTextView
    ) {
        guard let markdownTextView = textView as? MarkdownEditorTextView else { return }
        let source = storage.string as NSString
        let font = typeface.monospacedFont(ofSize: scaled(15), weight: .regular)
        for block in blocks {
            if let openingRange = block.openingRange {
                collapseLine(in: storage, range: openingRange)
            }
            if let closingRange = block.closingRange {
                collapseLine(in: storage, range: closingRange)
            }
            for indentationRange in block.indentationRanges {
                hideMarker(in: storage, range: indentationRange)
            }
            guard block.contentRange.length > 0 else { continue }
            storage.addAttribute(.font, value: font, range: block.contentRange)
            highlightCode(in: block, storage: storage)
            var location = block.contentRange.location
            while location < NSMaxRange(block.contentRange), location < source.length {
                let lineRange = NSIntersectionRange(
                    source.lineRange(for: NSRange(location: location, length: 0)),
                    block.contentRange
                )
                guard lineRange.length > 0 else { break }
                let paragraph = (
                    storage.attribute(.paragraphStyle, at: location, effectiveRange: nil)
                        as? NSParagraphStyle
                )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                paragraph.firstLineHeadIndent = 12
                paragraph.headIndent = 12
                paragraph.tailIndent = -12
                paragraph.lineSpacing = 2
                paragraph.paragraphSpacing = 0
                storage.addAttribute(.paragraphStyle, value: paragraph, range: lineRange)
                location = NSMaxRange(lineRange)
            }
        }
        markdownTextView.renderedCodeBlocks = blocks.compactMap { block in
            guard block.contentRange.length > 0 else { return nil }
            return .init(sourceRange: block.sourceRange, contentRange: block.contentRange)
        }
    }

    private func highlightCode(in block: MarkdownCodeBlock, storage: NSTextStorage) {
        guard let highlighter = host?.codeHighlighter else { return }
        let source = storage.string as NSString
        let language = block.openingRange.flatMap { range -> String? in
            let info = source.substring(with: range)
                .trimmingCharacters(in: CharacterSet(charactersIn: "`~").union(.whitespacesAndNewlines))
            return info.split(whereSeparator: \.isWhitespace).first.map(String.init)
        }
        let code = source.substring(with: block.contentRange)
        for run in highlighter.colorRuns(forCode: code, language: language) {
            let range = NSRange(location: block.contentRange.location + run.range.location, length: run.range.length)
            guard NSMaxRange(range) <= NSMaxRange(block.contentRange),
                  !intersects(range, block.indentationRanges) else { continue }
            storage.addAttribute(.foregroundColor, value: run.color, range: range)
        }
    }

    private func styleTables(
        in storage: NSTextStorage,
        font: NSFont,
        excluding excludedRanges: [NSRange]
    ) {
        let tables = MarkdownTable.tables(in: storage.string, excluding: excludedRanges)
        tableGlyphLayouts = []
        for table in tables {
            let allRows = [table.header] + table.rows
            storage.addAttribute(
                .font,
                value: typeface.font(ofSize: scaled(17), trait: .boldFontMask),
                range: table.header.lineRange
            )
            for row in allRows {
                for separator in row.separators where separator.length > 0 {
                    hideMarker(in: storage, range: separator)
                    storage.addAttribute(
                        .font,
                        value: font,
                        range: NSRange(location: separator.location, length: 1)
                    )
                }
                let paragraph = (
                    storage.attribute(.paragraphStyle, at: row.lineRange.location, effectiveRange: nil)
                        as? NSParagraphStyle
                )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                paragraph.lineSpacing = 2
                paragraph.paragraphSpacing = 3
                storage.addAttribute(.paragraphStyle, value: paragraph, range: row.lineRange)
            }
            collapseLine(in: storage, range: table.delimiterRange)
            let escapedPipe = try! NSRegularExpression(pattern: #"\\(?=\|)"#)
            for match in escapedPipe.matches(
                in: storage.string,
                range: table.sourceRange
            ) {
                hideMarker(in: storage, range: match.range)
            }
        }
    }

    private func layoutTables(
        in storage: NSTextStorage,
        excluding excludedRanges: [NSRange]
    ) {
        let tables = MarkdownTable.tables(in: storage.string, excluding: excludedRanges)
        var glyphLayouts: [RenderedObjectGlyphLayout] = []
        for table in tables {
            let allRows = [table.header] + table.rows
            var columnWidths = Array(repeating: CGFloat(0), count: table.header.cells.count)
            for row in allRows {
                for (index, cell) in row.cells.enumerated() {
                    columnWidths[index] = max(
                        columnWidths[index],
                        storage.attributedSubstring(from: cell).size().width
                    )
                }
            }

            for row in allRows {
                for (index, separator) in row.separators.enumerated() where separator.length > 0 {
                    let spacerWidth: CGFloat
                    if index == 0 || index > row.cells.count {
                        spacerWidth = 0
                    } else {
                        let cellWidth = storage.attributedSubstring(
                            from: row.cells[index - 1]
                        ).size().width
                        spacerWidth = max(14, columnWidths[index - 1] - cellWidth + 22)
                    }
                    glyphLayouts.append(.init(
                        range: separator,
                        size: NSSize(width: spacerWidth, height: 0)
                    ))
                }
            }
        }
        tableGlyphLayouts = glyphLayouts
    }

    private func styleHorizontalRules(
        in storage: NSTextStorage,
        font: NSFont,
        excluding excludedRanges: [NSRange],
        textView: NSTextView
    ) {
        guard let markdownTextView = textView as? MarkdownEditorTextView else { return }
        let ruleRanges = MarkdownInlineSyntax.thematicBreakRanges(in: storage.string, excluding: excludedRanges)
        for range in ruleRanges {
            hideMarker(in: storage, range: range)
            storage.addAttribute(
                .font,
                value: font,
                range: NSRange(location: range.location, length: 1)
            )
            let paragraph = (
                storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                    as? NSParagraphStyle
            )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            paragraph.minimumLineHeight = max(18, font.pointSize)
            paragraph.maximumLineHeight = max(18, font.pointSize)
            paragraph.paragraphSpacing = 7
            storage.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }
        markdownTextView.renderedHorizontalRules = ruleRanges.map { .init(sourceRange: $0) }
    }

    private func styleFootnotes(
        in storage: NSTextStorage,
        excluding excludedRanges: [NSRange],
        textView: NSTextView
    ) {
        guard let markdownTextView = textView as? MarkdownEditorTextView else {
            footnoteGlyphLayouts = []
            return
        }
        let presentation = MarkdownFootnotePresentation.parse(
            in: storage.string,
            excluding: excludedRanges
        )
        let referenceFont = typeface.font(
            ofSize: scaled(11),
            trait: .boldFontMask
        )
        let definitionNumberFont = typeface.font(
            ofSize: scaled(12),
            trait: .boldFontMask
        )
        let definitionBodyFont = typeface.font(ofSize: scaled(15))
        var glyphLayouts: [RenderedObjectGlyphLayout] = []
        var renderedReferences: [MarkdownEditorTextView.RenderedFootnoteReference] = []
        var renderedDefinitions: [MarkdownEditorTextView.RenderedFootnoteDefinition] = []

        for reference in presentation.references {
            let label = "\(reference.ordinal)"
            let size = (label as NSString).size(withAttributes: [.font: referenceFont])
            hideMarker(in: storage, range: reference.sourceRange)
            let placeholderRange = NSRange(
                location: reference.sourceRange.location,
                length: 1
            )
            storage.addAttribute(.font, value: referenceFont, range: placeholderRange)
            if let location = reference.definitionLocation,
               let url = internalFootnoteURL(location: location) {
                storage.addAttribute(.link, value: url, range: placeholderRange)
            }
            let measured = NSSize(width: ceil(size.width), height: ceil(size.height))
            renderedReferences.append(.init(
                sourceRange: reference.sourceRange,
                displayText: label,
                font: referenceFont,
                size: measured
            ))
            glyphLayouts.append(.init(range: reference.sourceRange, size: measured))
        }

        for (index, definition) in presentation.definitions.enumerated() {
            let label = "\(definition.ordinal)"
            let slotWidth = scaled(24)
            hideMarker(in: storage, range: definition.prefixRange)
            let placeholderRange = NSRange(
                location: definition.prefixRange.location,
                length: 1
            )
            storage.addAttribute(.font, value: definitionNumberFont, range: placeholderRange)
            if let location = definition.referenceLocation,
               let url = internalFootnoteURL(location: location) {
                storage.addAttribute(.link, value: url, range: placeholderRange)
            }
            storage.addAttributes([
                .font: definitionBodyFont,
                .foregroundColor: palette.secondaryText
            ], range: definition.contentRange)
            let paragraph = (
                storage.attribute(
                    .paragraphStyle,
                    at: definition.lineRange.location,
                    effectiveRange: nil
                ) as? NSParagraphStyle
            )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = 0
            paragraph.headIndent = slotWidth
            paragraph.lineSpacing = 2
            paragraph.paragraphSpacing = 4
            paragraph.paragraphSpacingBefore = index == 0 ? scaled(18) : 0
            storage.addAttribute(
                .paragraphStyle,
                value: paragraph,
                range: definition.lineRange
            )
            renderedDefinitions.append(.init(
                prefixRange: definition.prefixRange,
                displayText: label,
                font: definitionNumberFont,
                slotWidth: slotWidth,
                isFirst: index == 0
            ))
            glyphLayouts.append(.init(
                range: definition.prefixRange,
                size: NSSize(width: slotWidth, height: 0)
            ))
        }
        footnoteGlyphLayouts = glyphLayouts
        markdownTextView.renderedFootnoteReferences = renderedReferences
        markdownTextView.renderedFootnoteDefinitions = renderedDefinitions
    }

    private func internalFootnoteURL(location: Int) -> URL? {
        URL(string: "scribl-footnote://jump/\(location)")
    }

    private func styleDefinitionLists(
        in storage: NSTextStorage,
        excluding excludedRanges: [NSRange]
    ) {
        let source = storage.string as NSString
        let markerExpression = try! NSRegularExpression(pattern: #"^(:[ \t]+)([^\r\n]+)$"#)
        var location = 0
        var previousContentRange: NSRange?
        while location < source.length {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            var contentEnd = NSMaxRange(lineRange)
            while contentEnd > lineRange.location,
                  [unichar(10), unichar(13)].contains(source.character(at: contentEnd - 1)) {
                contentEnd -= 1
            }
            let contentRange = NSRange(
                location: lineRange.location,
                length: contentEnd - lineRange.location
            )
            let line = source.substring(with: contentRange)
            let localRange = NSRange(location: 0, length: (line as NSString).length)
            guard let match = markerExpression.firstMatch(in: line, range: localRange),
                  let termRange = previousContentRange,
                  !source.substring(with: termRange).hasPrefix("[^"),
                  !intersects(termRange, excludedRanges),
                  !intersects(contentRange, excludedRanges) else {
                previousContentRange = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : contentRange
                location = NSMaxRange(lineRange)
                continue
            }
            storage.addAttribute(
                .font,
                value: typeface.font(ofSize: scaled(17), trait: .boldFontMask),
                range: termRange
            )
            let markerRange = NSRange(
                location: contentRange.location + match.range(at: 1).location,
                length: match.range(at: 1).length
            )
            let definitionRange = NSRange(
                location: contentRange.location + match.range(at: 2).location,
                length: match.range(at: 2).length
            )
            hideMarker(in: storage, range: markerRange)
            let paragraph = (
                storage.attribute(.paragraphStyle, at: definitionRange.location, effectiveRange: nil)
                    as? NSParagraphStyle
            )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = 20
            paragraph.headIndent = 20
            storage.addAttribute(.paragraphStyle, value: paragraph, range: contentRange)
            previousContentRange = contentRange
            location = NSMaxRange(lineRange)
        }
    }

    @discardableResult
    private func styleMath(
        in storage: NSTextStorage,
        excluding excludedRanges: [NSRange],
        textView: NSTextView
    ) -> [NSRange] {
        guard let markdownTextView = textView as? MarkdownEditorTextView else {
            mathGlyphLayouts = []
            return []
        }
        let fullRange = NSRange(location: 0, length: storage.length)
        let blockExpression = try! NSRegularExpression(
            pattern: #"^\$\$[ \t]*\r?\n(.*?)\r?\n\$\$[ \t]*$"#,
            options: [.anchorsMatchLines, .dotMatchesLineSeparators]
        )
        let blockMatches = blockExpression.matches(in: storage.string, range: fullRange)
            .filter { !intersects($0.range, excludedRanges) }
        let blockRanges = blockMatches.map(\.range)
        let inlineExpression = try! NSRegularExpression(
            pattern: #"(?<!\$)\$([^$\r\n]+)\$(?!\$)"#
        )
        let inlineMatches = inlineExpression.matches(in: storage.string, range: fullRange)
            .filter { !intersects($0.range, excludedRanges + blockRanges) }
        var rendered: [MarkdownEditorTextView.RenderedMath] = []
        var glyphLayouts: [RenderedObjectGlyphLayout] = []

        func add(_ match: NSTextCheckingResult, contentRange: NSRange, isBlock: Bool) {
            let raw = (storage.string as NSString).substring(with: contentRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let display = MarkdownMathDisplay.text(for: raw)
            let font = NSFont(name: "STIX Two Math", size: scaled(isBlock ? 20 : 17))
                ?? NSFont(name: "Times New Roman", size: scaled(isBlock ? 20 : 17))
                ?? NSFont.systemFont(ofSize: scaled(isBlock ? 20 : 17))
            let size = (display as NSString).size(withAttributes: [.font: font])
            hideMarker(in: storage, range: match.range)
            storage.addAttribute(
                .font,
                value: imageLayoutFont(for: max(size.height, font.pointSize) + (isBlock ? 12 : 0)),
                range: NSRange(location: match.range.location, length: 1)
            )
            if isBlock {
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                paragraph.paragraphSpacing = 7
                storage.addAttribute(.paragraphStyle, value: paragraph, range: match.range)
            }
            let measured = NSSize(width: ceil(size.width), height: ceil(size.height))
            rendered.append(.init(
                sourceRange: match.range,
                displayText: display,
                font: font,
                size: measured,
                isBlock: isBlock
            ))
            glyphLayouts.append(.init(range: match.range, size: measured))
        }

        for match in blockMatches { add(match, contentRange: match.range(at: 1), isBlock: true) }
        for match in inlineMatches { add(match, contentRange: match.range(at: 1), isBlock: false) }
        mathGlyphLayouts = glyphLayouts.sorted { $0.range.location < $1.range.location }
        markdownTextView.renderedMath = rendered.sorted {
            $0.sourceRange.location < $1.sourceRange.location
        }
        return blockRanges + inlineMatches.map(\.range)
    }

    @discardableResult
    private func styleHTML(
        _ detailsBlocks: [MarkdownDetailsBlock],
        in storage: NSTextStorage,
        excluding excludedRanges: [NSRange],
        textView: NSTextView
    ) -> [NSRange] {
        guard let markdownTextView = textView as? MarkdownEditorTextView else {
            keycapGlyphLayouts = []
            return []
        }
        let fullRange = NSRange(location: 0, length: storage.length)
        let source = storage.string as NSString
        var protectedRanges: [NSRange] = []
        var renderedDetails: [MarkdownEditorTextView.RenderedDetails] = []

        func standaloneLineOrTagRange(_ tagRange: NSRange) -> NSRange {
            let lineRange = source.lineRange(for: tagRange)
            let line = source.substring(with: lineRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return line == source.substring(with: tagRange) ? lineRange : tagRange
        }

        for details in detailsBlocks {
            let openingRange = standaloneLineOrTagRange(details.openingTagRange)
            let closingRange = standaloneLineOrTagRange(details.closingTagRange)
            if openingRange == details.openingTagRange {
                hideMarker(in: storage, range: openingRange)
            } else {
                collapseLine(in: storage, range: openingRange)
            }
            hideMarker(in: storage, range: details.summaryOpeningRange)
            hideMarker(in: storage, range: details.summaryClosingRange)
            if closingRange == details.closingTagRange {
                hideMarker(in: storage, range: closingRange)
            } else {
                collapseLine(in: storage, range: closingRange)
            }
            storage.addAttribute(
                .font,
                value: typeface.font(ofSize: scaled(17), trait: .boldFontMask),
                range: details.summaryContentRange
            )
            let summaryLine = source.lineRange(for: details.summaryContentRange)
            let paragraph = (
                storage.attribute(
                    .paragraphStyle,
                    at: details.summaryContentRange.location,
                    effectiveRange: nil
                ) as? NSParagraphStyle
            )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = scaled(22)
            paragraph.headIndent = scaled(22)
            paragraph.paragraphSpacing = details.isExpanded ? 5 : 9
            storage.addAttribute(.paragraphStyle, value: paragraph, range: summaryLine)

            if !details.isExpanded, details.bodyRange.length > 0 {
                var location = details.bodyRange.location
                while location < NSMaxRange(details.bodyRange) {
                    let fullLineRange = source.lineRange(
                        for: NSRange(location: location, length: 0)
                    )
                    let bodyLineRange = NSIntersectionRange(
                        fullLineRange,
                        details.bodyRange
                    )
                    guard bodyLineRange.length > 0 else { break }
                    let collapseRange = NSIntersectionRange(
                        fullLineRange,
                        details.closingTagRange
                    ).length == 0 ? fullLineRange : bodyLineRange
                    collapseLine(in: storage, range: collapseRange)
                    location = min(
                        NSMaxRange(details.bodyRange),
                        NSMaxRange(fullLineRange)
                    )
                }
            }
            let markerRanges = [
                openingRange,
                details.summaryOpeningRange,
                details.summaryClosingRange,
                closingRange
            ]
            renderedDetails.append(.init(
                openingTagRange: details.openingTagRange,
                summaryContentRange: details.summaryContentRange,
                markerRanges: markerRanges,
                bodyRange: details.bodyRange,
                isExpanded: details.isExpanded
            ))
            protectedRanges.append(contentsOf: markerRanges)
            if !details.isExpanded { protectedRanges.append(details.bodyRange) }
        }
        markdownTextView.renderedDetails = renderedDetails

        let comments = try! NSRegularExpression(
            pattern: #"<!--.*?-->"#,
            options: .dotMatchesLineSeparators
        )
        for match in comments.matches(in: storage.string, range: fullRange)
        where !intersects(match.range, excludedRanges + protectedRanges) {
            let lineRange = source.lineRange(for: match.range)
            if source.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
                == source.substring(with: match.range) {
                collapseLine(in: storage, range: lineRange)
                protectedRanges.append(lineRange)
            } else {
                hideMarker(in: storage, range: match.range)
                protectedRanges.append(match.range)
            }
        }

        let kbd = try! NSRegularExpression(
            pattern: #"<kbd>([^\r\n]*?)</kbd>"#,
            options: .caseInsensitive
        )
        var renderedKeycaps: [MarkdownEditorTextView.RenderedKeycap] = []
        var glyphLayouts: [RenderedObjectGlyphLayout] = []
        for match in kbd.matches(in: storage.string, range: fullRange)
        where !intersects(match.range, excludedRanges + protectedRanges) {
            let displayText = source.substring(with: match.range(at: 1))
            let font = typeface.monospacedFont(ofSize: scaled(13), weight: .medium)
            let textSize = (displayText as NSString).size(withAttributes: [.font: font])
            let size = NSSize(
                width: ceil(textSize.width + scaled(12)),
                height: ceil(max(scaled(22), textSize.height + scaled(4)))
            )
            hideMarker(in: storage, range: match.range)
            storage.addAttribute(
                .font,
                value: imageLayoutFont(for: size.height + 2),
                range: NSRange(location: match.range.location, length: 1)
            )
            renderedKeycaps.append(.init(
                sourceRange: match.range,
                displayText: displayText,
                font: font,
                size: size
            ))
            glyphLayouts.append(.init(range: match.range, size: size))
            protectedRanges.append(match.range)
        }
        keycapGlyphLayouts = glyphLayouts
        markdownTextView.renderedKeycaps = renderedKeycaps

        let tags = try! NSRegularExpression(
            pattern: #"</?[A-Za-z][^>\r\n]*>"#
        )
        for match in tags.matches(in: storage.string, range: fullRange)
        where !intersects(match.range, excludedRanges + detailsBlocks.map(\.sourceRange)) {
            let lineRange = source.lineRange(for: match.range)
            if source.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
                == source.substring(with: match.range) {
                collapseLine(in: storage, range: lineRange)
                protectedRanges.append(lineRange)
            } else {
                hideMarker(in: storage, range: match.range)
                protectedRanges.append(match.range)
            }
        }
        return protectedRanges
    }

    private func collapseLine(in storage: NSTextStorage, range: NSRange) {
        guard range.length > 0 else { return }
        hideMarker(in: storage, range: range)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 0.1
        paragraph.maximumLineHeight = 0.1
        paragraph.lineSpacing = 0
        paragraph.paragraphSpacing = 0
        storage.addAttribute(.paragraphStyle, value: paragraph, range: range)
    }

    private func intersects(_ range: NSRange, _ excludedRanges: [NSRange]) -> Bool {
        excludedRanges.contains { NSIntersectionRange(range, $0).length > 0 }
    }

    private func styleImages(
        in storage: NSTextStorage,
        textView: NSTextView,
        excluding excludedRanges: [NSRange]
    ) {
        guard let imageTextView = textView as? MarkdownEditorTextView else {
            imageGlyphLayouts = []
            return
        }
        guard let documentURL else {
            imageGlyphLayouts = []
            imageTextView.renderedImages = []
            return
        }
        let references = MarkdownImageReference.references(in: storage.string)
        let maximumWidth = max(120, min(680, textView.bounds.width - 32))
        var rendered: [MarkdownEditorTextView.RenderedImage] = []
        var glyphLayouts: [RenderedObjectGlyphLayout] = []

        for reference in references where !intersects(reference.range, excludedRanges) {
            guard let url = reference.fileURL(relativeTo: documentURL),
                  let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { continue }
            let scale = min(1, maximumWidth / image.size.width, 520 / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            hideMarker(in: storage, range: reference.range)
            storage.addAttribute(
                .font,
                value: imageLayoutFont(for: size.height + 12),
                range: NSRange(location: reference.range.location, length: 1)
            )
            rendered.append(.init(range: reference.range, url: url, image: image, size: size))
            glyphLayouts.append(.init(range: reference.range, size: size))
        }
        imageGlyphLayouts = glyphLayouts
        imageTextView.renderedImages = rendered
    }

    private func imageLayoutFont(for desiredLineHeight: CGFloat) -> NSFont {
        let probeSize: CGFloat = 100
        let probe = NSFont.systemFont(ofSize: probeSize)
        let lineHeightRatio = max(0.1, (probe.ascender - probe.descender + probe.leading) / probeSize)
        return NSFont.systemFont(ofSize: desiredLineHeight / lineHeightRatio)
    }

    private func styleArtifacts(
        in storage: NSTextStorage,
        textView: NSTextView,
        excluding excludedRanges: [NSRange]
    ) {
        guard let artifactTextView = textView as? MarkdownEditorTextView else {
            artifactGlyphLayouts = []
            return
        }
        let artifacts = artifactParser.artifacts(
            in: storage.string,
            noteURL: documentURL,
            libraryURLs: linkableDocumentURLs
        ).filter { !intersects($0.sourceRange, excludedRanges) }
        let visibleWebURLs = Set(artifacts.compactMap { artifact -> URL? in
            guard case .web(let url) = artifact.kind else { return nil }
            return url
        })
        for (url, task) in metadataTasks where !visibleWebURLs.contains(url) {
            task.cancel()
            metadataTasks[url] = nil
        }
        var rendered: [MarkdownEditorTextView.RenderedArtifact] = []
        var glyphLayouts: [RenderedObjectGlyphLayout] = []
        let availableWidth = max(
            180,
            min(300, textView.bounds.width - textView.textContainerInset.width * 2 - 4)
        )
        for artifact in artifacts {
            hideMarker(in: storage, range: artifact.sourceRange)
            let content: ArtifactCardContent
            switch artifact.kind {
            case .web(let url):
                loadMetadataIfNeeded(for: url, textView: artifactTextView)
                content = webMetadata[url].map(ArtifactCardContent.web) ?? .loading(url: url)
            case .note(let reference):
                content = documentCardContent(for: reference)
            }
            let height = content.preferredHeight
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = height + 10
            paragraph.maximumLineHeight = height + 10
            storage.addAttribute(.paragraphStyle, value: paragraph, range: artifact.sourceRange)
            storage.addAttribute(
                .font,
                value: imageLayoutFont(for: height + 10),
                range: NSRange(location: artifact.sourceRange.location, length: 1)
            )
            rendered.append(.init(artifact: artifact, content: content, height: height))
            glyphLayouts.append(.init(
                range: artifact.sourceRange,
                size: NSSize(width: availableWidth + 8, height: height)
            ))
        }
        artifactGlyphLayouts = glyphLayouts
        artifactTextView.renderedArtifacts = rendered
    }

    private func documentCardContent(for reference: MarkdownNoteReference) -> ArtifactCardContent {
        let resolved: MarkdownLinkedDocument?
        if case .resolved(let url) = reference.state {
            resolved = host?.linkedDocument(at: url)
        } else {
            resolved = nil
        }
        let fallbackPreview = reference.state == .selfLink
            ? "This note cannot link to itself."
            : reference.destination
        return .document(
            resolved ?? MarkdownLinkedDocument(
                title: reference.title,
                preview: fallbackPreview,
                kindLabel: "Note",
                image: NSImage(systemSymbolName: "note.text", accessibilityDescription: nil)
            ),
            isBroken: resolved == nil
        )
    }

    private func linkedDocumentURL(matching url: URL) -> URL? {
        let target = url.standardizedFileURL
        return linkableDocumentURLs.first { $0.standardizedFileURL == target }
    }

    private func loadMetadataIfNeeded(for url: URL, textView: MarkdownEditorTextView) {
        guard webMetadata[url] == nil, metadataTasks[url] == nil else { return }
        guard let provider = host?.webLinkMetadataProvider else {
            webMetadata[url] = .fallback(for: url)
            return
        }
        let textViewBox = WeakArtifactTextView(textView)
        metadataTasks[url] = Task { [weak self] in
            let metadata = await provider.metadata(for: url)
            guard let self else { return }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.webMetadata[url] = metadata
                self.metadataTasks[url] = nil
                guard let textView = textViewBox.value else { return }
                self.refreshRenderedArtifacts(in: textView)
            }
        }
    }

    private func refreshRenderedArtifacts(in textView: MarkdownEditorTextView) {
        applyPresentation(to: textView)
        refreshPresentationLayout(in: textView)
    }

    func importImages(
        at urls: [URL],
        pastedImage: PasteboardImagePayload?,
        range: NSRange,
        into textView: NSTextView
    ) -> Bool {
        guard let documentURL else { return false }
        do {
            let store = MarkdownImageAssetStore()
            var references = try urls.compactMap { try store.importFile(at: $0, for: documentURL) }
            if let pastedImage {
                references.append(try store.importPastedImage(pastedImage, for: documentURL))
            }
            guard !references.isEmpty else { return false }
            let insertion = MarkdownImageAssetStore.insertion(
                markdown: references,
                in: textView.string,
                at: range.location
            )
            textView.insertText(insertion, replacementRange: range)
            return true
        } catch {
            NSSound.beep()
            return false
        }
    }

    func insertWebURLs(_ urls: [URL], at range: NSRange, into textView: NSTextView) -> Bool {
        let valid = urls.filter { url in
            guard let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  url.host?.isEmpty == false,
                  url.user == nil,
                  url.password == nil else { return false }
            return true
        }
        guard !valid.isEmpty else { return false }
        guard let insertion = MarkdownArtifactInsertion.insertion(
            valid.map(\.absoluteString),
            in: textView.string,
            near: range.location
        ) else { return false }
        let insertionRange = NSRange(location: insertion.location, length: 0)
        textView.setSelectedRange(insertionRange)
        textView.insertText(insertion.text, replacementRange: insertionRange)
        return true
    }

    func insertNotePayload(
        _ payload: MarkdownDocumentDragPayload,
        at range: NSRange,
        into textView: NSTextView
    ) -> Bool {
        guard let documentURL,
              artifactParser.linkableDocumentExtensions.contains(payload.fileURL.pathExtension.lowercased()),
              let markdown = MarkdownNoteLink.markdown(
                title: payload.title,
                targetURL: payload.fileURL,
                from: documentURL
              ) else {
            NSSound.beep()
            return false
        }
        guard let insertion = MarkdownArtifactInsertion.insertion(
            [markdown],
            in: textView.string,
            near: range.location
        ) else { return false }
        let insertionRange = NSRange(location: insertion.location, length: 0)
        textView.setSelectedRange(insertionRange)
        textView.insertText(insertion.text, replacementRange: insertionRange)
        return true
    }

    func reorderArtifact(
        _ payload: ArtifactReorderDragPayload,
        to destination: Int,
        in textView: NSTextView
    ) -> Bool {
        let artifacts = artifactParser.artifacts(
            in: textView.string,
            noteURL: documentURL,
            libraryURLs: linkableDocumentURLs
        )
        guard let artifact = artifacts.first(where: {
            $0.blockRange == payload.range && $0.source == payload.source
        }),
              let reordered = MarkdownArtifactReorder.move(
                block: artifact.blockRange,
                to: destination,
                in: textView.string
              ) else { return false }
        return applyReorder(
            reordered,
            moving: artifact.blockRange,
            to: destination,
            in: textView
        )
    }

    func reorderImage(
        _ payload: MarkdownImageReorderPayload,
        to destination: Int,
        in textView: NSTextView
    ) -> Bool {
        guard let reordered = MarkdownImageEditing.move(
            payload: payload,
            to: destination,
            in: textView.string
        ) else { return false }
        return applyReorder(
            reordered.markdown,
            moving: payload.range,
            to: destination,
            in: textView
        )
    }

    private func applyReorder(
        _ reordered: String,
        moving sourceRange: NSRange,
        to destination: Int,
        in textView: NSTextView
    ) -> Bool {
        let original = textView.string as NSString
        let reorderedSource = reordered as NSString
        let sourceEnd = NSMaxRange(sourceRange)
        guard sourceRange.location >= 0,
              sourceRange.length > 0,
              sourceEnd <= original.length,
              destination >= 0,
              destination <= original.length,
              reorderedSource.length == original.length,
              let textStorage = textView.textStorage else { return false }

        let changeStart = min(sourceRange.location, destination)
        let changeEnd = max(sourceEnd, destination)
        let changeRange = NSRange(location: changeStart, length: changeEnd - changeStart)
        guard changeRange.length > 0,
              NSMaxRange(changeRange) <= reorderedSource.length else { return false }

        let replacement = reorderedSource.substring(with: changeRange)
        let adjustedDestination = destination > sourceEnd
            ? destination - sourceRange.length
            : destination
        let selection = mappedSelection(
            textView.selectedRange(),
            moving: sourceRange,
            to: adjustedDestination,
            originalDestination: destination,
            textLength: original.length
        )

        guard textView.shouldChangeText(in: changeRange, replacementString: replacement) else {
            return false
        }
        textStorage.replaceCharacters(in: changeRange, with: replacement)
        textView.setSelectedRange(selection)
        textView.didChangeText()
        return true
    }

    private func mappedSelection(
        _ selection: NSRange,
        moving sourceRange: NSRange,
        to adjustedDestination: Int,
        originalDestination: Int,
        textLength: Int
    ) -> NSRange {
        let sourceEnd = NSMaxRange(sourceRange)
        if selection.length > 0,
           NSIntersectionRange(selection, sourceRange).length > 0 {
            return NSRange(location: adjustedDestination, length: sourceRange.length)
        }
        if selection.length == 0,
           selection.location >= sourceRange.location,
           selection.location < sourceEnd {
            return NSRange(
                location: adjustedDestination + selection.location - sourceRange.location,
                length: 0
            )
        }

        func map(_ location: Int) -> Int {
            if originalDestination < sourceRange.location,
               location >= originalDestination,
               location < sourceRange.location {
                return location + sourceRange.length
            }
            if originalDestination > sourceEnd,
               location >= sourceEnd,
               location < originalDestination {
                return location - sourceRange.length
            }
            return location
        }

        let start = min(max(0, map(selection.location)), textLength)
        let end = min(max(start, map(NSMaxRange(selection))), textLength)
        return NSRange(location: start, length: end - start)
    }

    func activate(_ artifact: MarkdownArtifact) {
        switch artifact.kind {
        case .web(let url):
            NSWorkspace.shared.open(url)
        case .note(let reference):
            guard case .resolved(let url) = reference.state,
                  host?.openLinkedDocument(at: url) == true else {
                NSSound.beep()
                return
            }
        }
    }

    private func updateBulletCharacterIndexes(in string: String) {
        guard presentation == .styled else {
            bulletCharacterIndexes = []
            return
        }

        let range = NSRange(location: 0, length: (string as NSString).length)
        let patterns = [
            #"(?m)^\s*(-)(?=\s+)"#,
            #"(?m)^[ \t]*(?:>[ \t]*)+[ \t]*(-)(?=[ \t]+)"#
        ]
        bulletCharacterIndexes = Set(patterns.flatMap { pattern in
            let regex = try! NSRegularExpression(pattern: pattern)
            return regex.matches(in: string, range: range)
                .map { $0.range(at: 1).location }
        })
    }

    private func updateSoftBreakCharacterIndexes(
        in string: String,
        excluding excludedRanges: [NSRange]
    ) {
        softBreakCharacterIndexes = MarkdownSoftBreaks.characterIndexes(
            in: string,
            excluding: excludedRanges
        )
    }

    public func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes: UnsafePointer<Int>,
        font: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        let objectGlyphLayouts = imageGlyphLayouts
            + artifactGlyphLayouts
            + checklistGlyphLayouts
            + orderedListGlyphLayouts
            + tableGlyphLayouts
            + mathGlyphLayouts
            + quoteGlyphLayouts
            + inlineReplacementGlyphLayouts
            + keycapGlyphLayouts
            + footnoteGlyphLayouts
        guard !bulletCharacterIndexes.isEmpty || !objectGlyphLayouts.isEmpty else { return 0 }

        var replacementGlyphs = Array(
            UnsafeBufferPointer(start: glyphs, count: glyphRange.length)
        )
        var replacementProperties = Array(
            UnsafeBufferPointer(start: properties, count: glyphRange.length)
        )
        let bulletGlyph = font.glyph(withName: "bullet")

        var replacedGlyph = false
        for index in replacementGlyphs.indices {
            let characterIndex = characterIndexes[index]
            if let objectLayout = objectGlyphLayouts.first(where: {
                NSLocationInRange(characterIndex, $0.range)
            }) {
                replacementGlyphs[index] = 0
                replacementProperties[index] = characterIndex == objectLayout.range.location
                    ? .controlCharacter
                    : .null
                replacedGlyph = true
            } else if bulletGlyph != 0,
                      bulletCharacterIndexes.contains(characterIndex) {
                replacementGlyphs[index] = CGGlyph(truncatingIfNeeded: bulletGlyph)
                replacedGlyph = true
            }
        }
        guard replacedGlyph else { return 0 }

        replacementGlyphs.withUnsafeBufferPointer { buffer in
            replacementProperties.withUnsafeBufferPointer { propertyBuffer in
                guard let baseAddress = buffer.baseAddress,
                      let propertyAddress = propertyBuffer.baseAddress else { return }
                layoutManager.setGlyphs(
                    baseAddress,
                    properties: propertyAddress,
                    characterIndexes: characterIndexes,
                    font: font,
                    forGlyphRange: glyphRange
                )
            }
        }
        return glyphRange.length
    }

    public func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldUse action: NSLayoutManager.ControlCharacterAction,
        forControlCharacterAt charIndex: Int
    ) -> NSLayoutManager.ControlCharacterAction {
        if softBreakCharacterIndexes.contains(charIndex) {
            return .whitespace
        }
        return (
            imageGlyphLayouts + artifactGlyphLayouts + checklistGlyphLayouts
                + orderedListGlyphLayouts + tableGlyphLayouts + mathGlyphLayouts
                + quoteGlyphLayouts + inlineReplacementGlyphLayouts
                + keycapGlyphLayouts + footnoteGlyphLayouts
        ).contains(where: {
            $0.range.location == charIndex
        })
            ? .whitespace
            : action
    }

    public func layoutManager(
        _ layoutManager: NSLayoutManager,
        boundingBoxForControlGlyphAt glyphIndex: Int,
        for textContainer: NSTextContainer,
        proposedLineFragment proposedRect: NSRect,
        glyphPosition: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        if softBreakCharacterIndexes.contains(charIndex) {
            let font = layoutManager.textStorage?.attribute(
                .font,
                at: charIndex,
                effectiveRange: nil
            ) as? NSFont ?? typeface.font(ofSize: scaled(17))
            let width = (" " as NSString).size(withAttributes: [.font: font]).width
            return NSRect(
                x: glyphPosition.x,
                y: proposedRect.minY,
                width: width,
                height: proposedRect.height
            )
        }
        guard let objectLayout = (
            imageGlyphLayouts + artifactGlyphLayouts + checklistGlyphLayouts
                + orderedListGlyphLayouts + tableGlyphLayouts + mathGlyphLayouts
                + quoteGlyphLayouts + inlineReplacementGlyphLayouts
                + keycapGlyphLayouts + footnoteGlyphLayouts
        ).first(where: {
            $0.range.location == charIndex
        }) else { return .zero }
        return NSRect(
            x: glyphPosition.x,
            y: proposedRect.minY,
            width: objectLayout.size.width,
            height: proposedRect.height
        )
    }

    public func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldBreakLineByWordBeforeCharacterAt charIndex: Int
    ) -> Bool {
        !(
            imageGlyphLayouts + artifactGlyphLayouts + checklistGlyphLayouts
                + orderedListGlyphLayouts + tableGlyphLayouts + mathGlyphLayouts
                + quoteGlyphLayouts + inlineReplacementGlyphLayouts
                + keycapGlyphLayouts + footnoteGlyphLayouts
        ).contains(where: {
            charIndex > $0.range.location && charIndex < NSMaxRange($0.range)
        })
    }

    func setChecklistState(
        _ checked: Bool,
        stateRange: NSRange,
        in textView: NSTextView
    ) {
        guard stateRange.length == 1,
              NSMaxRange(stateRange) <= (textView.string as NSString).length else { return }
        let selection = textView.selectedRange()
        textView.insertText(checked ? "x" : " ", replacementRange: stateRange)
        if NSMaxRange(selection) <= (textView.string as NSString).length {
            textView.setSelectedRange(selection)
        }
    }

    func setDetailsExpanded(
        _ expanded: Bool,
        openingTagRange: NSRange,
        in textView: NSTextView
    ) {
        let source = textView.string as NSString
        guard openingTagRange.length > 0,
              NSMaxRange(openingTagRange) <= source.length else { return }
        let openingTag = source.substring(with: openingTagRange)
        let openAttribute = try! NSRegularExpression(
            pattern: #"\s+open(?:\s*=\s*(?:\"[^\"]*\"|'[^']*'|[^\s>]+))?"#,
            options: .caseInsensitive
        )
        let fullRange = NSRange(
            location: 0,
            length: (openingTag as NSString).length
        )
        let hasOpenAttribute = openAttribute.firstMatch(
            in: openingTag,
            range: fullRange
        ) != nil
        guard expanded != hasOpenAttribute else { return }

        let replacement: String
        if expanded, let closing = openingTag.lastIndex(of: ">") {
            replacement = String(openingTag[..<closing])
                + " open"
                + String(openingTag[closing...])
        } else {
            replacement = openAttribute.stringByReplacingMatches(
                in: openingTag,
                range: fullRange,
                withTemplate: ""
            )
        }
        textView.insertText(replacement, replacementRange: openingTagRange)
    }

    private func handleListMarkerDeletion(
        in textView: NSTextView,
        forward: Bool
    ) -> Bool {
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }

        let source = textView.string as NSString
        let cursorLocation = min(selection.location, source.length)
        let lineRange = source.lineRange(for: NSRange(location: cursorLocation, length: 0))
        let line = source.substring(with: lineRange)
        let expression = try! NSRegularExpression(
            pattern: #"^([ \t]*)(?:(?:[-*+][ \t]+(?:\[[ xX]\][ \t]+)?)|(?:\d+\.[ \t]+))"#
        )
        guard let match = expression.firstMatch(
            in: line,
            range: NSRange(location: 0, length: (line as NSString).length)
        ) else { return false }

        let markerRange = NSRange(
            location: lineRange.location + match.range.location,
            length: match.range.length
        )
        let isAtMarkerBoundary = forward
            ? selection.location == markerRange.location
            : selection.location == NSMaxRange(markerRange)
        guard isAtMarkerBoundary else { return false }

        if !forward, match.range(at: 1).length > 0 {
            return adjustListIndent(in: textView, outdent: true)
        }

        textView.insertText("", replacementRange: markerRange)
        textView.setSelectedRange(NSRange(location: markerRange.location, length: 0))
        return true
    }

    private func normalizeOrderedListNumbers(in textView: NSTextView) {
        let edits = MarkdownOrderedListItem.items(in: textView.string).compactMap { item in
            item.rawNumber == item.displayNumber
                ? nil
                : (range: item.numberRange, replacement: "\(item.displayNumber)")
        }
        guard !edits.isEmpty else { return }

        let selection = textView.selectedRange()
        for edit in edits.reversed() {
            textView.insertText(edit.replacement, replacementRange: edit.range)
        }

        func mappedLocation(_ location: Int, preferReplacementEnd: Bool) -> Int {
            var delta = 0
            for edit in edits {
                let editEnd = NSMaxRange(edit.range)
                let replacementLength = (edit.replacement as NSString).length
                if location < edit.range.location { break }
                if location == edit.range.location {
                    return edit.range.location + delta
                        + (preferReplacementEnd ? replacementLength : 0)
                }
                if location <= editEnd {
                    return edit.range.location + delta + replacementLength
                }
                delta += replacementLength - edit.range.length
            }
            return location + delta
        }

        let start = mappedLocation(selection.location, preferReplacementEnd: false)
        let end = mappedLocation(
            NSMaxRange(selection),
            preferReplacementEnd: selection.length > 0
        )
        textView.setSelectedRange(NSRange(location: start, length: max(0, end - start)))
    }

    private func styleSource(in storage: NSTextStorage) {
        applySourceStyle(
            pattern: #"(?m)^#{1,6}(?:\s+.*)?$"#,
            color: .systemPurple,
            trait: .boldFontMask,
            in: storage
        )
        applySourceStyle(
            pattern: #"\*\*[^*\n]+\*\*|__[^_\n]+__"#,
            color: .systemBlue,
            trait: .boldFontMask,
            in: storage
        )
        applySourceStyle(
            pattern: #"(?<!\*)\*[^*\n]+\*(?!\*)|(?<!_)_[^_\n]+_(?!_)"#,
            color: .systemPink,
            trait: .italicFontMask,
            in: storage
        )
        applySourceStyle(
            pattern: #"(?m)^>\s+.*$"#,
            color: .systemGreen,
            in: storage
        )
        applySourceStyle(
            pattern: #"(?m)^\s*(?:[-*+]\s+(?:\[[ xX]\]\s+)?|\d+\.\s+)"#,
            color: .systemTeal,
            trait: .boldFontMask,
            in: storage
        )
        applySourceStyle(
            pattern: #"!?\[[^\]\n]+\]\([^)\n]+\)"#,
            color: .systemBlue,
            in: storage
        )
        applySourceStyle(
            pattern: #"`[^`\n]+`"#,
            color: .systemOrange,
            in: storage
        )
        applySourceStyle(
            pattern: #"```[^\n]*\n.*?(?:\n```|\z)"#,
            color: .systemOrange,
            backgroundColor: palette.quaternaryText.withAlphaComponent(0.22),
            in: storage,
            options: .dotMatchesLineSeparators
        )
    }

    private func applySourceStyle(
        pattern: String,
        color: NSColor,
        backgroundColor: NSColor? = nil,
        trait: NSFontTraitMask? = nil,
        in storage: NSTextStorage,
        options: NSRegularExpression.Options = []
    ) {
        let regex = try! NSRegularExpression(pattern: pattern, options: options)
        let range = NSRange(location: 0, length: storage.length)
        regex.enumerateMatches(in: storage.string, range: range) { match, _, _ in
            guard let match else { return }
            storage.addAttribute(.foregroundColor, value: color, range: match.range)
            if let backgroundColor {
                storage.addAttribute(.backgroundColor, value: backgroundColor, range: match.range)
            }
            if let trait {
                let baseFont = typeface.monospacedFont(
                    ofSize: scaled(15),
                    weight: trait == .boldFontMask ? .semibold : .regular
                )
                let font = NSFontManager.shared.convert(baseFont, toHaveTrait: trait)
                storage.addAttribute(.font, value: font, range: match.range)
            }
        }
    }

    private func hideMarker(in storage: NSTextStorage, range: NSRange) {
        storage.addAttributes([
            .font: NSFont.systemFont(ofSize: 0.1),
            .foregroundColor: NSColor.clear,
            .backgroundColor: NSColor.clear
        ], range: range)
    }

    private func scaled(_ baseSize: CGFloat) -> CGFloat {
        style.scaled(baseSize)
    }

    private func wrapSelection(prefix: String, suffix: String, in textView: NSTextView) {
        let range = inlineFormattingRange(in: textView)
        let selectedText = (textView.string as NSString).substring(with: range)
        let replacement = prefix + selectedText + suffix
        textView.insertText(replacement, replacementRange: range)

        let prefixLength = (prefix as NSString).length
        if range.length == 0 {
            textView.setSelectedRange(NSRange(location: range.location + prefixLength, length: 0))
        } else {
            textView.setSelectedRange(NSRange(location: range.location + prefixLength, length: range.length))
        }
    }

    private func inlineFormattingRange(in textView: NSTextView) -> NSRange {
        let selection = textView.selectedRange()
        guard selection.length > 0 else { return selection }

        let source = textView.string as NSString
        let selectionEnd = NSMaxRange(selection)
        let lineRange = source.lineRange(for: NSRange(
            location: min(selection.location, source.length),
            length: 0
        ))
        guard selectionEnd <= NSMaxRange(lineRange) else { return selection }

        let rawLine = source.substring(with: lineRange) as NSString
        let newlineLength = rawLine.hasSuffix("\r\n")
            ? 2
            : (rawLine.hasSuffix("\n") || rawLine.hasSuffix("\r") ? 1 : 0)
        let contentEnd = NSMaxRange(lineRange) - newlineLength
        let expression = try! NSRegularExpression(
            pattern: #"^[ \t]*(?:(?:[-*+]|\d+\.)[ \t]+(?:\[[ xX]\][ \t]+)?|#{1,6}[ \t]+|>[ \t]+)"#
        )
        guard let marker = expression.firstMatch(
            in: rawLine as String,
            range: NSRange(location: 0, length: rawLine.length - newlineLength)
        ) else { return selection }

        let markerEnd = lineRange.location + NSMaxRange(marker.range)
        let adjustedStart = max(selection.location, markerEnd)
        let adjustedEnd = min(selectionEnd, contentEnd)
        guard adjustedStart < adjustedEnd else { return selection }
        return NSRange(location: adjustedStart, length: adjustedEnd - adjustedStart)
    }

    private func applyTitleStyle(to textView: NSTextView) {
        if insertPrefixOnEmptyLine("# ", in: textView) { return }
        applyLineStyle("# ", to: textView)
    }

    private func applyLineStyle(_ prefix: String?, to textView: NSTextView) {
        replaceSelectedLines(in: textView) { line in
            let stripped = line.replacingOccurrences(
                of: #"^#{1,6}\s*"#,
                with: "",
                options: .regularExpression
            )
            guard !stripped.isEmpty, let prefix else { return stripped }
            return prefix + stripped
        }
    }

    private func applyListStyle(to textView: NSTextView) {
        if insertPrefixOnEmptyLine("- ", in: textView) { return }

        replaceSelectedLines(in: textView) { line in
            let stripped = line.replacingOccurrences(
                of: #"^\s*([-*+]\s+|\d+\.\s+)"#,
                with: "",
                options: .regularExpression
            )
            return stripped.isEmpty ? stripped : "- " + stripped
        }
    }

    private func adjustListIndent(in textView: NSTextView, outdent: Bool) -> Bool {
        let indentationWidth = 4
        let string = textView.string as NSString
        let selection = textView.selectedRange()
        let selectionStart = min(selection.location, string.length)
        let selectionEnd = min(NSMaxRange(selection), string.length)
        let finalSelectedCharacter = selection.length > 0
            ? max(selectionStart, selectionEnd - 1)
            : selectionStart
        let firstLineRange = string.lineRange(for: NSRange(location: selectionStart, length: 0))
        let lastLineRange = string.lineRange(
            for: NSRange(location: finalSelectedCharacter, length: 0)
        )
        let selectedLinesRange = NSRange(
            location: firstLineRange.location,
            length: NSMaxRange(lastLineRange) - firstLineRange.location
        )
        let expression = try! NSRegularExpression(
            pattern: #"^(\s*)(?:[-*+]|\d+\.)\s+(?:\[[ xX]\]\s+)?"#
        )

        var replacement = ""
        var edits: [(location: Int, removed: Int, inserted: Int)] = []
        var containsListItem = false
        var lineLocation = selectedLinesRange.location
        while lineLocation < NSMaxRange(selectedLinesRange) {
            let lineRange = string.lineRange(
                for: NSRange(location: lineLocation, length: 0)
            )
            let line = string.substring(with: lineRange)
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                replacement += line
            } else {
                guard let match = expression.firstMatch(
                    in: line,
                    range: NSRange(location: 0, length: (line as NSString).length)
                ) else { return false }
                containsListItem = true

                let leadingWhitespace = match.range(at: 1).length
                if outdent {
                    let removedCount = min(indentationWidth, leadingWhitespace)
                    replacement += (line as NSString).substring(from: removedCount)
                    if removedCount > 0 {
                        edits.append((lineRange.location, removedCount, 0))
                    }
                } else {
                    replacement += String(repeating: " ", count: indentationWidth) + line
                    edits.append((lineRange.location, 0, indentationWidth))
                }
            }
            lineLocation = NSMaxRange(lineRange)
        }

        guard containsListItem else { return false }
        guard !edits.isEmpty else { return true }
        textView.insertText(replacement, replacementRange: selectedLinesRange)

        func mappedLocation(_ originalLocation: Int) -> Int {
            var accumulatedDelta = 0
            for edit in edits {
                guard originalLocation > edit.location else { break }
                if originalLocation <= edit.location + edit.removed {
                    return edit.location + accumulatedDelta + edit.inserted
                }
                accumulatedDelta += edit.inserted - edit.removed
            }
            return originalLocation + accumulatedDelta
        }

        let newSelectionStart = mappedLocation(selectionStart)
        let newSelectionEnd = mappedLocation(selectionEnd)
        textView.setSelectedRange(NSRange(
            location: newSelectionStart,
            length: max(0, newSelectionEnd - newSelectionStart)
        ))
        normalizeOrderedListNumbers(in: textView)
        return true
    }

    private func continueListAfterNewline(in textView: NSTextView) -> Bool {
        normalizeOrderedListNumbers(in: textView)
        let string = textView.string as NSString
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }

        let cursorLocation = min(selection.location, string.length)
        let lineRange = string.lineRange(for: NSRange(location: cursorLocation, length: 0))
        let rawLine = string.substring(with: lineRange) as NSString
        let newlineLength: Int
        if rawLine.hasSuffix("\r\n") {
            newlineLength = 2
        } else if rawLine.hasSuffix("\n") || rawLine.hasSuffix("\r") {
            newlineLength = 1
        } else {
            newlineLength = 0
        }
        let lineLength = rawLine.length - newlineLength
        let line = rawLine.substring(to: lineLength)
        let expression = try! NSRegularExpression(
            pattern: #"^([ \t]*)([-*+]|\d+\.)([ \t]+)(\[[ xX]\][ \t]+)?(.*)$"#
        )
        guard let match = expression.firstMatch(
            in: line,
            range: NSRange(location: 0, length: (line as NSString).length)
        ) else { return false }

        let content = (line as NSString).substring(with: match.range(at: 5))
        if content.trimmingCharacters(in: .whitespaces).isEmpty,
           cursorLocation >= lineRange.location + lineLength {
            textView.insertText(
                "",
                replacementRange: NSRange(location: lineRange.location, length: lineLength)
            )
            textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
            return true
        }

        let indentation = (line as NSString).substring(with: match.range(at: 1))
        let marker = (line as NSString).substring(with: match.range(at: 2))
        let checklistRange = match.range(at: 4)
        let nextMarker: String
        if checklistRange.location != NSNotFound {
            nextMarker = "\(marker) [ ] "
        } else if marker.hasSuffix("."),
                  let rawNumber = Int(marker.dropLast()) {
            let number = MarkdownOrderedListItem.items(in: textView.string).first(where: {
                $0.markerRange.location == lineRange.location
            })?.displayNumber ?? rawNumber
            nextMarker = "\(number + 1). "
        } else {
            nextMarker = "\(marker) "
        }

        let insertion = "\n\(indentation)\(nextMarker)"
        textView.insertText(insertion, replacementRange: selection)
        textView.setSelectedRange(NSRange(
            location: cursorLocation + (insertion as NSString).length,
            length: 0
        ))
        return true
    }

    private func applyQuoteStyle(to textView: NSTextView) {
        replaceSelectedLines(in: textView) { line in
            let stripped = line.replacingOccurrences(
                of: #"^\s*>\s+"#,
                with: "",
                options: .regularExpression
            )
            return stripped.isEmpty ? stripped : "> " + stripped
        }
    }

    private func applyNumberedListStyle(to textView: NSTextView) {
        if insertPrefixOnEmptyLine("1. ", in: textView) { return }

        var itemNumber = 0
        replaceSelectedLines(in: textView) { line in
            let stripped = line.replacingOccurrences(
                of: #"^\s*([-*+]\s+(?:\[[ xX]\]\s+)?|\d+\.\s+)"#,
                with: "",
                options: .regularExpression
            )
            guard !stripped.isEmpty else { return stripped }
            itemNumber += 1
            return "\(itemNumber). \(stripped)"
        }
    }

    private func applyChecklistStyle(to textView: NSTextView) {
        if insertPrefixOnEmptyLine("- [ ] ", in: textView) { return }

        replaceSelectedLines(in: textView) { line in
            let stripped = line.replacingOccurrences(
                of: #"^\s*([-*+]\s+(?:\[[ xX]\]\s+)?|\d+\.\s+)"#,
                with: "",
                options: .regularExpression
            )
            return stripped.isEmpty ? stripped : "- [ ] " + stripped
        }
    }

    private func insertPrefixOnEmptyLine(_ prefix: String, in textView: NSTextView) -> Bool {
        let string = textView.string as NSString
        let selectedRange = textView.selectedRange()
        guard selectedRange.length == 0 else { return false }

        let lineRange = string.lineRange(for: selectedRange)
        let original = string.substring(with: lineRange)
        let content = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.isEmpty else { return false }

        let trailingNewline = original.hasSuffix("\n") ? "\n" : ""
        textView.insertText(prefix + trailingNewline, replacementRange: lineRange)
        textView.setSelectedRange(NSRange(
            location: lineRange.location + (prefix as NSString).length,
            length: 0
        ))
        return true
    }

    private func applyCodeBlock(to textView: NSTextView) {
        let string = textView.string as NSString
        let selectedRange = textView.selectedRange()
        let lineRange = string.lineRange(for: selectedRange)
        let original = string.substring(with: lineRange)
        let hasTrailingNewline = original.hasSuffix("\n")
        let content = hasTrailingNewline ? String(original.dropLast()) : original
        let replacement = "```\n\(content)\n```" + (hasTrailingNewline ? "\n" : "")

        textView.insertText(replacement, replacementRange: lineRange)
        textView.setSelectedRange(NSRange(
            location: lineRange.location + 4,
            length: (content as NSString).length
        ))
    }

    private func replaceSelectedLines(
        in textView: NSTextView,
        transform: (String) -> String
    ) {
        let string = textView.string as NSString
        let selectedRange = textView.selectedRange()
        let lineRange = string.lineRange(for: selectedRange)
        let original = string.substring(with: lineRange)
        let replacement = original
            .components(separatedBy: "\n")
            .map(transform)
            .joined(separator: "\n")

        textView.insertText(replacement, replacementRange: lineRange)
        textView.setSelectedRange(NSRange(location: lineRange.location, length: (replacement as NSString).length))
    }
}
