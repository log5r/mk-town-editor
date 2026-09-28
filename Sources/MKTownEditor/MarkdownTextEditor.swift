import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    let model: MarkdownEditorModel
    var textStyle: EditorTextStyle = EditorTextStyle()
    var layoutOptions: EditorLayoutOptions = EditorLayoutOptions()
    var sharedSnapshot: DocumentSnapshot?
    var usesSharedAnalysis = false
    var imageImportMode: ImageImportMode = .managedCopy
    var tableAddsRowOnTab = true
    var proofing = EditorProofingSettings()
    var snippets: [EditorSnippet] = []
    var isEditable = true
    var onImageDrop: ((URL, Int) -> Void)?
    var onImagePaste: ((Data) -> Void)?
    var onVisibleSourceChange: ((Int) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = EditorScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !layoutOptions.wrapsLines
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        let textView = EditorTextView()
        textView.layoutManager?.delegate = textView
        textView.delegate = context.coordinator
        textView.string = text
        textView.isRichText = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textStyle.apply(to: textView)
        context.coordinator.appliedTextStyle = textStyle
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = proofing.correctsSpelling
        textView.isContinuousSpellCheckingEnabled = proofing.checksSpelling
        textView.isVerticallyResizable = true
        scrollView.documentView = textView
        layoutOptions.apply(to: textView, in: scrollView)
        scrollView.onLayout = { [weak textView, weak scrollView, weak coordinator = context.coordinator] in
            guard let textView, let scrollView, let coordinator,
                  let options = coordinator.appliedLayoutOptions else { return }
            options.synchronizeWidth(of: textView, in: scrollView)
        }
        context.coordinator.appliedLayoutOptions = layoutOptions
        model.listIndentWidth = layoutOptions.listIndentWidth
        model.codeIndentWidth = layoutOptions.codeIndentWidth
        model.tableAddsRowOnTab = tableAddsRowOnTab
        model.snippets = snippets
        let lineNumberRuler = MarkdownLineNumberRulerView(scrollView: scrollView, editor: textView)
        scrollView.verticalRulerView = lineNumberRuler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.lineNumberRuler = lineNumberRuler
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        context.coordinator.isRestoringSession = true
        model.connect(textView, scrollView: scrollView)
        textView.commandModel = model
        textView.imageImportMode = imageImportMode
        textView.onImageDrop = onImageDrop
        textView.onImagePaste = onImagePaste
        textView.registerForDraggedTypes([.fileURL])
        context.coordinator.sharedSnapshot = sharedSnapshot
        context.coordinator.usesSharedAnalysis = usesSharedAnalysis
        context.coordinator.onVisibleSourceChange = onVisibleSourceChange
        context.coordinator.proofing = proofing
        context.coordinator.applyProofing()
        context.coordinator.refreshSyntax()
        layoutOptions.synchronizeWidth(of: textView, in: scrollView)
        context.coordinator.isRestoringSession = false
        textView.onFocused = { [weak textView, weak model, weak coordinator = context.coordinator] in
            guard let textView, let model else { return }
            model.editorDidGainFocus(textView)
            coordinator?.applyProofingLanguage()
        }
        scrollView.onWindowAttached = { [weak textView, weak model, weak coordinator = context.coordinator, weak scrollView] in
            guard let textView, let model, let coordinator, let scrollView else { return }
            coordinator.isRestoringSession = true
            model.restoreScroll(in: scrollView)
            coordinator.isRestoringSession = false
            model.restoreFocusIfNeeded(textView)
        }
        return scrollView
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator, name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        if let textView = scrollView.documentView as? NSTextView {
            coordinator.model.disconnect(textView, scrollView: scrollView)
        }
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? EditorTextView else { return }
        textView.isEditable = isEditable
        textView.imageImportMode = imageImportMode
        textView.onImageDrop = onImageDrop
        textView.onImagePaste = onImagePaste
        context.coordinator.sharedSnapshot = sharedSnapshot
        context.coordinator.usesSharedAnalysis = usesSharedAnalysis
        context.coordinator.onVisibleSourceChange = onVisibleSourceChange
        context.coordinator.proofing = proofing
        context.coordinator.applyProofing()
        if context.coordinator.appliedLayoutOptions != layoutOptions {
            layoutOptions.apply(to: textView, in: scrollView)
            context.coordinator.appliedLayoutOptions = layoutOptions
            context.coordinator.lineNumberRuler?.refresh()
        }
        context.coordinator.model.listIndentWidth = layoutOptions.listIndentWidth
        context.coordinator.model.codeIndentWidth = layoutOptions.codeIndentWidth
        context.coordinator.model.tableAddsRowOnTab = tableAddsRowOnTab
        context.coordinator.model.snippets = snippets
        if context.coordinator.appliedTextStyle != textStyle {
            textStyle.apply(to: textView)
            context.coordinator.appliedTextStyle = textStyle
            context.coordinator.lineNumberRuler?.refresh()
        }
        layoutOptions.synchronizeWidth(of: textView, in: scrollView)
        guard textView.string != text else {
            context.coordinator.refreshSyntax()
            return
        }
        let selection = textView.selectedRange()
        textView.clearFolds()
        textView.string = text
        context.coordinator.applyProofing()
        context.coordinator.refreshSyntax()
        layoutOptions.synchronizeWidth(of: textView, in: scrollView)
        context.coordinator.lineNumberRuler?.refresh()
        let length = (text as NSString).length
        let location = min(selection.location, length)
        textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        let model: MarkdownEditorModel
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        weak var lineNumberRuler: MarkdownLineNumberRulerView?
        var appliedTextStyle: EditorTextStyle?
        var appliedLayoutOptions: EditorLayoutOptions?
        var sharedSnapshot: DocumentSnapshot?
        var usesSharedAnalysis = false
        var proofing = EditorProofingSettings()
        private var proofingSource: String?
        private var protectedProofingRanges: [MarkdownProofingContext.ProtectedRange] = []
        var onVisibleSourceChange: ((Int) -> Void)?
        private var highlightedSource: String?
        private var highlightedSnapshotSource: String?
        private var highlightedWithSharedAnalysis: Bool?
        var isRestoringSession = false

        init(text: Binding<String>, model: MarkdownEditorModel) {
            _text = text
            self.model = model
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            (textView as? EditorTextView)?.clearFolds()
            text = textView.string
            applyProofing()
            refreshSyntax()
            if let scrollView, let options = appliedLayoutOptions {
                options.synchronizeWidth(of: textView, in: scrollView)
            }
            lineNumberRuler?.refresh()
        }

        @MainActor func refreshSyntax() {
            guard let textView, !textView.hasMarkedText() else { return }
            let source = textView.string
            let snapshotSource = sharedSnapshot?.source
            guard highlightedSource != source || highlightedSnapshotSource != snapshotSource ||
                    highlightedWithSharedAnalysis != usesSharedAnalysis else { return }
            if usesSharedAnalysis {
                let spans = snapshotSource == source ? sharedSnapshot?.syntaxSpans : nil
                MarkdownSyntaxHighlighter.apply(to: textView, spans: spans ?? [])
            } else {
                MarkdownSyntaxHighlighter.apply(to: textView)
            }
            highlightedSource = source
            highlightedSnapshotSource = snapshotSource
            highlightedWithSharedAnalysis = usesSharedAnalysis
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            (textView as? EditorTextView)?.unfold(containing: textView.selectedRange())
            model.selectionDidChange(textView.selectedRange())
            applyProofing()
        }

        @MainActor func applyProofingLanguage() {
            let checker = NSSpellChecker.shared
            if let language = proofing.language.spellCheckerIdentifier {
                checker.automaticallyIdentifiesLanguages = !checker.setLanguage(language)
            } else {
                checker.automaticallyIdentifiesLanguages = true
            }
        }

        @MainActor func applyProofing() {
            guard let textView else { return }
            if proofingSource != textView.string {
                proofingSource = textView.string
                protectedProofingRanges = MarkdownProofingContext.protectedRanges(in: textView.string)
            }
            let location = textView.selectedRange().location
            let protected = MarkdownProofingContext.isProtected(location,
                in: protectedProofingRanges)
            textView.isContinuousSpellCheckingEnabled = proofing.checksSpelling && !protected
            textView.isAutomaticSpellingCorrectionEnabled = proofing.correctsSpelling && !protected
            if textView.window?.firstResponder === textView { applyProofingLanguage() }
        }

        @MainActor @objc func clipViewBoundsDidChange(_ notification: Notification) {
            lineNumberRuler?.needsDisplay = true
            guard let scrollView, !isRestoringSession else { return }
            model.scrollDidChange(scrollView.contentView.bounds.origin)
            if let editor = textView as? EditorTextView,
               let location = editor.firstVisibleSourceLocation(in: scrollView) {
                onVisibleSourceChange?(location)
            }
        }
    }
}

