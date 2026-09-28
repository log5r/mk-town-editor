import AppKit
import Combine

@MainActor
final class MarkdownEditorModel: ObservableObject {
    @Published private(set) var selectedRange = NSRange(location: 0, length: 0)
    weak var textView: NSTextView?

    func connect(_ textView: NSTextView) {
        self.textView = textView
        selectedRange = textView.selectedRange()
    }

    func selectionDidChange(_ range: NSRange) {
        selectedRange = range
    }

    func apply(_ style: MarkdownFormattingStyle) {
        guard let textView, let storage = textView.textStorage,
              textView.isEditable, !textView.hasMarkedText() else { return }
        let edit = MarkdownFormatter.apply(style, to: textView.string, selection: textView.selectedRange())
        guard textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else {
            return
        }
        textView.breakUndoCoalescing()
        storage.replaceCharacters(in: edit.range, with: edit.replacement)
        textView.didChangeText()
        textView.setSelectedRange(edit.selection)
        textView.breakUndoCoalescing()
        textView.window?.makeFirstResponder(textView)
    }

    func showFindBar() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        textView.performFindPanelAction(item)
    }
}
