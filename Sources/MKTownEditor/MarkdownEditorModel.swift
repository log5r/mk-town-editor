import AppKit
import Combine

struct EditorViewport: Equatable {
    let topFraction: Double
    let visibleFraction: Double
}

@MainActor
final class MarkdownEditorModel: ObservableObject {
    private struct EditorState: Equatable {
        var selectedRange = NSRange(location: 0, length: 0)
        var selectedRanges = [NSRange(location: 0, length: 0)]
        var hasActiveEditor = false
        var viewport = EditorViewport(topFraction: 0, visibleFraction: 1)
    }

    @Published private var editorState = EditorState()
    private var pendingEditorState: EditorState?
    private var publicationTask: Task<Void, Never>?
    private var viewUpdateDepth = 0

    private(set) var selectedRange: NSRange {
        get { (pendingEditorState ?? editorState).selectedRange }
        set { updateEditorState { $0.selectedRange = newValue } }
    }
    private(set) var selectedRanges: [NSRange] {
        get { (pendingEditorState ?? editorState).selectedRanges }
        set { updateEditorState { $0.selectedRanges = newValue } }
    }
    private(set) var hasActiveEditor: Bool {
        get { (pendingEditorState ?? editorState).hasActiveEditor }
        set { updateEditorState { $0.hasActiveEditor = newValue } }
    }
    private(set) var viewport: EditorViewport {
        get { (pendingEditorState ?? editorState).viewport }
        set { updateEditorState { $0.viewport = newValue } }
    }

    // AppKit session state stays synchronous; SwiftUI observes it after its update ends.
    func beginViewUpdate() { viewUpdateDepth += 1 }
    func endViewUpdate() { viewUpdateDepth -= 1 }

