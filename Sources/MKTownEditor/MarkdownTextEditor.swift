import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    let model: MarkdownEditorModel
    var textStyle: EditorTextStyle = EditorTextStyle()
    var layoutOptions: EditorLayoutOptions = EditorLayoutOptions()
    var imageImportMode: ImageImportMode = .managedCopy
    var onImageDrop: ((URL, Int) -> Void)?
    var onImagePaste: ((Data) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = EditorScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !layoutOptions.wrapsLines
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
        textStyle.apply(to: textView)
        context.coordinator.appliedTextStyle = textStyle
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isVerticallyResizable = true
        scrollView.documentView = textView
        layoutOptions.apply(to: textView, in: scrollView)
        scrollView.onLayout = { [weak textView, weak scrollView, weak coordinator = context.coordinator] in
            guard let textView, let scrollView, let coordinator,
                  let options = coordinator.appliedLayoutOptions else { return }
            options.synchronizeWidth(of: textView, in: scrollView)
        }
        context.coordinator.appliedLayoutOptions = layoutOptions
        model.listIndentWidth = layoutOptions.listIndentWidth
        model.codeIndentWidth = layoutOptions.codeIndentWidth
        let lineNumberRuler = MarkdownLineNumberRulerView(scrollView: scrollView, editor: textView)
        scrollView.verticalRulerView = lineNumberRuler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.lineNumberRuler = lineNumberRuler
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        context.coordinator.isRestoringSession = true
        model.connect(textView, scrollView: scrollView)
        textView.commandModel = model
        textView.imageImportMode = imageImportMode
        textView.onImageDrop = onImageDrop
        textView.onImagePaste = onImagePaste
        textView.registerForDraggedTypes([.fileURL])
        MarkdownSyntaxHighlighter.apply(to: textView)
        layoutOptions.synchronizeWidth(of: textView, in: scrollView)
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
        guard let textView = scrollView.documentView as? EditorTextView else { return }
        textView.imageImportMode = imageImportMode
        textView.onImageDrop = onImageDrop
        textView.onImagePaste = onImagePaste
        if context.coordinator.appliedLayoutOptions != layoutOptions {
            layoutOptions.apply(to: textView, in: scrollView)
            context.coordinator.appliedLayoutOptions = layoutOptions
            context.coordinator.lineNumberRuler?.refresh()
        }
        context.coordinator.model.listIndentWidth = layoutOptions.listIndentWidth
        context.coordinator.model.codeIndentWidth = layoutOptions.codeIndentWidth
        if context.coordinator.appliedTextStyle != textStyle {
            textStyle.apply(to: textView)
            context.coordinator.appliedTextStyle = textStyle
            context.coordinator.lineNumberRuler?.refresh()
        }
        layoutOptions.synchronizeWidth(of: textView, in: scrollView)
        guard textView.string != text else { return }
        let selection = textView.selectedRange()
        textView.string = text
        MarkdownSyntaxHighlighter.apply(to: textView)
        layoutOptions.synchronizeWidth(of: textView, in: scrollView)
        context.coordinator.lineNumberRuler?.refresh()
        let length = (text as NSString).length
        let location = min(selection.location, length)
        textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        let model: MarkdownEditorModel
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        weak var lineNumberRuler: MarkdownLineNumberRulerView?
        var appliedTextStyle: EditorTextStyle?
        var appliedLayoutOptions: EditorLayoutOptions?
        var isRestoringSession = false

        init(text: Binding<String>, model: MarkdownEditorModel) {
            _text = text
            self.model = model
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text = textView.string
            MarkdownSyntaxHighlighter.apply(to: textView)
            if let scrollView, let options = appliedLayoutOptions {
                options.synchronizeWidth(of: textView, in: scrollView)
            }
            lineNumberRuler?.refresh()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            model.selectionDidChange(textView.selectedRange())
        }

        @MainActor @objc func clipViewBoundsDidChange(_ notification: Notification) {
            lineNumberRuler?.needsDisplay = true
            guard let scrollView, !isRestoringSession else { return }
            model.scrollDidChange(scrollView.contentView.bounds.origin)
        }
    }
}

private final class EditorScrollView: NSScrollView {
    var onWindowAttached: (() -> Void)?
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onWindowAttached?() }
    }
}

