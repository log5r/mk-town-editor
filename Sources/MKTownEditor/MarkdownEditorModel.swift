import AppKit
import Combine

@MainActor
final class MarkdownEditorModel: ObservableObject {
    @Published private(set) var selectedRange = NSRange(location: 0, length: 0)
    @Published private(set) var hasActiveEditor = false
    @Published var linkDraft: MarkdownLinkDraft?
    @Published var imageDraft: MarkdownImageDraft?
    @Published var tableDraft: MarkdownTableDraft?
    weak var textView: NSTextView?
    private(set) var scrollOrigin = NSPoint.zero
    private(set) var shouldRestoreFocus = false
    private var pendingNavigationLocation: Int?
    var listIndentWidth = 2
    var codeIndentWidth = 4
    var tableAddsRowOnTab = true
    var tablePasteboard: NSPasteboard = .general

    func connect(_ textView: NSTextView, scrollView: NSScrollView? = nil) {
        self.textView = textView
        hasActiveEditor = true
        let length = (textView.string as NSString).length
        let location = min(selectedRange.location, length)
        let restoredRange = NSRange(
            location: location,
            length: min(selectedRange.length, length - location)
        )
        textView.setSelectedRange(restoredRange)
        selectedRange = restoredRange
        if let scrollView { restoreScroll(in: scrollView) }
        if pendingNavigationLocation != nil {
            textView.scrollRangeToVisible(textView.selectedRange())
            pendingNavigationLocation = nil
        }
    }

    func disconnect(_ textView: NSTextView, scrollView: NSScrollView? = nil) {
        guard self.textView === textView else { return }
        selectedRange = textView.selectedRange()
        if let scrollView { scrollOrigin = scrollView.contentView.bounds.origin }
        if let window = textView.window {
            shouldRestoreFocus = window.firstResponder === textView
        }
        self.textView = nil
        hasActiveEditor = false
    }

    func scrollDidChange(_ origin: NSPoint) {
        scrollOrigin = origin
    }

    func restorePosition(selection: NSRange, scrollX: Double = 0, scrollY: Double) {
        let length = textView.map { ($0.string as NSString).length } ?? Int.max
        let location = min(max(0, selection.location), length)
        let range = NSRange(location: location,
                            length: min(max(0, selection.length), length - location))
        selectedRange = range
        scrollOrigin = NSPoint(x: max(0, scrollX), y: max(0, scrollY))
        if let textView {
            textView.setSelectedRange(range)
            if let scrollView = textView.enclosingScrollView { restoreScroll(in: scrollView) }
        }
    }

    func restoreScroll(in scrollView: NSScrollView) {
        scrollView.contentView.scroll(to: scrollOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func editorDidGainFocus(_ textView: NSTextView) {
        guard self.textView === textView else { return }
        shouldRestoreFocus = true
    }

    func restoreFocusIfNeeded(_ textView: NSTextView) {
        guard self.textView === textView, shouldRestoreFocus else { return }
        textView.window?.makeFirstResponder(textView)
    }

    func selectionDidChange(_ range: NSRange) {
        selectedRange = range
    }

    func navigate(to sourceLocation: Int) {
        let location = max(0, sourceLocation)
        guard let textView else {
            selectedRange = NSRange(location: location, length: 0)
            pendingNavigationLocation = location
            return
        }
        pendingNavigationLocation = nil
        let range = NSRange(location: min(location, (textView.string as NSString).length), length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.window?.makeFirstResponder(textView)
        selectedRange = range
    }

    func selectAndReveal(_ sourceRange: NSRange) {
        let location = max(0, sourceRange.location)
        guard let textView else {
            selectedRange = NSRange(location: location, length: max(0, sourceRange.length))
            pendingNavigationLocation = location
            return
        }
        let length = (textView.string as NSString).length
        let safeLocation = min(location, length)
        let range = NSRange(location: safeLocation,
                            length: min(max(0, sourceRange.length), length - safeLocation))
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.window?.makeFirstResponder(textView)
        selectedRange = range
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
        hasActiveEditor && textView?.isEditable == true && textView?.hasMarkedText() == false
    }

    func apply(_ style: MarkdownFormattingStyle) {
        guard let textView, let storage = textView.textStorage,
              textView.isEditable, !textView.hasMarkedText() else { return }
        let edit = MarkdownFormatter.apply(style, to: textView.string, selection: textView.selectedRange())
        perform(edit, in: textView, storage: storage, focusEditor: true)
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
              textView.isEditable, !textView.hasMarkedText(),
              let edit = MarkdownLineContinuation.edit(in: textView.string,
                                                       selection: textView.selectedRange()) else { return false }
        perform(edit, in: textView, storage: storage, focusEditor: true)
        return true
    }

    @discardableResult
    func changeIndentation(_ direction: MarkdownIndentation.Direction) -> Bool {
        guard let textView, let storage = textView.textStorage,
              textView.isEditable, !textView.hasMarkedText(),
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
              textView.isEditable, !textView.hasMarkedText(),
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
              textView.isEditable, !textView.hasMarkedText(),
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
              textView.isEditable, !textView.hasMarkedText(),
              let action = MarkdownTableEditing.tabAction(in: textView.string,
                  selection: textView.selectedRange(), backwards: backwards,
                  addsRowAtEnd: tableAddsRowOnTab) else { return false }
        switch action {
        case let .select(range):
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            selectedRange = range
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
                alert.messageText = "TSV・CSVを表に変換できません"
                alert.informativeText = "区切り文字、引用符、行の内容を確認してください。"
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
        alert.messageText = "セル内改行を変換します"
        alert.informativeText = "Markdown表ではセル内改行を直接表せないため、<br>に置き換えます。"
        alert.addButton(withTitle: "変換")
        alert.addButton(withTitle: "キャンセル")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { applyConversion() }
        }
    }

    func commitImage(alt: String, destination: String, title: String) -> Bool {
        guard let draft = imageDraft, let textView, let storage = textView.textStorage,
              textView.isEditable, !textView.hasMarkedText(),
              let edit = MarkdownLinkSyntax.imageEdit(in: textView.string, draft: draft,
                                                      alt: alt, destination: destination, title: title),
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
