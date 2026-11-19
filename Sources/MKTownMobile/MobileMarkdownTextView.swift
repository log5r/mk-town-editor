import SwiftUI
import UIKit

/// Keeps the caret and selected range while the editor is removed for the preview.
/// A plain reference avoids re-rendering the workspace for every caret movement.
@MainActor
final class MobileTextSelection {
    var range = NSRange(location: 0, length: 0)
}

/// The iOS Markdown editor.
///
/// SwiftUI's `TextEditor` lays out the whole text again for every binding update. TextKit 2
/// then estimates the heights of paragraphs it has not laid out yet, so a long wrapped document
/// shrank and jumped while typing near its end (issue #84). This view publishes typed text from
/// UIKit to the binding and replaces the UIKit text only for changes made elsewhere.
/// See docs/mobile-editor-scroll-jump.md.
struct MobileMarkdownTextView: UIViewRepresentable {
    @Binding var text: String
    let selection: MobileTextSelection
    @Binding var isFocused: Bool
    @Binding var isFindNavigatorPresented: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> EditorTextView {
        let view = EditorTextView()
        view.backgroundColor = .systemBackground
        view.textColor = .label
        view.font = Self.font(for: context.environment.dynamicTypeSize)
        context.coordinator.appliedFont = view.font
        view.isFindInteractionEnabled = true
        view.accessibilityLabel = String(localized: "Markdown本文")
        view.accessibilityIdentifier = "markdownEditor"
        view.text = text
        view.selectedRange = Self.clamped(selection.range, to: view.text)
        context.coordinator.syncedText = text
        view.delegate = context.coordinator
        view.findSessionDidChange = { [weak coordinator = context.coordinator] active in
            coordinator?.findSessionDidChange(active)
        }
        return view
    }

    func updateUIView(_ view: EditorTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        // Setting the font re-attributes and lays out the whole document, so only apply
        // Dynamic Type changes.
        let font = Self.font(for: context.environment.dynamicTypeSize)
        if font != coordinator.appliedFont {
            coordinator.appliedFont = font
            view.font = font
        }

        // Typed text already reached the binding from UIKit, so the common case is identical
        // storage. Never replace the text during IME composition (docs/ime-composition-reset.md).
        if text != coordinator.syncedText, view.markedTextRange == nil {
            coordinator.syncedText = text
            if view.text != text {
                let selected = view.selectedRange
                view.text = text
                view.selectedRange = Self.clamped(selected, to: text)
            }
        }

        if isFocused != coordinator.focusBinding {
            coordinator.focusBinding = isFocused
            if isFocused, !view.isFirstResponder, view.window != nil {
                view.becomeFirstResponder()
            } else if !isFocused, view.isFirstResponder {
                view.resignFirstResponder()
            }
        }

        if let interaction = view.findInteraction {
            if isFindNavigatorPresented, !interaction.isFindNavigatorVisible, view.window != nil {
                interaction.presentFindNavigator(showingReplace: false)
            } else if !isFindNavigatorPresented, interaction.isFindNavigatorVisible {
                interaction.dismissFindNavigator()
            }
        }
    }

    static func dismantleUIView(_ view: EditorTextView, coordinator: Coordinator) {
        // The workspace resets focus and find state when it removes the editor.
        view.findSessionDidChange = nil
        view.delegate = nil
        if view.findInteraction?.isFindNavigatorVisible == true {
            view.findInteraction?.dismissFindNavigator()
        }
    }

    /// Matches SwiftUI's `.body.monospaced()` and follows the environment's Dynamic Type size.
    static func font(for size: DynamicTypeSize) -> UIFont {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        return .monospacedSystemFont(ofSize: body.pointSize, weight: .regular)
    }

    static func clamped(_ range: NSRange, to text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(max(range.location, 0), length)
        return NSRange(location: location, length: min(max(range.length, 0), length - location))
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MobileMarkdownTextView
        /// The text known to match the binding. Typed text is stored here before it is published.
        var syncedText = ""
        /// The focus value last applied from, or published to, the binding.
        var focusBinding = false
        var appliedFont: UIFont?
        private var hasUnpublishedComposition = false

        init(_ parent: MobileMarkdownTextView) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            // Composition text is not part of the document until the input method commits it.
            guard view.markedTextRange == nil else {
                hasUnpublishedComposition = true
                return
            }
            publishText(of: view)
        }

        func textViewDidChangeSelection(_ view: UITextView) {
            parent.selection.range = view.selectedRange
            if hasUnpublishedComposition, view.markedTextRange == nil { publishText(of: view) }
        }

        func textViewDidBeginEditing(_ view: UITextView) { publishFocus(true) }
        func textViewDidEndEditing(_ view: UITextView) { publishFocus(false) }

        func findSessionDidChange(_ active: Bool) {
            if parent.isFindNavigatorPresented != active { parent.isFindNavigatorPresented = active }
        }

        private func publishText(of view: UITextView) {
            hasUnpublishedComposition = false
            let text = view.text ?? ""
            guard text != syncedText else { return }
            syncedText = text
            parent.text = text
        }

        private func publishFocus(_ focused: Bool) {
            focusBinding = focused
            if parent.isFocused != focused { parent.isFocused = focused }
        }
    }

    /// Reports when the built-in find navigator opens or closes, including when the person
    /// closes it from the system find bar.
    final class EditorTextView: UITextView {
        var findSessionDidChange: ((Bool) -> Void)?

        // UITextView is the delegate of its built-in UIFindInteraction. The SDK declares these
        // as optional protocol methods, so call UIKit's implementation only when it exists.
        override func findInteraction(_ interaction: UIFindInteraction, didBegin session: UIFindSession) {
            if UITextView.instancesRespond(to: #selector(UIFindInteractionDelegate.findInteraction(_:didBegin:))) {
                super.findInteraction(interaction, didBegin: session)
            }
            findSessionDidChange?(true)
        }

        override func findInteraction(_ interaction: UIFindInteraction, didEnd session: UIFindSession) {
            if UITextView.instancesRespond(to: #selector(UIFindInteractionDelegate.findInteraction(_:didEnd:))) {
                super.findInteraction(interaction, didEnd: session)
            }
            findSessionDidChange?(false)
        }
    }
}
