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

    func connect(_ textView: NSTextView, scrollView: NSScrollView? = nil) {
        self.textView = textView
        hasActiveEditor = true
        let length = (textView.string as NSString).length
        let location = min(selectedRange.location, length)
        textView.setSelectedRange(NSRange(
            location: location,
            length: min(selectedRange.length, length - location)
        ))
        if let scrollView { restoreScroll(in: scrollView) }
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
                                                  direction: direction) else { return false }
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
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        textView.performFindPanelAction(item)
    }
}
