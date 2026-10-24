#if os(macOS)
import AppKit
import ScriblMarkdown
import ScriblMarkdownRenderer

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
    /// Set while a shared editing rule's edit is applied, so the edit itself doesn't
    /// trigger typing shortcuts or renumbering.
    private var isApplyingRuleEdit = false
    private let orderedListRenumberer = MarkdownOrderedListRenumberer()
    private var linkPopover: MarkdownLinkPopover?
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
        textView.performCommand = { [weak self, weak textView] action in
            guard let self, let textView else { return }
            self.apply(action, to: textView)
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
        guard !isStyling, !isApplyingRuleEdit, let textView = notification.object as? NSTextView else { return }
        if !textView.hasMarkedText() {
            let source = textView.string
            if (source as NSString).length > MarkdownOrderedListRenumberer.backgroundThreshold {
                scheduleOrderedListRenumbering(in: textView)
            } else {
                orderedListRenumberer.cancel()
                if let renumber = MarkdownEditingRules.renumberOrderedLists(in: source, selection: textView.selectedRange()) {
                    // Applying it finishes this change too.
                    apply(renumber, to: textView)
                    return
                }
            }
        } else {
            orderedListRenumberer.cancel()
        }
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

    private func scheduleOrderedListRenumbering(in textView: NSTextView) {
        let source = textView.string
        let selection = textView.selectedRange()
        orderedListRenumberer.schedule(in: source, selection: selection) { [weak self, weak textView] edit in
            guard let self, let textView, textView.string == source, !textView.hasMarkedText() else { return }
            guard textView.selectedRange() == selection else {
                self.scheduleOrderedListRenumbering(in: textView)
                return
            }
            if let edit { self.apply(edit, to: textView) }
        }
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
        if !isApplyingRuleEdit,
           textView.undoManager?.isUndoing != true,
           textView.undoManager?.isRedoing != true,
           !textView.hasMarkedText(),
           let shortcut = MarkdownEditingRules.typingShortcut(
               in: textView.string,
               selection: affectedCharRange,
               replacement: replacement
           ) {
            apply(shortcut, to: textView)
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
               applyRule(MarkdownEditingRules.deleteAtListMarker(in: textView.string, selection: textView.selectedRange(), forward: false), to: textView) {
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
               applyRule(MarkdownEditingRules.deleteAtListMarker(in: textView.string, selection: textView.selectedRange(), forward: true), to: textView) {
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
            return applyRule(MarkdownEditingRules.newline(in: textView.string, selection: textView.selectedRange()), to: textView)
        }
        if commandSelector == #selector(NSResponder.insertTab(_:))
            || commandSelector == NSSelectorFromString("insertTabIgnoringFieldEditor:") {
            return handleTab(in: textView, backward: false)
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            return handleTab(in: textView, backward: true)
        }
        return false
    }

    /// Tab moves between table cells, types a tab in code, and indents list items;
    /// Shift-Tab does the reverse. Elsewhere Tab types a tab.
    private func handleTab(in textView: NSTextView, backward: Bool) -> Bool {
        let source = textView.string
        let selection = textView.selectedRange()
        if let cell = MarkdownEditingRules.tableCellSelection(in: source, selection: selection, forward: !backward) {
            textView.setSelectedRange(cell)
            textView.scrollRangeToVisible(cell)
            return true
        }
        if MarkdownEditingRules.isInsideCodeBlock(selection.location, in: source) {
            return backward
        }
        return applyRule(MarkdownEditingRules.indent(in: source, selection: selection, outdent: backward), to: textView)
    }

    /// Applies a shared editing rule's result. Returns whether the rule handled the key.
    private func applyRule(_ edit: MarkdownEdit?, to textView: NSTextView) -> Bool {
        guard let edit else { return false }
        apply(edit, to: textView)
        return true
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
        case .editLink:
            editLink(in: textView)
        case .horizontalRule:
            apply(MarkdownInsertion.horizontalRule(
                in: textView.string,
                selection: textView.selectedRange()
            ), to: textView)
        }
    }

    /// Applies a shared source edit through the text view so it is undoable and restyled.
    private func apply(_ edit: MarkdownEdit, to textView: NSTextView) {
        if edit.changesText {
            isApplyingRuleEdit = true
            textView.insertText(edit.replacement, replacementRange: edit.range)
            isApplyingRuleEdit = false
            textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        }
        textView.setSelectedRange(edit.selection)
    }

    /// Opens the link popover for the link at the caret, or for a new link on the
    /// selection.
    private func editLink(in textView: NSTextView) {
        let source = textView.string
        let selection = textView.selectedRange()
        let codeRanges = MarkdownCodeBlock.blocks(in: source).map(\.sourceRange)
        let existing = MarkdownLinkPresentation.parse(in: source, excluding: codeRanges).links.first {
            NSLocationInRange(selection.location, $0.sourceRange) || NSMaxRange($0.sourceRange) == selection.location
                || NSIntersectionRange($0.sourceRange, selection).length > 0
        }
        let text = source as NSString
        let targetRange = existing?.sourceRange ?? selection
        let title = existing.map { text.substring(with: $0.labelRange) } ?? text.substring(with: selection)
        let popover = MarkdownLinkPopover(theme: style.theme)
        linkPopover = popover
        let anchor = textView.firstRect(forCharacterRange: NSRange(location: targetRange.location, length: max(1, targetRange.length)), actualRange: nil)
        let windowRect = textView.window?.convertFromScreen(anchor) ?? .zero
        popover.show(
            relativeTo: textView.convert(windowRect, from: nil),
            of: textView,
            title: title.isEmpty ? nil : title,
            destination: existing?.destination,
            onApply: { [weak self, weak textView] title, destination in
                guard let self, let textView else { return }
                self.apply(MarkdownInsertion.link(
                    title: title,
                    destination: destination,
                    in: textView.string,
                    selection: targetRange
                ), to: textView)
            },
            onRemove: existing.map { link in
                { [weak self, weak textView] in
                    guard let self, let textView else { return }
                    let label = (textView.string as NSString).substring(with: link.labelRange)
                    self.apply(MarkdownEdit(
                        range: link.sourceRange,
                        replacement: label,
                        selection: NSRange(location: link.sourceRange.location + (label as NSString).length, length: 0)
                    ), to: textView)
                }
            }
        )
    }

    func applyPresentation(to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        isStyling = true
        defer { isStyling = false }

        if let markdownTextView = textView as? MarkdownEditorTextView {
            markdownTextView.theme = style.theme
            markdownTextView.linkableDocumentExtensions = artifactParser.linkableDocumentExtensions
            markdownTextView.tableCellRenderer = MarkdownAttributedRenderer(style: MarkdownRenderStyle(theme: style.theme)).tableCellRenderer
        }

        let selectedRange = textView.selectedRange()
        let fullRange = NSRange(location: 0, length: storage.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = presentation == .styled ? 5 : 4
        paragraph.paragraphSpacing = presentation == .styled ? 7 : 0
        let bodyFont = presentation == .styled
            ? style.theme.bodyFont
            : typeface.monospacedFont(ofSize: scaled(MarkdownVisualSpec.referenceCodeSize), weight: .regular)

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
            let tables = styleTables(in: storage, font: bodyFont, excluding: blockExclusions)
            let ruleRanges = styleHorizontalRules(in: storage, font: bodyFont, excluding: blockExclusions, textView: textView)
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
            styleHeadings(in: storage, excluding: protectedRanges)
            styleLists(in: storage, font: bodyFont, excluding: protectedRanges)
            styleBullets(
                in: storage,
                font: bodyFont,
                textView: textView,
                excluding: protectedRanges + ruleRanges + tables.map(\.sourceRange)
            )
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
            layoutTables(tables, in: storage, textView: textView)
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
            (textView as? MarkdownEditorTextView)?.renderedBullets = []
            (textView as? MarkdownEditorTextView)?.renderedTables = []
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
        let titleFont = style.theme.headingFont(level: 1)
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
            font: style.theme.headingFont(level: 1),
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

    /// ATX headings 1–6 on the shared scale. An empty level-1 heading is the title line.
    private func styleHeadings(in storage: NSTextStorage, excluding excludedRanges: [NSRange]) {
        let range = NSRange(location: 0, length: storage.length)
        Self.headingExpression.enumerateMatches(in: storage.string, range: range) { match, _, _ in
            guard let match, !intersects(match.range, excludedRanges) else { return }
            let level = match.range(at: 1).length
            let content = match.range(at: 3)
            guard level == 1 || content.length > 0 else { return }
            hideMarker(in: storage, range: NSRange(location: match.range.location, length: content.location - match.range.location))
            storage.addAttribute(.font, value: style.theme.headingFont(level: level), range: content)
        }
    }

    private static let headingExpression = try! NSRegularExpression(pattern: #"(?m)^(#{1,6})([ \t]+)(.*)$"#)

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
                storage.addAttribute(.backgroundColor, value: palette.highlightBackground, range: span.contentRange)
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
                .font: style.theme.inlineCodeFont,
                .foregroundColor: palette.inlineCodeText,
                .backgroundColor: palette.inlineCodeBackground
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
                    markerText = "- "
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

    private static let bulletExpressions = [
        try! NSRegularExpression(pattern: #"(?m)^([ \t]*)([-*+])(?=[ \t]+)"#),
        try! NSRegularExpression(pattern: #"(?m)^[ \t]*(?:>[ \t]*)+()([-*+])(?=[ \t]+)"#)
    ]

    /// Bullet markers keep their place in the text but are drawn as the depth's symbol
    /// (• ◦ ▪), so `-`, `*` and `+` all read as bullets. Checklist markers draw boxes instead.
    private func styleBullets(
        in storage: NSTextStorage,
        font: NSFont,
        textView: NSTextView,
        excluding excludedRanges: [NSRange]
    ) {
        guard let markdownTextView = textView as? MarkdownEditorTextView else { return }
        let source = storage.string as NSString
        let checklistMarkers = Set(MarkdownChecklistItem.items(in: storage.string).map {
            NSMaxRange($0.indentationRange)
        })
        var rendered: [MarkdownEditorTextView.RenderedBullet] = []
        for expression in Self.bulletExpressions {
            for match in expression.matches(in: storage.string, range: NSRange(location: 0, length: source.length)) {
                let marker = match.range(at: 2)
                guard !intersects(marker, excludedRanges), !checklistMarkers.contains(marker.location) else { continue }
                let depth = MarkdownVisualSpec.listDepth(ofIndentation: source.substring(with: match.range(at: 1)))
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: marker)
                rendered.append(.init(
                    markerLocation: marker.location,
                    symbol: MarkdownVisualSpec.bulletSymbol(depth: depth),
                    font: storage.attribute(.font, at: marker.location, effectiveRange: nil) as? NSFont ?? font
                ))
            }
        }
        markdownTextView.renderedBullets = rendered.sorted { $0.markerLocation < $1.markerLocation }
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
        let controlSize = MarkdownDrawnMarkers.checklistBoxSize(for: font)
        let controlSlotWidth = MarkdownDrawnMarkers.checklistSlotWidth(for: font)
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
                    .foregroundColor: palette.completedText,
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

    private static let fenceExpression = try! NSRegularExpression(pattern: #"^([ \t]*(?:`{3,}|~{3,})[ \t]*)(.*)$"#)

    /// Fenced code on the shared code block surface: the opening fence becomes the header
    /// (its language stays editable text, set in the header style, with copy and pop-out
    /// buttons drawn over it), the code is syntax-colored beside a line-number gutter, and
    /// the closing fence collapses. An empty block keeps its fences visible as source.
    private func styleCodeBlocks(
        _ blocks: [MarkdownCodeBlock],
        in storage: NSTextStorage,
        textView: NSTextView
    ) {
        guard let markdownTextView = textView as? MarkdownEditorTextView else { return }
        let source = storage.string as NSString
        let surface = style.theme.surface
        let font = surface.codeFont
        let padding = MarkdownCodeBlockLayout.gutterPadding
        var rendered: [MarkdownEditorTextView.RenderedCodeBlock] = []
        for block in blocks {
            guard block.contentRange.length > 0 else {
                storage.addAttribute(.font, value: font, range: block.sourceRange)
                continue
            }
            let language = codeLanguage(of: block, in: source)
            var headerLineRange: NSRange?
            if let openingRange = block.openingRange {
                styleCodeBlockHeader(openingRange, in: storage)
                headerLineRange = openingRange
            }
            if let closingRange = block.closingRange {
                collapseLine(in: storage, range: closingRange)
            }
            for indentationRange in block.indentationRanges {
                hideMarker(in: storage, range: indentationRange)
            }
            storage.addAttribute(.font, value: font, range: block.contentRange)
            highlightCode(in: block, language: language, storage: storage)

            let lines = codeLineRanges(in: block.contentRange, source: source)
            let gutterWidth = MarkdownCodeBlockLayout.gutterWidth(lineCount: lines.count, font: font)
            for (index, lineRange) in lines.enumerated() {
                let paragraph = NSMutableParagraphStyle()
                paragraph.firstLineHeadIndent = gutterWidth
                paragraph.headIndent = gutterWidth
                paragraph.tailIndent = -padding
                paragraph.lineSpacing = 2
                paragraph.paragraphSpacingBefore = index == 0 ? padding : 0
                paragraph.paragraphSpacing = index == lines.count - 1 ? padding : 0
                storage.addAttribute(.paragraphStyle, value: paragraph, range: lineRange)
            }
            let code = NSMutableString(string: source.substring(with: block.contentRange))
            for indentationRange in block.indentationRanges.reversed() {
                code.deleteCharacters(in: NSRange(location: indentationRange.location - block.contentRange.location, length: indentationRange.length))
            }
            if code.hasSuffix("\n") { code.deleteCharacters(in: NSRange(location: code.length - 1, length: 1)) }
            rendered.append(.init(
                sourceRange: block.sourceRange,
                contentRange: block.contentRange,
                headerLineRange: headerLineRange,
                language: language,
                code: code as String,
                lineNumberFont: font,
                gutterWidth: gutterWidth
            ))
        }
        markdownTextView.renderedCodeBlocks = rendered
    }

    /// The opening fence as the header line: the fence characters hidden, the language set
    /// in the header font (small caps, like the display header's capitals) and centered in
    /// a header-height line.
    private func styleCodeBlockHeader(_ lineRange: NSRange, in storage: NSTextStorage) {
        let source = storage.string as NSString
        let line = source.substring(with: lineRange).trimmingCharacters(in: .newlines)
        guard let match = Self.fenceExpression.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return }
        let surface = style.theme.surface
        let height = MarkdownCodeBlockHeaderView.height
        let fenceRange = NSRange(location: lineRange.location + match.range(at: 1).location, length: match.range(at: 1).length)
        let infoRange = NSRange(location: lineRange.location + match.range(at: 2).location, length: match.range(at: 2).length)
        hideMarker(in: storage, range: fenceRange)

        let font = NSFont(
            descriptor: surface.headerFont.fontDescriptor.addingAttributes([
                .featureSettings: [[
                    NSFontDescriptor.FeatureKey.typeIdentifier: kLowerCaseType,
                    NSFontDescriptor.FeatureKey.selectorIdentifier: kLowerCaseSmallCapsSelector
                ]]
            ]),
            size: surface.headerFont.pointSize
        ) ?? surface.headerFont
        let lineHeight = font.ascender - font.descender + font.leading
        storage.addAttributes([
            .font: font,
            .foregroundColor: surface.headerText,
            .baselineOffset: max(0, (height - lineHeight) / 2)
        ], range: infoRange)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = height
        paragraph.maximumLineHeight = height
        paragraph.firstLineHeadIndent = 10
        paragraph.headIndent = 10
        paragraph.tailIndent = -60
        paragraph.lineBreakMode = .byTruncatingTail
        storage.addAttribute(.paragraphStyle, value: paragraph, range: lineRange)
    }

    private func codeLanguage(of block: MarkdownCodeBlock, in source: NSString) -> String? {
        block.openingRange.flatMap { range -> String? in
            let info = source.substring(with: range)
                .trimmingCharacters(in: CharacterSet(charactersIn: "`~").union(.whitespacesAndNewlines))
            return info.split(whereSeparator: \.isWhitespace).first.map(String.init)
        }
    }

    private func codeLineRanges(in contentRange: NSRange, source: NSString) -> [NSRange] {
        var lines: [NSRange] = []
        var location = contentRange.location
        while location < NSMaxRange(contentRange), location < source.length {
            let lineRange = NSIntersectionRange(source.lineRange(for: NSRange(location: location, length: 0)), contentRange)
            guard lineRange.length > 0 else { break }
            lines.append(lineRange)
            location = NSMaxRange(lineRange)
        }
        return lines
    }

    /// The host's highlighter, else the shared one in the theme's syntax colors.
    private func highlightCode(in block: MarkdownCodeBlock, language: String?, storage: NSTextStorage) {
        let highlighter = host?.codeHighlighter ?? MarkdownSyntaxHighlighter(colors: style.theme.syntax)
        let source = storage.string as NSString
        let code = source.substring(with: block.contentRange)
        for run in highlighter.colorRuns(forCode: code, language: language) {
            let range = NSRange(location: block.contentRange.location + run.range.location, length: run.range.length)
            guard NSMaxRange(range) <= NSMaxRange(block.contentRange),
                  !intersects(range, block.indentationRanges) else { continue }
            storage.addAttribute(.foregroundColor, value: run.color, range: range)
        }
    }

    private static let escapedPipeExpression = try! NSRegularExpression(pattern: #"\\(?=\|)"#)

    /// Tables stay editable source under a drawn grid: pipes hide, the delimiter row
    /// collapses, the header is bold and every row gets the cell padding. Column alignment
    /// happens in `layoutTables` once cell fonts are final.
    @discardableResult
    private func styleTables(
        in storage: NSTextStorage,
        font: NSFont,
        excluding excludedRanges: [NSRange]
    ) -> [MarkdownTable] {
        let tables = MarkdownTable.tables(in: storage.string, excluding: excludedRanges)
        let padding = MarkdownTableView.verticalCellPadding
        tableGlyphLayouts = []
        for table in tables {
            storage.addAttribute(
                .font,
                value: NSFontManager.shared.convert(style.theme.bodyFont, toHaveTrait: .boldFontMask),
                range: table.header.lineRange
            )
            storage.addAttribute(.foregroundColor, value: style.theme.surface.tableHeaderText, range: table.header.lineRange)
            for row in [table.header] + table.rows {
                for separator in row.separators where separator.length > 0 {
                    hideMarker(in: storage, range: separator)
                    storage.addAttribute(.font, value: font, range: NSRange(location: separator.location, length: 1))
                }
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 0
                paragraph.paragraphSpacingBefore = padding
                paragraph.paragraphSpacing = padding
                // Rows without a leading pipe still start one cell padding in.
                let hasLeadingSeparator = (row.separators.first?.length ?? 0) > 0
                paragraph.firstLineHeadIndent = hasLeadingSeparator ? 0 : MarkdownTableView.horizontalCellPadding
                paragraph.headIndent = MarkdownTableView.horizontalCellPadding
                storage.addAttribute(.paragraphStyle, value: paragraph, range: row.lineRange)
            }
            collapseLine(in: storage, range: table.delimiterRange)
            for match in Self.escapedPipeExpression.matches(in: storage.string, range: table.sourceRange) {
                hideMarker(in: storage, range: match.range)
            }
        }
        return tables
    }

    /// Aligns table columns by widening the hidden pipes between cells, and hands the grid
    /// (row lines, width, cells for pop-out) to the text view to draw.
    private func layoutTables(_ tables: [MarkdownTable], in storage: NSTextStorage, textView: NSTextView) {
        let cellPadding = MarkdownTableView.horizontalCellPadding
        var glyphLayouts: [RenderedObjectGlyphLayout] = []
        var rendered: [MarkdownEditorTextView.RenderedTable] = []
        for table in tables {
            let rows = [table.header] + table.rows
            let columnCount = table.header.cells.count
            var columnWidths = Array(repeating: CGFloat(0), count: columnCount)
            for row in rows {
                for (index, cell) in row.cells.enumerated() where index < columnCount {
                    columnWidths[index] = max(columnWidths[index], storage.attributedSubstring(from: cell).size().width)
                }
            }
            // The header's last cell keeps room for the pop-out button.
            if columnCount > 0 {
                columnWidths[columnCount - 1] += MarkdownTableView.popOutButtonSpace
            }

            for row in rows {
                for (index, separator) in row.separators.enumerated() where separator.length > 0 {
                    let width: CGFloat
                    if index == 0 {
                        width = cellPadding
                    } else if index - 1 < row.cells.count {
                        let cellWidth = storage.attributedSubstring(from: row.cells[index - 1]).size().width
                        let isLast = index - 1 == columnCount - 1
                        width = columnWidths[index - 1] - cellWidth + (isLast ? cellPadding : cellPadding * 2)
                    } else {
                        width = 0
                    }
                    glyphLayouts.append(.init(range: separator, size: NSSize(width: max(0, width), height: 0)))
                }
            }
            rendered.append(.init(
                sourceRange: table.sourceRange,
                headerLineRange: table.header.lineRange,
                rowLineRanges: table.rows.map(\.lineRange),
                width: columnWidths.reduce(0, +) + cellPadding * 2 * CGFloat(columnCount),
                content: MarkdownTableContent(table, in: storage.string)
            ))
        }
        tableGlyphLayouts = glyphLayouts
        (textView as? MarkdownEditorTextView)?.renderedTables = rendered
    }

    @discardableResult
    private func styleHorizontalRules(
        in storage: NSTextStorage,
        font: NSFont,
        excluding excludedRanges: [NSRange],
        textView: NSTextView
    ) -> [NSRange] {
        guard let markdownTextView = textView as? MarkdownEditorTextView else { return [] }
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
        return ruleRanges
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
            let font = MarkdownDrawnMarkers.mathFont(ofSize: scaled(isBlock ? 20 : 17))
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
            let size = MarkdownDrawnMarkers.keycapSize(for: displayText, font: font, scale: scaled(1))
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
            let content: MarkdownLinkCardContent
            switch artifact.kind {
            case .web(let url):
                loadMetadataIfNeeded(for: url, textView: artifactTextView)
                content = webMetadata[url].map(MarkdownLinkCardContent.web) ?? .loading(url: url)
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

    private func documentCardContent(for reference: MarkdownNoteReference) -> MarkdownLinkCardContent {
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
        guard !objectGlyphLayouts.isEmpty else { return 0 }

        var replacementGlyphs = Array(
            UnsafeBufferPointer(start: glyphs, count: glyphRange.length)
        )
        var replacementProperties = Array(
            UnsafeBufferPointer(start: properties, count: glyphRange.length)
        )

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
#endif
