import AppKit
import Combine

@MainActor
final class MarkdownEditorModel: ObservableObject {
    @Published private(set) var selectedRange = NSRange(location: 0, length: 0)
    @Published private(set) var hasActiveEditor = false
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

    func toggleTask(at sourceLocation: Int) {
        guard let textView, let storage = textView.textStorage,
              textView.isEditable, !textView.hasMarkedText(),
              let edit = MarkdownFormatter.toggleTasks(in: textView.string,
                                                       selection: NSRange(location: sourceLocation, length: 0)) else { return }
        perform(edit, in: textView, storage: storage, focusEditor: false)
    }

    private func perform(_ edit: MarkdownEdit, in textView: NSTextView,
                         storage: NSTextStorage, focusEditor: Bool) {
        guard (storage.string as NSString).substring(with: edit.range) != edit.replacement else { return }
        guard textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else {
            return
        }
        let originalSelection = textView.selectedRange()
        textView.breakUndoCoalescing()
        storage.replaceCharacters(in: edit.range, with: edit.replacement)
        textView.didChangeText()
        textView.setSelectedRange(focusEditor ? edit.selection : originalSelection)
        textView.breakUndoCoalescing()
        if focusEditor { textView.window?.makeFirstResponder(textView) }
    }

    func showFindBar() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        textView.performFindPanelAction(item)
    }
}
