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
    var whitespaceOptions = EditorWhitespaceOptions()
    var isEditable = true
    var onImageDrop: ((URL, Int) -> Void)?
    var onImagePaste: ((Data) -> Void)?
    var onVisibleSourceChange: ((Int) -> Void)?
    var documentContext = DocumentContext(fileURL: nil)
    var loadsExternalLinkPreviews = false
    var usesInlineLivePresentation = false
    var usesTypewriterMode = false

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        model.beginViewUpdate()
        defer { model.endViewUpdate() }
        let scrollView = EditorScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !layoutOptions.wrapsLines
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        // AppKit defaults to unclipped drawing on macOS 14+. Keep the ruler and
        // scroll background out of the shared window toolbar.
        scrollView.clipsToBounds = true
        scrollView.drawsBackground = true

        let textView = EditorTextView()
        textView.placeholder = String(localized: "Markdown で書き始めましょう。")
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
        textView.whitespaceOptions = whitespaceOptions
        textView.whitespaceTabWidth = textStyle.tabWidth
        textView.refreshInvisibles()
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
        scrollView.onManualScroll = { [weak coordinator = context.coordinator] in
            coordinator?.manualScrollDidStart()
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(context.coordinator,
            selector: #selector(Coordinator.liveScrollDidStart(_:)),
            name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        NotificationCenter.default.addObserver(context.coordinator,
            selector: #selector(Coordinator.liveScrollDidEnd(_:)),
            name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        context.coordinator.isRestoringSession = true
        model.connect(textView, scrollView: scrollView)
        textView.commandModel = model
        textView.imageImportMode = imageImportMode
        textView.onImageDrop = onImageDrop
        textView.onImagePaste = onImagePaste
        model.markdownDialect = documentContext.markdownDialect
        textView.hoverDocumentContext = documentContext
        textView.loadsExternalLinkPreviews = loadsExternalLinkPreviews
        if textView.whitespaceOptions != whitespaceOptions ||
           textView.whitespaceTabWidth != textStyle.tabWidth {
            textView.whitespaceOptions = whitespaceOptions
            textView.whitespaceTabWidth = textStyle.tabWidth
            textView.refreshInvisibles()
        }
        textView.registerForDraggedTypes([.fileURL])
        context.coordinator.sharedSnapshot = sharedSnapshot
        context.coordinator.usesSharedAnalysis = usesSharedAnalysis
        context.coordinator.usesInlineLivePresentation = usesInlineLivePresentation
        context.coordinator.usesTypewriterMode = usesTypewriterMode
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
            coordinator?.refreshSyntax()
        }
        textView.onBlurred = { [weak coordinator = context.coordinator] in
            Task { @MainActor [weak coordinator] in coordinator?.refreshSyntax() }
        }
        scrollView.onWindowAttached = { [weak textView, weak model, weak coordinator = context.coordinator, weak scrollView] in
            guard let textView, let model, let coordinator, let scrollView else { return }
            guard model.textView === textView else { return }
            model.beginViewUpdate()
            defer { model.endViewUpdate() }
            coordinator.isRestoringSession = true
            model.restoreScroll(in: scrollView)
            coordinator.isRestoringSession = false
            model.restoreFocusIfNeeded(textView)
        }
        return scrollView
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.model.beginViewUpdate()
        defer { coordinator.model.endViewUpdate() }
        NotificationCenter.default.removeObserver(coordinator, name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.removeObserver(coordinator, name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        NotificationCenter.default.removeObserver(coordinator, name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        coordinator.cancelTypewriterFollow()
        coordinator.cancelVisibleSourceChange()
        if let textView = scrollView.documentView as? NSTextView {
            (textView as? EditorTextView)?.cancelLinkHover()
            coordinator.model.disconnect(textView, scrollView: scrollView)
        }
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        model.beginViewUpdate()
        defer { model.endViewUpdate() }
        guard let textView = scrollView.documentView as? EditorTextView else { return }
        textView.isEditable = isEditable
        textView.imageImportMode = imageImportMode
        textView.onImageDrop = onImageDrop
        textView.onImagePaste = onImagePaste
        if textView.hoverDocumentContext != documentContext ||
            textView.loadsExternalLinkPreviews != loadsExternalLinkPreviews {
            textView.cancelLinkHover()
        }
        model.markdownDialect = documentContext.markdownDialect
        textView.hoverDocumentContext = documentContext
        textView.loadsExternalLinkPreviews = loadsExternalLinkPreviews
        context.coordinator.sharedSnapshot = sharedSnapshot
        context.coordinator.usesSharedAnalysis = usesSharedAnalysis
        context.coordinator.usesInlineLivePresentation = usesInlineLivePresentation
        context.coordinator.usesTypewriterMode = usesTypewriterMode
        if !usesTypewriterMode { context.coordinator.cancelTypewriterFollow() }
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
        // Input methods keep composed text marked until the user confirms it, and marked text is
        // not reported to the binding. Replacing the contents here would destroy the composition
        // (AppKit then asks the input method to commit) and drop the text being typed. The
        // committed text reaches the binding through textDidChange once the composition ends.
        guard textView.editorSource != text, !textView.hasMarkedText() else {
            context.coordinator.refreshSyntax()
            return
        }
        let selections = textView.selectedRanges.map(\.rangeValue)
        textView.clearFolds()
        textView.string = text
        textView.refreshInvisibles()
        context.coordinator.applyProofing()
        context.coordinator.refreshSyntax()
        layoutOptions.synchronizeWidth(of: textView, in: scrollView)
        context.coordinator.lineNumberRuler?.refresh()
        let length = (text as NSString).length
        var restored: [NSRange] = []
        for selection in selections {
            let location = min(max(0, selection.location), length)
            let range = NSRange(location: location,
                                length: min(max(0, selection.length), length - location))
            if !restored.contains(range) { restored.append(range) }
        }
        textView.setSelectedRanges(restored.map(NSValue.init(range:)), affinity: .upstream,
                                   stillSelecting: false)
        Task { @MainActor [weak scrollView, weak model] in
            guard let scrollView, let model,
                  model.textView === scrollView.documentView else { return }
            model.scrollDidChange(scrollView.contentView.bounds.origin, in: scrollView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        let model: MarkdownEditorModel
        weak var textView: NSTextView? {
            didSet { observeProofingEdits() }
        }
        weak var scrollView: NSScrollView?
        weak var lineNumberRuler: MarkdownLineNumberRulerView?
        var appliedTextStyle: EditorTextStyle?
        var appliedLayoutOptions: EditorLayoutOptions?
        var sharedSnapshot: DocumentSnapshot? {
            didSet { model.sharedSnapshot = sharedSnapshot }
        }
        var usesSharedAnalysis = false {
            didSet { model.usesSharedAnalysis = usesSharedAnalysis }
        }
        var usesInlineLivePresentation = false
        var usesTypewriterMode = false
        private var lastManualScroll = Date.distantPast
        private var isUserScrolling = false
        private var typewriterFollowTask: Task<Void, Never>?
        private var visibleSourceChangeTask: Task<Void, Never>?
        var proofing = EditorProofingSettings()
        private var proofingSource: String?
        private var proofingDialect: MarkdownDialect?
        private var protectedProofingRanges: [MarkdownProofingContext.ProtectedRange] = []
        /// The ranges exactly as analysed for `proofingSource`, before any edit shifted them.
        private var proofingSourceRanges: [MarkdownProofingContext.ProtectedRange] = []
        var onVisibleSourceChange: ((Int) -> Void)?
        private var highlightedSource: String?
        private var highlightedSnapshotSource: String?
        private var highlightedDialect: MarkdownDialect?
        private var highlightedWithSharedAnalysis: Bool?
        private var highlightedWithLivePresentation: Bool?
        private var inlineLiveDisplay: MarkdownInlineLiveDisplay?
        var isRestoringSession = false

        init(text: Binding<String>, model: MarkdownEditorModel) {
            _text = text
            self.model = model
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            (textView as? EditorTextView)?.clearFolds()
            var source = textView.editorSource
            source.makeContiguousUTF8()
            text = source
            (textView as? EditorTextView)?.refreshInvisibles()
            applyProofing()
            refreshSyntax()
            if let scrollView, let options = appliedLayoutOptions {
                options.synchronizeWidth(of: textView, in: scrollView)
            }
            lineNumberRuler?.refresh()
            scheduleTypewriterFollow()
        }

        @MainActor func manualScrollDidStart() {
            lastManualScroll = Date()
            cancelTypewriterFollow()
        }

        @MainActor @objc func liveScrollDidStart(_ notification: Notification) {
            isUserScrolling = true
            manualScrollDidStart()
        }

        @MainActor @objc func liveScrollDidEnd(_ notification: Notification) {
            isUserScrolling = false
            lastManualScroll = Date()
        }

        @MainActor func cancelTypewriterFollow() {
            typewriterFollowTask?.cancel()
            typewriterFollowTask = nil
        }

        @MainActor private func scheduleTypewriterFollow() {
            cancelTypewriterFollow()
            guard usesTypewriterMode else { return }
            typewriterFollowTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled else { return }
                self?.followTypingIfAppropriate()
            }
        }

        @MainActor func followTypingIfAppropriate() {
            guard usesTypewriterMode, let textView, let scrollView,
                  textView.window?.firstResponder === textView else { return }
            scrollView.layoutSubtreeIfNeeded()
            guard let lineMidY = TypewriterScrolling.lineMidY(for: textView,
                at: textView.selectedRange().location) else { return }
            let clip = scrollView.contentView
            let visible = clip.bounds.height
            let document = scrollView.documentView?.bounds.height ?? textView.bounds.height
            guard let target = TypewriterScrolling.targetOrigin(
                lineMidY: lineMidY, visibleHeight: visible, documentHeight: document,
                currentOrigin: clip.bounds.origin.y,
                secondsSinceManualScroll: Date().timeIntervalSince(lastManualScroll),
                isUserScrolling: isUserScrolling, isComposing: textView.hasMarkedText())
            else { return }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
            scrollView.reflectScrolledClipView(clip)
        }

        @MainActor func refreshSyntax() {
            guard let textView, !textView.hasMarkedText() else { return }
            let source = textView.editorSource
            let dialect = model.markdownDialect
            let snapshot = sharedSnapshot.flatMap {
                $0.matches(source: source, dialect: dialect) ? $0 : nil
            }
            let snapshotSource = snapshot?.source
            // TextKit adjusts existing temporary colors as the text changes. Keep them
            // until matching analysis arrives instead of clearing them on every keystroke.
            // Inline marker ranges also belong to the old source and must not be reapplied.
            if usesSharedAnalysis && snapshot == nil { return }
            let needsBase = highlightedSource != source || highlightedSnapshotSource != snapshotSource ||
                highlightedDialect != dialect ||
                highlightedWithSharedAnalysis != usesSharedAnalysis ||
                highlightedWithLivePresentation != usesInlineLivePresentation
            if needsBase {
                let analysis = snapshot?.analysis ?? MarkdownAnalysis(source, dialect: dialect)
                let displaySpans = usesSharedAnalysis ? snapshot?.syntaxSpans
                    : MarkdownSyntaxHighlighter.spans(in: source, analysis: analysis)
                MarkdownSyntaxHighlighter.apply(to: textView, spans: displaySpans ?? [])
                if usesInlineLivePresentation,
                   let displaySpans {
                    inlineLiveDisplay = MarkdownInlineLiveDisplay(textView: textView,
                        ranges: MarkdownInlineLivePresentation.markerRanges(in: source,
                            spans: displaySpans,
                            analysis: analysis))
                } else {
                    inlineLiveDisplay = nil
                }
                highlightedSource = source
                highlightedSnapshotSource = snapshotSource
                highlightedDialect = dialect
                highlightedWithSharedAnalysis = usesSharedAnalysis
                highlightedWithLivePresentation = usesInlineLivePresentation
            }
            let selections = textView.window?.firstResponder === textView
                ? textView.selectedRanges.map(\.rangeValue) : []
            inlineLiveDisplay?.update(in: textView,
                activeLines: MarkdownInlineLivePresentation.activeLines(in: source, selections: selections),
                force: needsBase)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView, model.textView === textView else { return }
            model.beginViewUpdate()
            defer { model.endViewUpdate() }
            (textView as? EditorTextView)?.unfold(containing: textView.selectedRange())
            model.selectionDidChange(textView.selectedRanges.map(\.rangeValue))
            applyProofing()
            refreshSyntax()
        }

        @MainActor func applyProofingLanguage() {
            let checker = NSSpellChecker.shared
            if let language = proofing.language.spellCheckerIdentifier {
                checker.automaticallyIdentifiesLanguages = !checker.setLanguage(language)
            } else {
                checker.automaticallyIdentifiesLanguages = true
            }
        }

        private weak var observedProofingStorage: NSTextStorage?

        /// Keeps the protected ranges of the last snapshot aligned with the text while
        /// the background analysis for the edited source is still pending.
        private func observeProofingEdits() {
            if let observedProofingStorage {
                NotificationCenter.default.removeObserver(self, name: NSTextStorage.didProcessEditingNotification,
                                                          object: observedProofingStorage)
            }
            observedProofingStorage = textView?.textStorage
            if let observedProofingStorage {
                NotificationCenter.default.addObserver(self, selector: #selector(proofingStorageDidProcessEditing(_:)),
                    name: NSTextStorage.didProcessEditingNotification, object: observedProofingStorage)
            }
        }

        @MainActor @objc private func proofingStorageDidProcessEditing(_ notification: Notification) {
            guard let storage = notification.object as? NSTextStorage,
                  storage.editedMask.contains(.editedCharacters) else { return }
            protectedProofingRanges = MarkdownProofingContext.shifted(protectedProofingRanges,
                editedRange: storage.editedRange, changeInLength: storage.changeInLength)
        }

        @MainActor func applyProofing() {
            guard let textView else { return }
            let source = textView.editorSource
            let dialect = model.markdownDialect
            let needsRanges = proofingSource != source || proofingDialect != dialect
            if usesSharedAnalysis {
                if let snapshot = sharedSnapshot, snapshot.matches(source: source, dialect: dialect) {
                    if needsRanges {
                        proofingSource = source
                        proofingDialect = snapshot.dialect
                        proofingSourceRanges = snapshot.proofingRanges
                    }
                }
            } else if needsRanges {
                proofingSource = source
                proofingDialect = dialect
                proofingSourceRanges = MarkdownProofingContext.protectedRanges(in: source,
                    analysis: MarkdownAnalysis(source, dialect: dialect))
            }
            // Shifting drops ranges cut by an edit. When the text is back to the analysed source
            // (an undo, or the edit retyped before a new snapshot arrived), use the exact ranges.
            if proofingSource == source { protectedProofingRanges = proofingSourceRanges }
            let location = textView.selectedRange().location
            // While the snapshot for an edited source is pending, the previous ranges stay
            // aligned through proofingStorageDidProcessEditing, and inline code or URLs typed
            // since then are found in the caret's paragraph, so prose keeps spelling and
            // correction. A pending dialect change (or no snapshot yet) still suppresses
            // correction: it can change which regions are protected anywhere in the document.
            let sourcePending = usesSharedAnalysis && proofingSource != source
            let dialectPending = usesSharedAnalysis && proofingDialect != dialect
            let protected = dialectPending
                || MarkdownProofingContext.isProtected(location, in: protectedProofingRanges)
                || (sourcePending && MarkdownProofingContext.isProtectedInParagraph(location, of: source))
            textView.isContinuousSpellCheckingEnabled = proofing.checksSpelling && !protected
            textView.isAutomaticSpellingCorrectionEnabled = proofing.correctsSpelling && !protected
            if textView.window?.firstResponder === textView { applyProofingLanguage() }
        }

        @MainActor @objc func clipViewBoundsDidChange(_ notification: Notification) {
            lineNumberRuler?.needsDisplay = true
            guard let scrollView, !isRestoringSession,
                  model.textView === textView else { return }
            model.beginViewUpdate()
            defer { model.endViewUpdate() }
            model.scrollDidChange(scrollView.contentView.bounds.origin, in: scrollView)
            // Bounds notifications can arrive during SwiftUI layout. The callback
            // also updates SwiftUI state, so deliver only the latest position later.
            guard visibleSourceChangeTask == nil else { return }
            visibleSourceChangeTask = Task { @MainActor [weak self] in
                guard let self else { return }
                self.visibleSourceChangeTask = nil
                guard !Task.isCancelled, let scrollView = self.scrollView,
                      let editor = self.textView as? EditorTextView,
                      self.model.textView === editor,
                      let location = editor.firstVisibleSourceLocation(in: scrollView) else { return }
                self.onVisibleSourceChange?(location)
            }
        }

        @MainActor func cancelVisibleSourceChange() {
            visibleSourceChangeTask?.cancel()
            visibleSourceChangeTask = nil
        }
    }
}

enum MarkdownProofingContext {
    struct ProtectedRange: Equatable, Sendable {
        let range: NSRange
        let includesEnd: Bool
    }

    private static let urlPattern = try! NSRegularExpression(pattern: #"https?://[^\s)<>\]]+"#)

    static func protectedRanges(in source: String, analysis: MarkdownAnalysis? = nil) -> [ProtectedRange] {
        let analysis = analysis ?? MarkdownAnalysis(source)
        let code = analysis.blocks.filter { $0.kind == .codeBlock }
            .map { ProtectedRange(range: $0.sourceRange, includesEnd: false) }
        return code + inlineProtectedRanges(in: source)
    }

    /// Inline code spans and URLs, which need no block analysis.
    static func inlineProtectedRanges(in source: String) -> [ProtectedRange] {
        let inline = MarkdownInlineSyntax.codeSpanRanges(in: source)
            .map { ProtectedRange(range: $0, includesEnd: false) }
        let full = NSRange(location: 0, length: (source as NSString).length)
        let urls = urlPattern.matches(in: source, range: full)
            .map { ProtectedRange(range: $0.range, includesEnd: true) }
        return inline + urls
    }

    static func isProtected(_ location: Int, in ranges: [ProtectedRange]) -> Bool {
        ranges.contains { item in
            NSLocationInRange(location, item.range) ||
                (item.includesEnd && location == NSMaxRange(item.range))
        }
    }

    /// Whether `location` sits in inline code or a URL of its own paragraph. Used while
    /// whole-document analysis is pending, so it costs one paragraph scan per keystroke.
    static func isProtectedInParagraph(_ location: Int, of source: String) -> Bool {
        let text = source as NSString
        guard location >= 0, location <= text.length else { return false }
        let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
        let ranges = inlineProtectedRanges(in: text.substring(with: paragraph)).map {
            ProtectedRange(range: NSRange(location: $0.range.location + paragraph.location,
                                          length: $0.range.length), includesEnd: $0.includesEnd)
        }
        return isProtected(location, in: ranges)
    }

    /// Realigns ranges after a character edit reported by NSTextStorage. `editedRange` is in
    /// post-edit coordinates; the replaced pre-edit range had `editedRange.length - changeInLength`
    /// characters. Ranges containing the edit grow or shrink, ranges after it move, and ranges
    /// cut by the edit are dropped until the next snapshot arrives.
    static func shifted(_ ranges: [ProtectedRange], editedRange: NSRange,
                        changeInLength delta: Int) -> [ProtectedRange] {
        let replaced = NSRange(location: editedRange.location, length: max(0, editedRange.length - delta))
        return ranges.compactMap { item in
            let range = item.range
            let end = NSMaxRange(range)
            let before = item.includesEnd ? end < replaced.location : end <= replaced.location
            if before { return item }
            if range.location >= NSMaxRange(replaced) {
                return ProtectedRange(range: NSRange(location: range.location + delta, length: range.length),
                                      includesEnd: item.includesEnd)
            }
            let inside = replaced.location > range.location && NSMaxRange(replaced) <= end
            let appended = item.includesEnd && replaced.location == end && replaced.length == 0
            guard inside || appended else { return nil }
            let length = range.length + delta
            guard length > 0 else { return nil }
            return ProtectedRange(range: NSRange(location: range.location, length: length),
                                  includesEnd: item.includesEnd)
        }
    }
}

private final class EditorScrollView: NSScrollView {
    var onWindowAttached: (() -> Void)?
    var onLayout: (() -> Void)?
    var onManualScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onManualScroll?()
        super.scrollWheel(with: event)
    }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onWindowAttached?() }
    }
}

extension NSTextView {
    var editorSource: String { (self as? EditorTextView)?.sourceText ?? string }
}

final class EditorTextView: NSTextView {
    private var cachedSource: String?
    private var observesSourceEdits = false
    private var pendingCharacterEdit: (range: NSRange, delta: Int)?
    private(set) var sourceRevision = 0
    private(set) var sourceReadCount = 0

    var sourceText: String {
        if let cachedSource { return cachedSource }
        var source = super.string
        source.makeContiguousUTF8()
        sourceReadCount += 1
        cachedSource = source
        return source
    }

    convenience init() { self.init(frame: .zero) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        observeSourceEdits()
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        observeSourceEdits()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        observeSourceEdits()
    }

    private func observeSourceEdits() {
        guard !observesSourceEdits else { return }
        observesSourceEdits = true
        NotificationCenter.default.addObserver(self, selector: #selector(sourceStorageDidChange(_:)),
            name: NSTextStorage.didProcessEditingNotification, object: textStorage)
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let allowed = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if allowed, let replacementString {
            pendingCharacterEdit = (affectedCharRange, replacementString.utf16.count - affectedCharRange.length)
        }
        return allowed
    }

    @objc private func sourceStorageDidChange(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage,
              storage.editedMask.contains(.editedCharacters) else { return }
        let expected = pendingCharacterEdit
        pendingCharacterEdit = nil
        commandModel?.sourceStorageDidChange(range: expected?.range ?? NSRange(location: 0, length: 0), delta: expected?.delta ?? 0,
            undoing: expected == nil || undoManager?.isUndoing == true || undoManager?.isRedoing == true)
        cachedSource = nil
        sourceRevision += 1
        refreshPlaceholderVisibility()
    }

    /// Guidance drawn while the document is empty. It is never part of the text, so it is not
    /// saved, copied, or read back as content (#28).
    var placeholder: String? {
        didSet {
            guard placeholder != oldValue else { return }
            setAccessibilityPlaceholderValue(placeholder)
            needsDisplay = true
        }
    }
    private var drewPlaceholder = false

    var showsPlaceholder: Bool {
        guard let placeholder, !placeholder.isEmpty else { return false }
        return (textStorage?.length ?? 0) == 0 && !hasMarkedText()
    }

    private func refreshPlaceholderVisibility() {
        guard showsPlaceholder != drewPlaceholder else { return }
        needsDisplay = true
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        refreshPlaceholderVisibility()
    }

    private func drawPlaceholder() {
        drewPlaceholder = showsPlaceholder
        guard drewPlaceholder, let placeholder else { return }
        let padding = textContainer?.lineFragmentPadding ?? 0
        let origin = NSPoint(x: textContainerOrigin.x + padding, y: textContainerOrigin.y)
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.placeholderTextColor]
        if let font = font ?? typingAttributes[.font] as? NSFont { attributes[.font] = font }
        if let paragraph = defaultParagraphStyle { attributes[.paragraphStyle] = paragraph }
        let width = max(0, bounds.width - origin.x - textContainerInset.width - padding)
        (placeholder as NSString).draw(with: NSRect(origin: origin, size: NSSize(width: width, height: bounds.height)),
                                       options: [.usesLineFragmentOrigin], attributes: attributes)
    }

    var onFocused: (() -> Void)?
    var onBlurred: (() -> Void)?
    weak var commandModel: MarkdownEditorModel?
    var imageImportMode: ImageImportMode = .managedCopy
    var onImageDrop: ((URL, Int) -> Void)?
    var onImagePaste: ((Data) -> Void)?
    var imagePasteboard: NSPasteboard = .general
    var hoverDocumentContext = DocumentContext(fileURL: nil)
    var loadsExternalLinkPreviews = false
    private let linkHover = MarkdownLinkHoverPopover()
    private var hoverTrackingArea: NSTrackingArea?
    private var hoverRevision = -1
    private var hoverLinks: [MarkdownHoverLink] = []

    func cancelLinkHover() { linkHover.cancel() }
    var whitespaceOptions = EditorWhitespaceOptions()
    var whitespaceTabWidth = 4
    private var invisiblePlan: InvisibleCharacterPlan?

    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        super.updateTrackingAreas()
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let source = sourceText
        if commandModel?.usesSharedAnalysis == true {
            guard let snapshot = commandModel?.matchingSnapshot else { linkHover.cancel(); return }
            hoverLinks = snapshot.hoverLinks
        } else if hoverRevision != sourceRevision {
            hoverRevision = sourceRevision
            hoverLinks = MarkdownLinkHover.links(in: source)
        }
        guard let layoutManager, let textContainer else {
            linkHover.cancel()
            return
        }
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x,
                                     y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs else {
            linkHover.cancel()
            return
        }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard let link = hoverLinks.first(where: { NSLocationInRange(index, $0.sourceRange) }) else {
            linkHover.cancel()
            return
        }
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        guard glyphRect.insetBy(dx: -2, dy: -2).contains(point) else {
            linkHover.cancel()
            return
        }
        linkHover.show(link.url, relativeTo: glyphRect, of: self,
                       context: hoverDocumentContext, source: source,
                       loadsExternalPages: loadsExternalLinkPreviews)
    }

    override func mouseExited(with event: NSEvent) {
        linkHover.cancel()
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        linkHover.cancel()
        super.mouseDown(with: event)
    }

    static let collaborativeReadinessNotification = Notification.Name("MKTownEditor.editorReadyForCollaborativeText")
    private var readinessNotificationTask: Task<Void, Never>?

    override var isEditable: Bool {
        didSet {
            if !isEditable { readinessNotificationTask?.cancel() }
            else if !oldValue { notifyCollaborativeReadiness() }
        }
    }

    override func unmarkText() {
        super.unmarkText()
        refreshPlaceholderVisibility()
        notifyCollaborativeReadiness()
    }

    private func notifyCollaborativeReadiness() {
        readinessNotificationTask?.cancel()
        // Defer until updateNSView has finished changing the editor's state.
        readinessNotificationTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self, self.isEditable, !self.hasMarkedText() else { return }
            NotificationCenter.default.post(name: Self.collaborativeReadinessNotification, object: self)
        }
    }

    override func didChangeText() {
        linkHover.cancel()
        super.didChangeText()
    }

    func refreshInvisibles() {
        invisiblePlan = whitespaceOptions.showsCharacters || whitespaceOptions.showsIndentGuides
            ? InvisibleCharacterPlan(source: sourceText, tabWidth: max(1, whitespaceTabWidth)) : nil
        needsDisplay = true
    }
    private(set) var foldedPlans: [MarkdownFoldPlan] = [] {
        didSet { foldedHeaderLocations = Set(foldedPlans.map(\.headerLocation)) }
    }
    private(set) var foldedHeaderLocations: Set<Int> = []
    private var selectionBeforeImageDrag: NSRange?
    private var imageDropLocation: Int? {
        didSet { needsDisplay = true }
    }

    func toggleFold(at location: Int) -> Bool {
        guard let plan = MarkdownFoldPlan.at(location, in: sourceText) else { return false }
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
        let length = (sourceText as NSString).length
        layoutManager?.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: length),
            changeInLength: 0, actualCharacterRange: nil)
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
        needsDisplay = true
    }

    func firstVisibleSourceLocation(in scrollView: NSScrollView) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let visible = convert(scrollView.contentView.bounds, from: scrollView.contentView)
        let point = NSPoint(x: 0, y: max(0, visible.minY - textContainerOrigin.y))
        return min((sourceText as NSString).length,
                   layoutManager.characterIndex(for: point, in: textContainer,
                                                fractionOfDistanceBetweenInsertionPoints: nil))
    }

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome { onFocused?() }
        return didBecome
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign { onBlurred?() }
        return didResign
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

    override var rangeForUserCompletion: NSRange {
        let fallback = super.rangeForUserCompletion
        guard !hasMarkedText(), selectedRange().length == 0 else { return fallback }
        let text = sourceText as NSString
        let end = selectedRange().location
        var start = end
        while start > 0, end - start < 32 {
            let unit = text.character(at: start - 1)
            if (65...90).contains(unit) || (97...122).contains(unit) ||
                (48...57).contains(unit) || unit == 95 || unit == 43 || unit == 45 {
                start -= 1
            } else { break }
        }
        guard start > 0, text.character(at: start - 1) == 58 else { return fallback }
        return NSRange(location: start - 1, length: end - start + 1)
    }

    override func completions(forPartialWordRange charRange: NSRange,
                              indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        let matches = MarkdownEmoji.completions(in: sourceText, range: charRange)
        if !matches.isEmpty {
            index.pointee = 0
            return matches
        }
        return super.completions(forPartialWordRange: charRange, indexOfSelectedItem: index)
    }

    override func paste(_ sender: Any?) {
        guard isEditable, !hasMarkedText(), selectedRanges.count == 1 else {
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
        drawPlaceholder()
        drawInvisibles(in: dirtyRect)
        guard let imageDropLocation,
              let indicator = imageDropIndicatorRect(at: imageDropLocation),
              indicator.intersects(dirtyRect) else { return }
        NSColor.controlAccentColor.setFill()
        indicator.fill()
    }

    private func drawInvisibles(in dirtyRect: NSRect) {
        guard !hasMarkedText(), let invisiblePlan, let layoutManager, let textContainer else { return }
        let containerRect = dirtyRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: containerRect, in: textContainer)
        let visible = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let start = visible.location
        let end = NSMaxRange(visible)
        func firstVisible<Item>(_ items: [Item], location: (Item) -> Int) -> Int {
            var low = 0
            var high = items.count
            while low < high {
                let middle = (low + high) / 2
                if location(items[middle]) < start { low = middle + 1 }
                else { high = middle }
            }
            return low
        }
        func glyph(_ location: Int) -> (NSRange, NSRect)? {
            let range = layoutManager.glyphRange(forCharacterRange: NSRange(location: location, length: 1),
                                                 actualCharacterRange: nil)
            guard range.length > 0 else { return nil }
            let rect = layoutManager.boundingRect(forGlyphRange: range, in: textContainer)
            return (range, rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y))
        }
        if whitespaceOptions.showsIndentGuides {
            let first = firstVisible(invisiblePlan.guides, location: { $0 })
            for location in invisiblePlan.guides[first...].prefix(while: { $0 < end }) {
                guard let (range, rect) = glyph(location) else { continue }
                let line = layoutManager.lineFragmentRect(forGlyphAt: range.location,
                                                          effectiveRange: nil)
                let path = NSBezierPath()
                let x = rect.maxX - 1
                path.move(to: NSPoint(x: x, y: line.minY + textContainerOrigin.y))
                path.line(to: NSPoint(x: x, y: line.maxY + textContainerOrigin.y))
                path.lineWidth = 1
                NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setStroke()
                path.stroke()
            }
        }
        if whitespaceOptions.showsCharacters {
            let font = NSFont.systemFont(ofSize: 9)
            let first = firstVisible(invisiblePlan.marks, location: { $0.location })
            for mark in invisiblePlan.marks[first...].prefix(while: { $0.location < end }) {
                guard let (_, rect) = glyph(mark.location) else { continue }
                let symbol: String
                let color: NSColor
                switch mark.kind {
                case .space: symbol = "·"; color = .tertiaryLabelColor
                case .trailingSpace: symbol = "·"; color = .systemOrange
                case .tab: symbol = "→"; color = .tertiaryLabelColor
                case .newline: symbol = "¶"; color = .tertiaryLabelColor
                }
                let attributes: [NSAttributedString.Key: Any] = [.font: font,
                    .foregroundColor: color.withAlphaComponent(0.75)]
                let size = (symbol as NSString).size(withAttributes: attributes)
                let x = mark.kind == .newline ? rect.maxX : rect.midX - size.width / 2
                (symbol as NSString).draw(at: NSPoint(x: x, y: rect.minY), withAttributes: attributes)
            }
        }
    }

    func imageDropIndicatorRect(at location: Int) -> NSRect? {
        guard let window, location >= 0,
              location <= (sourceText as NSString).length else { return nil }
        let screen = firstRect(forCharacterRange: NSRange(location: location, length: 0),
                               actualRange: nil)
        let local = convert(window.convertFromScreen(screen), from: nil)
        return NSRect(x: local.minX, y: local.minY, width: 2,
                      height: max(local.height, font?.pointSize ?? 13))
    }

    func dropInsertionLocation(for windowPoint: NSPoint) -> Int {
        guard let layoutManager, let textContainer else { return (sourceText as NSString).length }
        let local = convert(windowPoint, from: nil)
        let containerPoint = NSPoint(x: local.x - textContainerOrigin.x,
                                     y: local.y - textContainerOrigin.y)
        return min((sourceText as NSString).length,
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
            let plainPaste = NSMenuItem(title: String(localized: "URL をそのまま貼り付け"),
                                        action: #selector(pasteURLAsPlainText(_:)), keyEquivalent: "")
            plainPaste.target = self
            menu.addItem(plainPaste)
        }
        for group in EditorCommand.contextGroups {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for command in group { add(command, to: menu) }
        }
        menu.addItem(.separator())
        let markdownMenu = NSMenu(title: "Markdown")
        let headingItem = NSMenuItem(title: String(localized: "見出しレベル"), action: nil, keyEquivalent: "")
        let headingMenu = NSMenu(title: String(localized: "見出しレベル"))
        for level in 0...6 {
            add(.heading(level: level), to: headingMenu)
        }
        headingItem.submenu = headingMenu
        markdownMenu.addItem(headingItem)
        let codeItem = NSMenuItem(title: String(localized: "コードブロック"), action: nil, keyEquivalent: "")
        let codeMenu = NSMenu(title: String(localized: "コードブロック"))
        add(.codeBlock(language: nil), to: codeMenu)
        for language in MarkdownCodeLanguage.allCases {
            add(.codeBlock(language: language), to: codeMenu)
        }
        codeItem.submenu = codeMenu
        markdownMenu.addItem(codeItem)
        markdownMenu.addItem(.separator())
        for command in EditorCommand.contextMarkdown {
            add(command, to: markdownMenu)
        }
        let markdownItem = NSMenuItem(title: "Markdown", action: nil, keyEquivalent: "")
        markdownItem.submenu = markdownMenu
        menu.addItem(markdownItem)
        return menu
    }

    private func add(_ command: EditorCommand, to menu: NSMenu) {
        let item = NSMenuItem(title: command.title, action: #selector(performMarkdownCommand(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = command
        item.isEnabled = command.canExecute(in: commandModel)
        menu.addItem(item)
    }

    /// Menus validate their items again just before showing them, so availability must come from here.
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(performMarkdownCommand(_:)) {
            guard let command = menuItem.representedObject as? EditorCommand else { return false }
            return command.canExecute(in: commandModel)
        }
        return super.validateMenuItem(menuItem)
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