enum MarkdownProofingContext {
    struct ProtectedRange: Equatable {
        let range: NSRange
        let includesEnd: Bool
    }

    private static let urlPattern = try! NSRegularExpression(pattern: #"https?://[^\s)<>\]]+"#)

    static func protectedRanges(in source: String) -> [ProtectedRange] {
        let analysis = MarkdownAnalysis(source)
        let code = analysis.blocks.filter { $0.kind == .codeBlock }
            .map { ProtectedRange(range: $0.sourceRange, includesEnd: false) }
        let inline = MarkdownInlineSyntax.codeSpanRanges(in: source)
            .map { ProtectedRange(range: $0, includesEnd: false) }
        let full = NSRange(location: 0, length: (source as NSString).length)
        let urls = urlPattern.matches(in: source, range: full)
            .map { ProtectedRange(range: $0.range, includesEnd: true) }
        return code + inline + urls
    }

    static func isProtected(_ location: Int, in ranges: [ProtectedRange]) -> Bool {
        ranges.contains { item in
            NSLocationInRange(location, item.range) ||
                (item.includesEnd && location == NSMaxRange(item.range))
        }
    }
}

private final class EditorScrollView: NSScrollView {
    var onWindowAttached: (() -> Void)?
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onWindowAttached?() }
    }
}

