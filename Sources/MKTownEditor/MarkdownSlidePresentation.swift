import AppKit
import SwiftUI

@MainActor
final class MarkdownSlideWindowManager: NSObject, ObservableObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(deck: MarkdownSlideDeck, context: DocumentContext,
              exportPDF: @escaping () -> Void) {
        window?.close()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = String(localized: "スライド表示")
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: MarkdownSlidePresentationView(
            deck: deck, documentContext: context, exportPDF: exportPDF,
            close: { [weak window] in window?.close() }))
        self.window = window
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak window] in
            if window?.isVisible == true { window?.toggleFullScreen(nil) }
        }
    }

    func windowWillClose(_ notification: Notification) {
        if window === notification.object as? NSWindow { window = nil }
    }
}

private struct MarkdownSlidePresentationView: View {
    let deck: MarkdownSlideDeck
    let documentContext: DocumentContext
    let exportPDF: () -> Void
    let close: () -> Void
    @State private var index = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(index + 1) / \(deck.slides.count)")
                    .font(.caption.monospacedDigit())
                    .accessibilityLabel("スライド \(index + 1) / \(deck.slides.count)")
                Spacer()
                Button("スライドPDFを書き出す", systemImage: "square.and.arrow.up") {
                    exportPDF()
                }
                Button("閉じる", systemImage: "xmark") { close() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            MarkdownPreview(markdown: deck.slides[index], documentContext: documentContext)
                .id(index)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            Divider()
            HStack {
                Button("前へ", systemImage: "chevron.left") {
                    index = max(0, index - 1)
                }
                .disabled(index == 0)
                Spacer()
                Button("次へ", systemImage: "chevron.right") {
                    index = min(deck.slides.count - 1, index + 1)
                }
                .disabled(index + 1 == deck.slides.count)
            }
            .padding(16)
        }
        .frame(minWidth: 720, minHeight: 480)
        .onMoveCommand { direction in
            switch direction {
            case .left, .up: index = max(0, index - 1)
            case .right, .down: index = min(deck.slides.count - 1, index + 1)
            default: break
            }
        }
    }
}
