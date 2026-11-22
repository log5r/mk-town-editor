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
    var font: MobileEditorFont = .default

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> EditorTextView {
        let view = EditorTextView()
        view.backgroundColor = .systemBackground
        view.textColor = .label
        view.font = Self.font(for: context.environment.dynamicTypeSize, choice: font)
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
        // Dynamic Type changes and a different font chosen in Settings.
        let font = Self.font(for: context.environment.dynamicTypeSize, choice: self.font)
        if font != coordinator.appliedFont {
            coordinator.appliedFont = font
            view.font = font
        }

        // Typed text already reached the binding from UIKit, so the common case is identical
        // storage. Never replace the text during IME composition (docs/ime-composition-reset.md):
        // `syncedText` stays behind, and the coordinator reconciles the change when it ends.
        if text != coordinator.syncedText, view.markedTextRange == nil {
            coordinator.apply(outsideText: text, to: view)
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

    /// The chosen font at the body size of the environment's Dynamic Type size. The default
    /// matches SwiftUI's `.body.monospaced()`.
    static func font(for size: DynamicTypeSize, choice: MobileEditorFont = .default) -> UIFont {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        return choice.uiFont(ofSize: body.pointSize)
    }

    static func clamped(_ range: NSRange, to text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(max(range.location, 0), length)
        return NSRange(location: location, length: min(max(range.length, 0), length - location))
    }

    /// Combines text typed in the editor with a change made elsewhere since `base`, when the two
    /// changed different places. `offsetAfterTypedText` is how far text after the typed change
    /// moved, in UTF-16 units. Returns nil when both changed the same place.
    static func merging(typed: String, outside: String, base: String) -> (text: String, offsetAfterTypedText: Int)? {
        let base = base as NSString, typed = typed as NSString, outside = outside as NSString
        /// The range of `base` that `other` replaced, found from the shared start and end.
        func changedRange(_ other: NSString) -> NSRange {
            let limit = min(base.length, other.length)
            var prefix = 0
            while prefix < limit, base.character(at: prefix) == other.character(at: prefix) { prefix += 1 }
            var suffix = 0
            while suffix < limit - prefix,
                  base.character(at: base.length - 1 - suffix) == other.character(at: other.length - 1 - suffix) {
                suffix += 1
            }
            return NSRange(location: prefix, length: base.length - prefix - suffix)
        }
        let typedRange = changedRange(typed), outsideRange = changedRange(outside)
        let replacement = typed.substring(with: NSRange(location: typedRange.location,
            length: typed.length - (base.length - typedRange.length)))
        if NSMaxRange(typedRange) <= outsideRange.location {
            // Typed before the outside change: the same range of the new text is still untouched.
            return (outside.replacingCharacters(in: typedRange, with: replacement), 0)
        }
        if typedRange.location >= NSMaxRange(outsideRange) {
            let shift = outside.length - base.length
            let moved = NSRange(location: typedRange.location + shift, length: typedRange.length)
            return (outside.replacingCharacters(in: moved, with: replacement), shift)
        }
        return nil
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

        /// Replaces the editor's text with a change made elsewhere.
        func apply(outsideText: String, to view: UITextView) {
            syncedText = outsideText
            guard view.text != outsideText else { return }
            let selected = view.selectedRange
            view.text = outsideText
            view.selectedRange = MobileMarkdownTextView.clamped(selected, to: outsideText)
        }

        private func publishText(of view: UITextView) {
            hasUnpublishedComposition = false
            var text = view.text ?? ""
            // The document can change elsewhere while composition keeps `updateUIView` from
            // applying it. Publishing the editor's text as it is would discard that change.
            let outside = parent.text
            if outside != syncedText {
                guard text != syncedText else {
                    // Nothing was typed after all, so the outside change simply applies.
                    apply(outsideText: outside, to: view)
                    return
                }
                if let merged = MobileMarkdownTextView.merging(typed: text, outside: outside, base: syncedText) {
                    let selected = view.selectedRange
                    view.text = merged.text
                    view.selectedRange = MobileMarkdownTextView.clamped(NSRange(
                        location: selected.location + merged.offsetAfterTypedText, length: selected.length),
                        to: merged.text)
                    text = merged.text
                }
                // Otherwise both changed the same place. Keep what the person sees and just typed.
            }
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

extension MobileEditorFont {
    /// The font at `size`. A bundled font that cannot be loaded falls back to the system
    /// monospaced font, the editor's default.
    func uiFont(ofSize size: CGFloat) -> UIFont {
        let base: UIFont
        switch face {
        case .system(.monospaced):
            base = .monospacedSystemFont(ofSize: size, weight: .regular)
        case .system(let design):
            let system = UIFont.systemFont(ofSize: size)
            let descriptor = system.fontDescriptor.withDesign(design.uiDesign) ?? system.fontDescriptor
            base = UIFont(descriptor: descriptor, size: size)
        case .named(let name):
            guard let font = UIFont(name: name, size: size) else {
                return .monospacedSystemFont(ofSize: size, weight: .regular)
            }
            base = font
        }
        guard let japaneseFallback,
              UIFont(name: japaneseFallback, size: size) != nil else { return base }
        let cascade = UIFontDescriptor(name: japaneseFallback, size: size)
        return UIFont(descriptor: base.fontDescriptor.addingAttributes([.cascadeList: [cascade]]), size: size)
    }
}

extension MobileEditorFont.SystemDesign {
    var uiDesign: UIFontDescriptor.SystemDesign {
        switch self {
        case .standard: .default
        case .monospaced: .monospaced
        case .serif: .serif
        case .rounded: .rounded
        }
    }
}