final class EditorTextView: NSTextView {
    var onFocused: (() -> Void)?
    weak var commandModel: MarkdownEditorModel?
    var imageImportMode: ImageImportMode = .managedCopy
    var onImageDrop: ((URL, Int) -> Void)?
    var onImagePaste: ((Data) -> Void)?
    var imagePasteboard: NSPasteboard = .general
    private(set) var foldedPlans: [MarkdownFoldPlan] = []
    var foldedHeaderLocations: Set<Int> { Set(foldedPlans.map(\.headerLocation)) }
    private var selectionBeforeImageDrag: NSRange?
    private var imageDropLocation: Int? {
        didSet { needsDisplay = true }
    }

    func toggleFold(at location: Int) -> Bool {
        guard let plan = MarkdownFoldPlan.at(location, in: string) else { return false }
        if let index = foldedPlans.firstIndex(where: { $0.headerLocation == plan.headerLocation }) {
            foldedPlans.remove(at: index)
        } else {
            foldedPlans.append(plan)
            if NSLocationInRange(selectedRange().location, plan.hiddenRange) {
                setSelectedRange(NSRange(location: plan.headerLocation, length: 0))
            }
        }
        refreshFolds()
        return true
    }

    func clearFolds() {
        guard !foldedPlans.isEmpty else { return }
        foldedPlans.removeAll()
        refreshFolds()
    }

