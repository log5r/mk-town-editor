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
        guard let textView else { return }
        let edit = MarkdownFormatter.apply(style, to: textView.string, selection: textView.selectedRange())
        guard textView.shouldChangeText(in: NSRange(location: 0, length: (textView.string as NSString).length), replacementString: edit.text) else {
            return
        }
        textView.string = edit.text
        textView.didChangeText()
        textView.setSelectedRange(edit.selection)
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
