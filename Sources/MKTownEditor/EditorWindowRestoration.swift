import AppKit
import SwiftUI

/// Decides whether a document window is saved for state restoration.
///
/// An untitled document with no text has nothing to bring back. Restoring it anyway made the
/// window count grow on every launch: the restored empty windows came back and SwiftUI's
/// `DocumentGroup` opened one more untitled document beside them, which the next launch restored
/// again. Saved documents and untitled documents with text are still restored, so unsaved work
/// that was autosaved keeps coming back. See docs/untitled-window-accumulation.md.
enum EditorWindowRestoration {
    static func isRestorable(fileURL: URL?, isTextEmpty: Bool) -> Bool {
        fileURL != nil || !isTextEmpty
    }
}

/// Applies `isRestorable` to the window that hosts this view, when the view joins a window and
/// whenever the value changes.
struct WindowRestorationSetter: NSViewRepresentable {
    let isRestorable: Bool

    func makeNSView(context: Context) -> RestorationView {
        let view = RestorationView()
        view.isRestorableWindow = isRestorable
        return view
    }

    func updateNSView(_ view: RestorationView, context: Context) {
        view.isRestorableWindow = isRestorable
    }

    final class RestorationView: NSView {
        var isRestorableWindow = true {
            didSet { if isRestorableWindow != oldValue { apply() } }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func apply() {
            guard let window, window.isRestorable != isRestorableWindow else { return }
            window.isRestorable = isRestorableWindow
        }
    }
}