    private func updateEditorState(_ update: (inout EditorState) -> Void) {
        var next = pendingEditorState ?? editorState
        update(&next)
        guard next != (pendingEditorState ?? editorState) else { return }
        if viewUpdateDepth > 0 || publicationTask != nil {
            pendingEditorState = next
            guard publicationTask == nil else { return }
            publicationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let next = self.pendingEditorState
                self.pendingEditorState = nil
                self.publicationTask = nil
                if let next, next != self.editorState { self.editorState = next }
            }
        } else if next != editorState {
            editorState = next
        }
    }

    @Published var linkDraft: MarkdownLinkDraft?
    @Published var imageDraft: MarkdownImageDraft?
    @Published var tableDraft: MarkdownTableDraft?
    @Published var tableGridDraft: MarkdownTableGridDraft?
    @Published var showingSnippetPicker = false
    @Published var showingCommandPalette = false
    weak var textView: NSTextView?
    private var transitionSelections: [NSRange]?
    private(set) var scrollOrigin = NSPoint.zero
    private(set) var shouldRestoreFocus = false
    private var pendingNavigationLocation: Int?
    private var selectionHistory: [NSRange] = []
    private var selectionHistoryText: String?
    private var expectedSelection: NSRange?
    var listIndentWidth = 2
    var codeIndentWidth = 4
    var tableAddsRowOnTab = true
    var tablePasteboard: NSPasteboard = .general
    var snippets: [EditorSnippet] = []
    private struct SnippetSession {
        var snapshot: String
        var placeholders: [NSRange]
        var index: Int
        var finalCaret: Int
    }
    private var snippetSession: SnippetSession?

    func connect(_ textView: NSTextView, scrollView: NSScrollView? = nil) {
        self.textView = textView
        transitionSelections = nil
        hasActiveEditor = true
        let length = (textView.string as NSString).length
        let restored = selectedRanges.map { range in
            let location = min(max(0, range.location), length)
            return NSRange(location: location, length: min(max(0, range.length), length - location))
        }
        textView.setSelectedRanges(restored.map(NSValue.init(range:)), affinity: .upstream,
                                   stillSelecting: false)
        selectedRanges = restored
        selectedRange = restored[0]
        if let scrollView { restoreScroll(in: scrollView) }
        if pendingNavigationLocation != nil {
            textView.scrollRangeToVisible(textView.selectedRange())
            pendingNavigationLocation = nil
        }
    }

    func disconnect(_ textView: NSTextView, scrollView: NSScrollView? = nil) {
        guard self.textView === textView else { return }
        let selections = transitionSelections ?? textView.selectedRanges.map(\.rangeValue)
        if let first = selections.first {
            selectedRange = first
            selectedRanges = selections
        }
        if let scrollView { scrollOrigin = scrollView.contentView.bounds.origin }
        if let window = textView.window {
            shouldRestoreFocus = window.firstResponder === textView
        }
        self.textView = nil
        hasActiveEditor = false
    }

    func prepareForViewTransition() {
        guard let textView else { return }
        transitionSelections = textView.selectedRanges.map(\.rangeValue)
    }

    func scrollDidChange(_ origin: NSPoint, in scrollView: NSScrollView) {
        scrollOrigin = origin
        let visible = max(1, scrollView.contentView.bounds.height)
        let document = max(visible, scrollView.documentView?.bounds.height ?? visible)
        let next = EditorViewport(topFraction: Double(min(1, max(0, origin.y / document))),
                                  visibleFraction: Double(min(1, visible / document)))
        if abs(next.topFraction - viewport.topFraction) >= 0.001 ||
            abs(next.visibleFraction - viewport.visibleFraction) >= 0.001 {
            viewport = next
        }
    }

    func restorePosition(selection: NSRange, scrollX: Double = 0, scrollY: Double) {
        let length = textView.map { ($0.string as NSString).length } ?? Int.max
        let location = min(max(0, selection.location), length)
        let range = NSRange(location: location,
                            length: min(max(0, selection.length), length - location))
        selectedRange = range
        selectedRanges = [range]
        scrollOrigin = NSPoint(x: max(0, scrollX), y: max(0, scrollY))
        if let textView {
            textView.setSelectedRange(range)
            if let scrollView = textView.enclosingScrollView { restoreScroll(in: scrollView) }
        }
    }

    func restoreScroll(in scrollView: NSScrollView) {
        scrollView.contentView.scroll(to: scrollOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollDidChange(scrollView.contentView.bounds.origin, in: scrollView)
    }

    func editorDidGainFocus(_ textView: NSTextView) {
        guard self.textView === textView else { return }
        shouldRestoreFocus = true
    }

    func restoreFocusIfNeeded(_ textView: NSTextView) {
        guard self.textView === textView, shouldRestoreFocus else { return }
        textView.window?.makeFirstResponder(textView)
    }

    func selectionDidChange(_ range: NSRange) { selectionDidChange([range]) }

    func selectionDidChange(_ ranges: [NSRange]) {
        guard transitionSelections == nil else { return }
        guard let range = ranges.first else { return }
        let unchanged = selectedRange == range
        selectedRange = range
        selectedRanges = ranges
        if range == expectedSelection {
            expectedSelection = nil
        } else if !unchanged {
            selectionHistory.removeAll()
            selectionHistoryText = nil
        }
    }

    func expandSelection() {
        guard let textView, !textView.hasMarkedText() else { return }
        if selectionHistoryText != textView.string { selectionHistory.removeAll() }
        let current = textView.selectedRange()
        guard let next = MarkdownSelectionExpansion.next(in: textView.string,
            selection: current) else { return }
        selectionHistoryText = textView.string
        selectionHistory.append(current)
        expectedSelection = next
        selectAndReveal(next)
    }

    func shrinkSelection() {
        guard let textView, !textView.hasMarkedText(),
              selectionHistoryText == textView.string,
              let previous = selectionHistory.popLast() else { return }
        expectedSelection = previous
        selectAndReveal(previous)
    }

    func toggleFold() {
        guard let textView = textView as? EditorTextView,
              !textView.hasMarkedText() else { return }
        _ = textView.toggleFold(at: textView.selectedRange().location)
    }

    func unfoldAll() {
        (textView as? EditorTextView)?.clearFolds()
    }

    func presentSnippetPicker() {
        guard canExecuteCommand, !snippets.isEmpty else { return }
        showingSnippetPicker = true
    }

    func expandSnippetTrigger() -> Bool {
        guard canExecuteCommand, let textView,
              textView.selectedRange().length == 0 else { return false }
        let selection = textView.selectedRange()
        for snippet in snippets.sorted(by: { $0.trigger.count > $1.trigger.count }) where !snippet.trigger.isEmpty {
            guard let plan = MarkdownSnippetPlan.make(snippet, in: textView.string,
                selection: selection), plan.edit.range.length > 0 else { continue }
            return insertSnippet(snippet)
        }
        return false
    }

    @discardableResult
    func insertSnippet(_ snippet: EditorSnippet) -> Bool {
        guard let textView, let storage = textView.textStorage,
              canExecuteCommand,
              let plan = MarkdownSnippetPlan.make(snippet, in: textView.string,
                  selection: textView.selectedRange()),
              perform(plan.edit, in: textView, storage: storage, focusEditor: true) else { return false }
        snippetSession = plan.placeholders.isEmpty ? nil : SnippetSession(
            snapshot: textView.string, placeholders: plan.placeholders,
            index: 0, finalCaret: plan.finalCaret)
        showingSnippetPicker = false
        return true
    }

    func advanceSnippetPlaceholder(backwards: Bool) -> Bool {
        guard let textView, textView.selectedRanges.count == 1, !textView.hasMarkedText(),
              var session = snippetSession else { return false }
        guard updateSnippetSession(&session, to: textView.string) else {
            snippetSession = nil
            return false
        }
        let current = session.placeholders[session.index]
        let selected = textView.selectedRange()
        guard selected.location >= current.location,
              NSMaxRange(selected) <= NSMaxRange(current) else {
            snippetSession = nil
            return false
        }
        if backwards {
            guard session.index > 0 else { return true }
            session.index -= 1
            snippetSession = session
            selectAndReveal(session.placeholders[session.index])
        } else if session.index + 1 < session.placeholders.count {
            session.index += 1
            snippetSession = session
            selectAndReveal(session.placeholders[session.index])
        } else {
            snippetSession = nil
            selectAndReveal(NSRange(location: session.finalCaret, length: 0))
        }
        return true
    }

    private func updateSnippetSession(_ session: inout SnippetSession, to text: String) -> Bool {
        guard text != session.snapshot else { return true }
        let old = session.snapshot as NSString
        let new = text as NSString
        var prefix = 0
        while prefix < min(old.length, new.length),
              old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < min(old.length, new.length) - prefix,
              old.character(at: old.length - suffix - 1) == new.character(at: new.length - suffix - 1) {
            suffix += 1
        }
        let removedEnd = old.length - suffix
        let delta = new.length - old.length
        let current = session.placeholders[session.index]
        guard prefix >= current.location, removedEnd <= NSMaxRange(current) else { return false }
        for index in session.placeholders.indices {
            if index == session.index {
                session.placeholders[index].length += delta
            } else if session.placeholders[index].location >= removedEnd {
                session.placeholders[index].location += delta
            }
        }
        if session.finalCaret >= removedEnd { session.finalCaret += delta }
        session.snapshot = text
        return true
    }

    func navigate(to sourceLocation: Int) {
        let location = max(0, sourceLocation)
        guard let textView else {
            selectedRange = NSRange(location: location, length: 0)
            selectedRanges = [selectedRange]
            pendingNavigationLocation = location
            return
        }
        pendingNavigationLocation = nil
        let range = NSRange(location: min(location, (textView.string as NSString).length), length: 0)
        (textView as? EditorTextView)?.unfold(containing: range)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.window?.makeFirstResponder(textView)
        selectedRange = range
        selectedRanges = [range]
    }

    func selectAndReveal(_ sourceRange: NSRange) {
        let location = max(0, sourceRange.location)
        guard let textView else {
            selectedRange = NSRange(location: location, length: max(0, sourceRange.length))
            selectedRanges = [selectedRange]
            pendingNavigationLocation = location
            return
        }
        let length = (textView.string as NSString).length
        let safeLocation = min(location, length)
        let range = NSRange(location: safeLocation,
                            length: min(max(0, sourceRange.length), length - safeLocation))
        (textView as? EditorTextView)?.unfold(containing: range)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.window?.makeFirstResponder(textView)
        selectedRange = range
        selectedRanges = [range]
    }

    func scrollToTop(sourceLocation: Int) {
        guard let textView, let scrollView = textView.enclosingScrollView,
              let layoutManager = textView.layoutManager,
              textView.textContainer != nil,
              layoutManager.numberOfGlyphs > 0 else { return }
        let length = (textView.string as NSString).length
        let location = min(max(sourceLocation, 0), max(length - 1, 0))
        let glyph = min(layoutManager.glyphIndexForCharacter(at: location),
                        layoutManager.numberOfGlyphs - 1)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let clipView = scrollView.contentView
        let y = max(0, line.minY + textView.textContainerOrigin.y)
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clipView)
    }

    var canExecuteCommand: Bool {
        hasActiveEditor && textView?.isEditable == true && textView?.hasMarkedText() == false &&
            textView?.selectedRanges.count == 1
    }

    var canExecuteMultiSelectionCommand: Bool {
        hasActiveEditor && textView?.isEditable == true && textView?.hasMarkedText() == false &&
            (textView?.selectedRanges.count ?? 0) > 1
    }

    var canAddNextOccurrence: Bool {
        guard let textView, !textView.hasMarkedText() else { return false }
        return MarkdownSelectionOccurrences.addingNext(in: textView.string,
            selections: textView.selectedRanges.map(\.rangeValue)) != nil
    }

    func addNextOccurrence() {
        guard let textView, !textView.hasMarkedText(),
              let selections = MarkdownSelectionOccurrences.addingNext(in: textView.string,
                  selections: textView.selectedRanges.map(\.rangeValue)) else { return }
        textView.setSelectedRanges(selections.map(NSValue.init(range:)),
                                   affinity: .upstream, stillSelecting: false)
        if let last = selections.last { textView.scrollRangeToVisible(last) }
        textView.window?.makeFirstResponder(textView)
    }

    func apply(_ style: MarkdownFormattingStyle) {
        guard let textView, let storage = textView.textStorage,
              textView.isEditable, !textView.hasMarkedText() else { return }
        let ranges = textView.selectedRanges.map(\.rangeValue)
        if ranges.count > 1 {
            guard let plan = MarkdownMultiSelectionPlan.make(style: style, source: textView.string,
                                                             selections: ranges) else { return }
            perform(plan, in: textView, storage: storage)
            return
        }
        let edit = MarkdownFormatter.apply(style, to: textView.string, selection: textView.selectedRange())
        perform(edit, in: textView, storage: storage, focusEditor: true)
    }

    private func perform(_ plan: MarkdownMultiSelectionPlan, in textView: NSTextView,
                         storage: NSTextStorage) {
        let edit = plan.edit
        guard textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textView.breakUndoCoalescing()
        storage.replaceCharacters(in: edit.range, with: edit.replacement)
        selectionHistory.removeAll()
        selectionHistoryText = nil
        textView.didChangeText()
        textView.setSelectedRanges(plan.selections.map(NSValue.init(range:)),
                                   affinity: .upstream, stillSelecting: false)
        textView.breakUndoCoalescing()
        textView.window?.makeFirstResponder(textView)
    }

    func toggleTaskCompletion() {
        guard let textView, let storage = textView.textStorage,
              textView.isEditable, !textView.hasMarkedText(),
              let edit = MarkdownFormatter.toggleTasks(in: textView.string,
                                                       selection: textView.selectedRange()) else { return }
        perform(edit, in: textView, storage: storage, focusEditor: true)
    }

    /// Returns true when Return belongs to a Markdown line, even if AppKit rejects the edit.
    func continueListOrQuote() -> Bool {
        guard let textView, let storage = textView.textStorage,
              textView.isEditable, !textView.hasMarkedText(), textView.selectedRanges.count == 1,
              let edit = MarkdownLineContinuation.edit(in: textView.string,
                                                       selection: textView.selectedRange()) else { return false }
        perform(edit, in: textView, storage: storage, focusEditor: true)
        return true
    }

    @discardableResult
    func changeIndentation(_ direction: MarkdownIndentation.Direction) -> Bool {
        guard let textView, let storage = textView.textStorage,
              textView.isEditable, !textView.hasMarkedText(), textView.selectedRanges.count == 1,
              let edit = MarkdownIndentation.edit(in: textView.string,
                                                  selection: textView.selectedRange(),
                                                  direction: direction,
                                                  listIndentWidth: listIndentWidth,
                                                  codeIndentWidth: codeIndentWidth) else { return false }
        perform(edit, in: textView, storage: storage, focusEditor: true)
        return true
    }

    func completeSymbol(_ typed: String, replacementRange: NSRange) -> Bool {
        guard replacementRange.location == NSNotFound,
              let textView, let storage = textView.textStorage,
              textView.isEditable, !textView.hasMarkedText(), textView.selectedRanges.count == 1,
              let edit = MarkdownSymbolCompletion.edit(in: textView.string,
                                                       selection: textView.selectedRange(),
                                                       typed: typed) else { return false }
        perform(edit, in: textView, storage: storage, focusEditor: true)
        return true
    }

    func toggleTask(at sourceLocation: Int) {
        guard let textView, let storage = textView.textStorage,
              textView.isEditable, !textView.hasMarkedText(),
              let edit = MarkdownFormatter.toggleTasks(in: textView.string,
                                                       selection: NSRange(location: sourceLocation, length: 0)) else { return }
        perform(edit, in: textView, storage: storage, focusEditor: false)
    }

    func presentLinkEditor() {
        guard canExecuteCommand, let textView else { return }
        linkDraft = MarkdownLinkSyntax.draft(in: textView.string, selection: textView.selectedRange())
    }

    func convertLinkForm() {
        guard canExecuteCommand, let textView, let storage = textView.textStorage,
              let edit = MarkdownReferenceConversion.edit(in: textView.string,
                  selection: textView.selectedRange()) else { return }
        _ = perform(edit, in: textView, storage: storage, focusEditor: true)
    }

    func moveSection(at headingLocation: Int, direction: SectionMoveDirection) {
        guard canExecuteCommand, let textView, let storage = textView.textStorage,
              let edit = MarkdownSectionMove.edit(in: textView.string,
                  headingLocation: headingLocation, direction: direction) else { return }
        _ = perform(edit, in: textView, storage: storage, focusEditor: true)
    }

    func changeSectionLevel(at headingLocation: Int, by delta: Int) {
        guard canExecuteCommand, let textView, let storage = textView.textStorage,
              let edit = MarkdownSectionLevel.edit(in: textView.string,
                  headingLocation: headingLocation, by: delta) else { return }
        _ = perform(edit, in: textView, storage: storage, focusEditor: true)
    }

    func commitLink(label: String, destination: String, title: String) -> Bool {
        guard let draft = linkDraft, let textView, let storage = textView.textStorage,
              textView.isEditable, !textView.hasMarkedText(),
              let edit = MarkdownLinkSyntax.edit(in: textView.string, draft: draft,
                                                 label: label, destination: destination, title: title),
              perform(edit, in: textView, storage: storage, focusEditor: true) else { return false }
        linkDraft = nil
        return true
    }

    func commitReferenceLink(label: String, referenceID: String) -> Bool {
        guard let draft = linkDraft, let textView, let storage = textView.textStorage,
              textView.isEditable, !textView.hasMarkedText(),
              let edit = MarkdownLinkSyntax.referenceEdit(in: textView.string, draft: draft,
                                                          label: label, referenceID: referenceID),
              perform(edit, in: textView, storage: storage, focusEditor: true) else { return false }
        linkDraft = nil
        return true
    }

    @discardableResult
    func pasteURLAsLink(_ pastedText: String) -> Bool {
        guard let textView, let storage = textView.textStorage,
              textView.isEditable, !textView.hasMarkedText(), textView.selectedRanges.count == 1,
              let edit = MarkdownURLPaste.edit(in: textView.string,
                                               selection: textView.selectedRange(),
                                               pastedText: pastedText) else { return false }
        return perform(edit, in: textView, storage: storage, focusEditor: true)
    }

    func presentImageEditor() {
        guard canExecuteCommand, let textView else { return }
        imageDraft = MarkdownLinkSyntax.imageDraft(in: textView.string, selection: textView.selectedRange())
    }

    func presentTableEditor() {
        guard canExecuteCommand, let textView else { return }
        tableDraft = MarkdownTableInsertion.draft(in: textView.string,
                                                  selection: textView.selectedRange())
    }

    func commitTable(rows: Int, columns: Int) -> Bool {
        guard let draft = tableDraft, let textView, let storage = textView.textStorage,
              textView.isEditable, !textView.hasMarkedText(),
              let edit = MarkdownTableInsertion.edit(in: textView.string, draft: draft,
                                                     rows: rows, columns: columns),
              perform(edit, in: textView, storage: storage, focusEditor: true) else { return false }
        tableDraft = nil
        return true
    }

    var canPresentTableGrid: Bool {
        guard canExecuteCommand, let textView else { return false }
        return MarkdownTableEditing.gridDraft(in: textView.string,
                                               selection: textView.selectedRange()) != nil
    }

    func presentTableGrid() {
        guard canExecuteCommand, let textView else { return }
        tableGridDraft = MarkdownTableEditing.gridDraft(in: textView.string,
                                                        selection: textView.selectedRange())
    }

    func commitTableGrid(header: [String], rows: [[String]],
                         alignments: [MarkdownTable.Alignment]) -> Bool {
        if let draft = tableGridDraft, let textView,
           textView.string == draft.originalText,
           header == draft.header, rows == draft.rows, alignments == draft.alignments {
            tableGridDraft = nil
            return true
        }
        guard let draft = tableGridDraft, let textView, let storage = textView.textStorage,
              textView.isEditable, !textView.hasMarkedText(),
              let edit = MarkdownTableEditing.gridEdit(in: textView.string, draft: draft,
                                                       header: header, rows: rows,
                                                       alignments: alignments),
              perform(edit, in: textView, storage: storage, focusEditor: true) else { return false }
        tableGridDraft = nil
        return true
    }

    func canEditTable(_ operation: MarkdownTableOperation) -> Bool {
        guard canExecuteCommand, let textView else { return false }
        return MarkdownTableEditing.edit(in: textView.string,
                                         selection: textView.selectedRange(),
                                         operation: operation) != nil
    }

    var selectedTableAlignment: MarkdownTable.Alignment? {
        guard let textView else { return nil }
        return MarkdownTableEditing.alignment(in: textView.string,
                                              selection: textView.selectedRange())
    }

    @discardableResult
    func editTable(_ operation: MarkdownTableOperation) -> Bool {
        guard let textView, let storage = textView.textStorage,
              textView.isEditable, !textView.hasMarkedText(),
              let edit = MarkdownTableEditing.edit(in: textView.string,
                                                    selection: textView.selectedRange(),
                                                    operation: operation) else { return false }
        return perform(edit, in: textView, storage: storage, focusEditor: true)
    }

    func moveTableCell(backwards: Bool) -> Bool {
        guard let textView, let storage = textView.textStorage,
              textView.isEditable, !textView.hasMarkedText(), textView.selectedRanges.count == 1,
              let action = MarkdownTableEditing.tabAction(in: textView.string,
                  selection: textView.selectedRange(), backwards: backwards,
                  addsRowAtEnd: tableAddsRowOnTab) else { return false }
        switch action {
        case let .select(range):
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            selectedRange = range
            selectedRanges = [range]
        case let .edit(edit):
            perform(edit, in: textView, storage: storage, focusEditor: true)
        }
        return true
    }

    func convertClipboardTable() {
        guard canExecuteCommand, let textView,
              let clipboard = tablePasteboard.string(forType: .string) else { return }
        let original = textView.string
        let selection = textView.selectedRange()
        guard let conversion = MarkdownTableInsertion.conversion(in: original,
            selection: selection, delimitedText: clipboard) else {
            if let window = textView.window {
                let alert = NSAlert()
                alert.messageText = String(localized: "TSV・CSVを表に変換できません")
                alert.informativeText = String(localized: "区切り文字、引用符、行の内容を確認してください。")
                alert.beginSheetModal(for: window)
            }
            return
        }
        let applyConversion = { [weak self, weak textView] in
            guard let self, let textView, let storage = textView.textStorage,
                  textView.string == original, textView.selectedRange() == selection,
                  textView.isEditable, !textView.hasMarkedText() else { return }
            self.perform(conversion.edit, in: textView, storage: storage, focusEditor: true)
        }
        guard conversion.hasMultilineCells, let window = textView.window else {
            applyConversion()
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "セル内改行を変換します")
        alert.informativeText = String(localized: "Markdown表ではセル内改行を直接表せないため、<br>に置き換えます。")
        alert.addButton(withTitle: "変換")
        alert.addButton(withTitle: "キャンセル")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { applyConversion() }
        }
    }

    func commitImage(alt: String, destination: String, title: String,
                     width: Int? = nil) -> Bool {
        guard let draft = imageDraft, let textView, let storage = textView.textStorage,
              textView.isEditable, !textView.hasMarkedText(),
              let edit = MarkdownLinkSyntax.imageEdit(in: textView.string, draft: draft,
                                                      alt: alt, destination: destination,
                                                      title: title, width: width),
              perform(edit, in: textView, storage: storage, focusEditor: true) else { return false }
        imageDraft = nil
        return true
    }

    func imageDropDraft(at sourceLocation: Int) -> MarkdownImageDraft? {
        guard canExecuteCommand, let textView,
              sourceLocation >= 0,
              sourceLocation <= (textView.string as NSString).length else { return nil }
        return MarkdownLinkSyntax.imageDraft(in: textView.string,
                                             selection: NSRange(location: sourceLocation, length: 0))
    }

    func imagePasteDraft() -> MarkdownImageDraft? {
        guard canExecuteCommand, let textView else { return nil }
        return MarkdownLinkSyntax.imageDraft(in: textView.string,
                                             selection: textView.selectedRange())
    }

    func commitDroppedImage(_ draft: MarkdownImageDraft, alt: String, destination: String) -> Bool {
        guard let textView, let storage = textView.textStorage,
              textView.isEditable, !textView.hasMarkedText(),
              let edit = MarkdownLinkSyntax.imageEdit(in: textView.string, draft: draft,
                                                      alt: alt, destination: destination, title: "") else {
            return false
        }
        return perform(edit, in: textView, storage: storage, focusEditor: true)
    }

    @discardableResult
    private func perform(_ edit: MarkdownEdit, in textView: NSTextView,
                         storage: NSTextStorage, focusEditor: Bool) -> Bool {
        guard (storage.string as NSString).substring(with: edit.range) != edit.replacement else { return true }
        guard textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else {
            return false
        }
        let originalSelection = textView.selectedRange()
        textView.breakUndoCoalescing()
        storage.replaceCharacters(in: edit.range, with: edit.replacement)
        selectionHistory.removeAll()
        selectionHistoryText = nil
        textView.didChangeText()
        textView.setSelectedRange(focusEditor ? edit.selection : originalSelection)
        textView.breakUndoCoalescing()
        if focusEditor { textView.window?.makeFirstResponder(textView) }
        return true
    }

    func showFindBar() {
        performFinderAction(.showFindInterface)
    }

    func showReplaceBar() {
        performFinderAction(.showReplaceInterface)
    }

    func findNext() {
        performFinderAction(.nextMatch)
    }

    func findPrevious() {
        performFinderAction(.previousMatch)
    }

    func replaceAllMatches() {
        guard canExecuteCommand else { return }
        performFinderAction(.replaceAll)
    }

    func replaceAllInSelection() {
        guard canExecuteCommand, (textView?.selectedRange().length ?? 0) > 0 else { return }
        performFinderAction(.replaceAllInSelection)
    }

    @discardableResult
    func applyRegexEdit(_ edit: MarkdownEdit, expectedSource: String) -> Bool {
        guard let textView, let storage = textView.textStorage,
              textView.isEditable, !textView.hasMarkedText(),
              textView.string == expectedSource,
              edit.range.location >= 0,
              edit.range.location <= (expectedSource as NSString).length,
              edit.range.length >= 0,
              edit.range.length <= (expectedSource as NSString).length - edit.range.location else { return false }
        return perform(edit, in: textView, storage: storage, focusEditor: true)
    }

    /// Applies a peer edit without stealing focus or splitting a Unicode grapheme.
    @discardableResult
    func applyCollaborativeText(_ next: String, expectedSource: String) -> Bool {
        guard let textView, let storage = textView.textStorage,
              textView.isEditable, !textView.hasMarkedText(),
              textView.string == expectedSource else { return false }
        guard let change = CollaborativeTextReplacement.between(expectedSource, next) else { return true }
        let selections = textView.selectedRanges.map(\.rangeValue).map(change.mapped)
        let edit = MarkdownEdit(range: change.range, replacement: change.replacement,
                                selection: selections.first ?? NSRange(location: 0, length: 0))
        guard perform(edit, in: textView, storage: storage, focusEditor: false) else { return false }
        textView.setSelectedRanges(selections.map(NSValue.init(range:)),
                                   affinity: .upstream, stillSelecting: false)
        return true
    }

    @discardableResult
    func insertFootnote() -> Bool {
        guard let textView,
              let edit = MarkdownFootnoteInsertion.plan(in: textView.string,
                                                        selection: textView.selectedRange()) else { return false }
        return applyRegexEdit(edit, expectedSource: textView.string)
    }

    private func performFinderAction(_ action: NSTextFinder.Action) {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = action.rawValue
        textView.performTextFinderAction(item)
    }
}