    func unfold(containing selection: NSRange) {
        let before = foldedPlans.count
        foldedPlans.removeAll { plan in
            selection.length == 0
                ? NSLocationInRange(selection.location, plan.hiddenRange)
                : NSIntersectionRange(selection, plan.hiddenRange).length > 0
        }
        if foldedPlans.count != before { refreshFolds() }
    }

    private func refreshFolds() {
        let length = (string as NSString).length
        layoutManager?.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: length),
            changeInLength: 0, actualCharacterRange: nil)
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
        needsDisplay = true
    }

    func firstVisibleSourceLocation(in scrollView: NSScrollView) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let visible = convert(scrollView.contentView.bounds, from: scrollView.contentView)
        let point = NSPoint(x: 0, y: max(0, visible.minY - textContainerOrigin.y))
        return min((string as NSString).length,
                   layoutManager.characterIndex(for: point, in: textContainer,
                                                fractionOfDistanceBetweenInsertionPoints: nil))
    }

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome { onFocused?() }
        return didBecome
    }

    override func insertNewline(_ sender: Any?) {
        if commandModel?.continueListOrQuote() == true { return }
        super.insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        if commandModel?.advanceSnippetPlaceholder(backwards: false) == true { return }
        if commandModel?.expandSnippetTrigger() == true { return }
        if commandModel?.moveTableCell(backwards: false) == true { return }
        if commandModel?.changeIndentation(.indent) == true { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if commandModel?.advanceSnippetPlaceholder(backwards: true) == true { return }
        if commandModel?.moveTableCell(backwards: true) == true { return }
        if commandModel?.changeIndentation(.outdent) == true { return }
        super.insertBacktab(sender)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if let typed = insertString as? String,
           commandModel?.completeSymbol(typed, replacementRange: replacementRange) == true { return }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func paste(_ sender: Any?) {
        guard isEditable, !hasMarkedText() else {
            super.paste(sender)
            return
        }
        if let onImagePaste, let data = Self.imageData(in: imagePasteboard) {
            onImagePaste(data)
            return
        }
        if let value = imagePasteboard.string(forType: .string),
           commandModel?.pasteURLAsLink(value) == true { return }
        super.paste(sender)
    }

    @objc private func pasteURLAsPlainText(_ sender: Any?) {
        super.paste(sender)
    }

    static func imageData(in pasteboard: NSPasteboard) -> Data? {
        pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard Self.imageURL(in: sender.draggingPasteboard) != nil, onImageDrop != nil,
              isEditable, !hasMarkedText() else { return super.draggingEntered(sender) }
        selectionBeforeImageDrag = selectedRange()
        imageDropLocation = dropInsertionLocation(for: sender.draggingLocation)
        return imageImportMode == .managedCopy ? .copy : .link
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard Self.imageURL(in: sender.draggingPasteboard) != nil, onImageDrop != nil,
              isEditable, !hasMarkedText() else { return super.draggingUpdated(sender) }
        setSelectedRange(NSRange(location: dropInsertionLocation(for: sender.draggingLocation), length: 0))
        imageDropLocation = selectedRange().location
        return imageImportMode == .managedCopy ? .copy : .link
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let selectionBeforeImageDrag {
            setSelectedRange(selectionBeforeImageDrag)
            self.selectionBeforeImageDrag = nil
            imageDropLocation = nil
            return
        }
        selectionBeforeImageDrag = nil
        imageDropLocation = nil
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = Self.imageURL(in: sender.draggingPasteboard), let onImageDrop,
              isEditable, !hasMarkedText() else { return super.performDragOperation(sender) }
        let location = dropInsertionLocation(for: sender.draggingLocation)
        setSelectedRange(NSRange(location: location, length: 0))
        selectionBeforeImageDrag = nil
        imageDropLocation = nil
        onImageDrop(url, location)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let imageDropLocation,
              let indicator = imageDropIndicatorRect(at: imageDropLocation),
              indicator.intersects(dirtyRect) else { return }
        NSColor.controlAccentColor.setFill()
        indicator.fill()
    }

    func imageDropIndicatorRect(at location: Int) -> NSRect? {
        guard let window, location >= 0,
              location <= (string as NSString).length else { return nil }
        let screen = firstRect(forCharacterRange: NSRange(location: location, length: 0),
                               actualRange: nil)
        let local = convert(window.convertFromScreen(screen), from: nil)
        return NSRect(x: local.minX, y: local.minY, width: 2,
                      height: max(local.height, font?.pointSize ?? 13))
    }

    func dropInsertionLocation(for windowPoint: NSPoint) -> Int {
        guard let layoutManager, let textContainer else { return (string as NSString).length }
        let local = convert(windowPoint, from: nil)
        let containerPoint = NSPoint(x: local.x - textContainerOrigin.x,
                                     y: local.y - textContainerOrigin.y)
        return min((string as NSString).length,
                   layoutManager.characterIndex(for: containerPoint, in: textContainer,
                                                fractionOfDistanceBetweenInsertionPoints: nil))
    }

    static func imageURL(in pasteboard: NSPasteboard) -> URL? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL]
        guard let urls, urls.count == 1,
              let url = urls.first, url.isFileURL,
              UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else { return nil }
        return url
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        makeMarkdownMenu(baseMenu: super.menu(for: event))
    }

    func makeMarkdownMenu(baseMenu: NSMenu?) -> NSMenu {
        let menu = (baseMenu?.copy() as? NSMenu) ?? NSMenu()
        if selectedRange().length > 0,
           let value = imagePasteboard.string(forType: .string),
           MarkdownURLPaste.validURL(value) != nil {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let plainPaste = NSMenuItem(title: "URL をそのまま貼り付け", action: #selector(pasteURLAsPlainText(_:)),
                                       keyEquivalent: "")
            plainPaste.target = self
            menu.addItem(plainPaste)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        for command in EditorCommand.context {
            add(command, to: menu)
        }
        let codeItem = NSMenuItem(title: "コードブロック", action: nil, keyEquivalent: "")
        let codeMenu = NSMenu(title: "コードブロック")
        add(.codeBlock(language: nil), to: codeMenu)
        for language in MarkdownCodeLanguage.allCases {
            add(.codeBlock(language: language), to: codeMenu)
        }
        codeItem.submenu = codeMenu
        menu.addItem(codeItem)
        let headingItem = NSMenuItem(title: "見出しレベル", action: nil, keyEquivalent: "")
        let headingMenu = NSMenu(title: "見出しレベル")
        for level in 0...6 {
            add(.heading(level: level), to: headingMenu)
        }
        headingItem.submenu = headingMenu
        menu.addItem(headingItem)
        return menu
    }

    private func add(_ command: EditorCommand, to menu: NSMenu) {
        let item = NSMenuItem(title: command.title, action: #selector(performMarkdownCommand(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = command
        item.isEnabled = command.canExecute(in: commandModel)
        menu.addItem(item)
    }

    @objc private func performMarkdownCommand(_ item: NSMenuItem) {
        guard let command = item.representedObject as? EditorCommand else { return }
        command.perform(on: commandModel)
    }
}

extension EditorTextView: @preconcurrency NSLayoutManagerDelegate {
    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>,
                       font aFont: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard !foldedPlans.isEmpty else { return 0 }
        var properties = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
        var changed = false
        for offset in properties.indices where foldedPlans.contains(where: {
            NSLocationInRange(charIndexes[offset], $0.hiddenRange)
        }) {
            properties[offset] = .null
            changed = true
        }
        guard changed else { return 0 }
        properties.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            layoutManager.setGlyphs(glyphs, properties: base, characterIndexes: charIndexes,
                font: aFont, forGlyphRange: glyphRange)
        }
        return glyphRange.length
    }
}
