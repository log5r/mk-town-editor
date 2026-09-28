import AppKit
import SwiftUI

struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    let model: MarkdownEditorModel

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = EditorScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        let textView = EditorTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 18, height: 18)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        context.coordinator.isRestoringSession = true
        model.connect(textView, scrollView: scrollView)
        context.coordinator.isRestoringSession = false
        textView.onFocused = { [weak textView, weak model] in
            guard let textView, let model else { return }
            model.editorDidGainFocus(textView)
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
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else {
            return
        }
        let selection = textView.selectedRange()
        textView.string = text
        let length = (text as NSString).length
        let location = min(selection.location, length)
        textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        let model: MarkdownEditorModel
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        var isRestoringSession = false

        init(text: Binding<String>, model: MarkdownEditorModel) {
            _text = text
            self.model = model
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text = textView.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            model.selectionDidChange(textView.selectedRange())
        }

        @MainActor @objc func clipViewBoundsDidChange(_ notification: Notification) {
            guard let scrollView, !isRestoringSession else { return }
            model.scrollDidChange(scrollView.contentView.bounds.origin)
        }
    }
}

private final class EditorScrollView: NSScrollView {
    var onWindowAttached: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onWindowAttached?() }
    }
}

private final class EditorTextView: NSTextView {
    var onFocused: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome { onFocused?() }
        return didBecome
    }
}