final class EditorTextView: NSTextView {
    var onFocused: (() -> Void)?
    weak var commandModel: MarkdownEditorModel?
    var imageImportMode: ImageImportMode = .managedCopy
    var onImageDrop: ((URL, Int) -> Void)?
    var onImagePaste: ((Data) -> Void)?
    var imagePasteboard: NSPasteboard = .general
    private var selectionBeforeImageDrag: NSRange?
    private var imageDropLocation: Int? {
        didSet { needsDisplay = true }
    }

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome { onFocused?() }
        return didBecome
    }

    override func insertNewline(_ sender: Any?) {
        if commandModel?.continueListOrQuote() == true { return }
        super.insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        if commandModel?.changeIndentation(.indent) == true { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if commandModel?.changeIndentation(.outdent) == true { return }
        super.insertBacktab(sender)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if let typed = insertString as? String,
           commandModel?.completeSymbol(typed, replacementRange: replacementRange) == true { return }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func paste(_ sender: Any?) {
        guard isEditable, !hasMarkedText(), let onImagePaste,
              let data = Self.imageData(in: imagePasteboard) else {
            super.paste(sender)
            return
        }
        onImagePaste(data)
    }

    static func imageData(in pasteboard: NSPasteboard) -> Data? {
        pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard Self.imageURL(in: sender.draggingPasteboard) != nil, onImageDrop != nil,
              isEditable, !hasMarkedText() else { return super.draggingEntered(sender) }
        selectionBeforeImageDrag = selectedRange()
        imageDropLocation = dropInsertionLocation(for: sender.draggingLocation)
        return imageImportMode == .managedCopy ? .copy : .link
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard Self.imageURL(in: sender.draggingPasteboard) != nil, onImageDrop != nil,
              isEditable, !hasMarkedText() else { return super.draggingUpdated(sender) }
        setSelectedRange(NSRange(location: dropInsertionLocation(for: sender.draggingLocation), length: 0))
        imageDropLocation = selectedRange().location
        return imageImportMode == .managedCopy ? .copy : .link
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let selectionBeforeImageDrag {
            setSelectedRange(selectionBeforeImageDrag)
            self.selectionBeforeImageDrag = nil
            imageDropLocation = nil
            return
        }
        selectionBeforeImageDrag = nil
        imageDropLocation = nil
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = Self.imageURL(in: sender.draggingPasteboard), let onImageDrop,
              isEditable, !hasMarkedText() else { return super.performDragOperation(sender) }
        let location = dropInsertionLocation(for: sender.draggingLocation)
        setSelectedRange(NSRange(location: location, length: 0))
        selectionBeforeImageDrag = nil
        imageDropLocation = nil
        onImageDrop(url, location)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let imageDropLocation,
              let indicator = imageDropIndicatorRect(at: imageDropLocation),
              indicator.intersects(dirtyRect) else { return }
        NSColor.controlAccentColor.setFill()
        indicator.fill()
    }

    func imageDropIndicatorRect(at location: Int) -> NSRect? {
        guard let window, location >= 0,
              location <= (string as NSString).length else { return nil }
        let screen = firstRect(forCharacterRange: NSRange(location: location, length: 0),
                               actualRange: nil)
        let local = convert(window.convertFromScreen(screen), from: nil)
        return NSRect(x: local.minX, y: local.minY, width: 2,
                      height: max(local.height, font?.pointSize ?? 13))
    }

    func dropInsertionLocation(for windowPoint: NSPoint) -> Int {
        guard let layoutManager, let textContainer else { return (string as NSString).length }
        let local = convert(windowPoint, from: nil)
        let containerPoint = NSPoint(x: local.x - textContainerOrigin.x,
                                     y: local.y - textContainerOrigin.y)
        return min((string as NSString).length,
                   layoutManager.characterIndex(for: containerPoint, in: textContainer,
                                                fractionOfDistanceBetweenInsertionPoints: nil))
    }

    static func imageURL(in pasteboard: NSPasteboard) -> URL? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL]
        guard let urls, urls.count == 1,
              let url = urls.first, url.isFileURL,
              UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else { return nil }
        return url
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        makeMarkdownMenu(baseMenu: super.menu(for: event))
    }

    func makeMarkdownMenu(baseMenu: NSMenu?) -> NSMenu {
        let menu = (baseMenu?.copy() as? NSMenu) ?? NSMenu()
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        for command in EditorCommand.context {
            add(command, to: menu)
        }
        let codeItem = NSMenuItem(title: "コードブロック", action: nil, keyEquivalent: "")
        let codeMenu = NSMenu(title: "コードブロック")
        add(.codeBlock(language: nil), to: codeMenu)
        for language in MarkdownCodeLanguage.allCases {
            add(.codeBlock(language: language), to: codeMenu)
        }
        codeItem.submenu = codeMenu
        menu.addItem(codeItem)
        let headingItem = NSMenuItem(title: "見出しレベル", action: nil, keyEquivalent: "")
        let headingMenu = NSMenu(title: "見出しレベル")
        for level in 0...6 {
            add(.heading(level: level), to: headingMenu)
        }
        headingItem.submenu = headingMenu
        menu.addItem(headingItem)
        return menu
    }

    private func add(_ command: EditorCommand, to menu: NSMenu) {
        let item = NSMenuItem(title: command.title, action: #selector(performMarkdownCommand(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = command
        item.isEnabled = command.canExecute(in: commandModel)
        menu.addItem(item)
    }

    @objc private func performMarkdownCommand(_ item: NSMenuItem) {
        guard let command = item.representedObject as? EditorCommand else { return }
        command.perform(on: commandModel)
    }
}
