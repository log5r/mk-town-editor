import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

@MainActor
private final class PaletteVisibilityProbe {
    var commands: [EditorCommand] = []
}

@MainActor
final class EditorCommandTests: XCTestCase {
    func testOccurrenceAvailabilityCacheTracksAllSelections() {
        let view = NSTextView()
        view.string = "word word word"
        let model = MarkdownEditorModel()
        model.connect(view)
        let ranges = [0, 5, 10].map { NSValue(range: NSRange(location: $0, length: 4)) }
        view.setSelectedRange(ranges[0].rangeValue)
        XCTAssertTrue(model.canAddNextOccurrence)
        view.setSelectedRanges(ranges, affinity: .upstream, stillSelecting: false)
        XCTAssertFalse(model.canAddNextOccurrence,
                       "Adding other selections must invalidate the cache even if the first is unchanged")
        view.setSelectedRanges(Array(ranges.prefix(2)), affinity: .upstream, stillSelecting: false)
        XCTAssertTrue(model.canAddNextOccurrence)
    }

    func testOpenPaletteAddsStructuralCommandsWhenPendingAnalysisCompletes() async throws {
        let view = NSTextView()
        view.string = "- item"
        let model = MarkdownEditorModel()
        model.connect(view)
        model.usesSharedAnalysis = true
        let visible = PaletteVisibilityProbe()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let host = NSHostingView(rootView: CommandPaletteView(model: model)
            .environmentObject(EditorSettingsStore(defaults: defaults))
            .onPreferenceChange(CommandPaletteMatchesKey.self) { commands in
                Task { @MainActor in visible.commands = commands }
            })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for _ in 0..<100 where visible.commands.isEmpty {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(visible.commands.contains(.indentList))
        XCTAssertTrue(visible.commands.contains(.bold), "The palette must be loaded before publishing analysis")
        model.sharedSnapshot = DocumentSnapshot(source: view.string)
        for _ in 0..<100 where !visible.commands.contains(.indentList) {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(visible.commands.contains(.indentList),
                      "Opening the palette during analysis must not permanently hide commands")
    }

    func testCustomizableToolbarUsesUniqueStableCommandsAndSharedActions() {
        let identifiers = EditorCommand.toolbar.map(\.toolbarIdentifier)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        XCTAssertEqual(EditorCommand.defaultToolbar, [.bold, .italic, .link])
        XCTAssertTrue(EditorCommand.defaultToolbar.isSubset(of: Set(EditorCommand.toolbar)))
        XCTAssertTrue(EditorCommand.toolbar.contains(.image))
        XCTAssertTrue(EditorCommand.toolbar.contains(.table))
        let view = NSTextView()
        view.string = "word"
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 0, length: 4))
        EditorCommand.toolbar.first(where: { $0 == .strikethrough })?.perform(on: model)
        XCTAssertEqual(view.string, "~~word~~")
    }

    func testCommandPaletteSearchesNamesAndShortcutsAndFiltersUnavailableCommands() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.string = "本文"
        let model = MarkdownEditorModel()
        model.connect(view)
        XCTAssertEqual(EditorCommand.bold.shortcutLabel, "⌘B")
        XCTAssertEqual(EditorCommand.paletteMatches("⌘B", in: model), [.bold])
        XCTAssertEqual(EditorCommand.paletteMatches("見出し 3", in: model), [.heading(level: 3)])
        XCTAssertFalse(EditorCommand.paletteMatches("", in: model).contains(.indentList))
        XCTAssertFalse(EditorCommand.paletteMatches("", in: model).contains(.snippet))
        model.snippets = [EditorSnippet(trigger: "sig", template: "文字")]
        XCTAssertTrue(EditorCommand.paletteMatches("スニペット", in: model).contains(.snippet))
    }

    func testCommandActsOnlyOnThePassedDocumentModel() {
        let firstView = NSTextView()
        firstView.string = "first"
        let secondView = NSTextView()
        secondView.string = "second"
        let first = MarkdownEditorModel()
        let second = MarkdownEditorModel()
        first.connect(firstView)
        second.connect(secondView)
        firstView.setSelectedRange(NSRange(location: 0, length: 5))

        EditorCommand.bold.perform(on: first)

        XCTAssertEqual(firstView.string, "**first**")
        XCTAssertEqual(secondView.string, "second")
    }

    func testCommandIsUnavailableWithoutAnEditableActiveView() {
        let model = MarkdownEditorModel()
        XCTAssertFalse(EditorCommand.bold.canExecute(in: model))
        let view = NSTextView()
        model.connect(view)
        XCTAssertTrue(EditorCommand.bold.canExecute(in: model))
        view.isEditable = false
        XCTAssertFalse(EditorCommand.bold.canExecute(in: model))
        model.disconnect(view)
        XCTAssertFalse(EditorCommand.bold.canExecute(in: model))
    }

    func testUnicodeInspectionIsAvailableForASelectionInAReadOnlyDocument() {
        let view = NSTextView()
        view.string = "👩‍💻"
        let model = MarkdownEditorModel()
        model.connect(view)
        XCTAssertFalse(EditorCommand.inspectUnicode.canExecute(in: model))
        view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
        view.isEditable = false
        XCTAssertTrue(EditorCommand.inspectUnicode.canExecute(in: model))
        XCTAssertFalse(EditorCommand.insertUnicode.canExecute(in: model))
        XCTAssertTrue(EditorCommand.paletteMatches("", in: model).contains(.inspectUnicode))
        model.disconnect(view)
        XCTAssertFalse(EditorCommand.inspectUnicode.canExecute(in: model))
    }

    func testUnicodeInsertionReplacesSelectionAndSupportsUndo() throws {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.string = "前Å後"
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 1, length: 1))

        EditorCommand.insertUnicode.perform(on: model)
        let draft = try XCTUnwrap(model.unicodeInsertionDraft)
        XCTAssertTrue(model.commitUnicodeInsertion("Å", draft: draft))
        XCTAssertEqual(view.string.unicodeScalars.map(\.value), "前Å後".unicodeScalars.map(\.value))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 0))
        view.undoManager?.undo()
        XCTAssertEqual(view.string.unicodeScalars.map(\.value), "前Å後".unicodeScalars.map(\.value))
    }

    func testUnicodeInsertionRejectsChangedTextSelectionAndEditability() throws {
        let view = NSTextView()
        view.string = "AÅ"
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 1, length: 1))
        EditorCommand.insertUnicode.perform(on: model)
        let draft = try XCTUnwrap(model.unicodeInsertionDraft)

        view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertFalse(model.commitUnicodeInsertion("😀", draft: draft))
        view.setSelectedRange(draft.selection)
        view.isEditable = false
        XCTAssertFalse(model.commitUnicodeInsertion("😀", draft: draft))
        view.isEditable = true
        view.string = "AÅ"
        view.setSelectedRange(draft.selection)
        XCTAssertFalse(model.commitUnicodeInsertion("😀", draft: draft))
        XCTAssertEqual(view.string.unicodeScalars.map(\.value), "AÅ".unicodeScalars.map(\.value))
    }

    func testUnicodeInsertionPreservesExplicitCarriageReturnOnDisk() throws {
        var document = MarkdownDocument(text: "一二\n三")
        let binding = Binding(get: { document }, set: { document = $0 })
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.string = document.text
        let model = MarkdownEditorModel()
        let coordinator = MarkdownTextEditor.Coordinator(text: binding.text, model: model, document: binding)
        coordinator.textView = view
        view.delegate = coordinator
        model.connect(view)
        view.setSelectedRange(NSRange(location: 1, length: 0))

        EditorCommand.insertUnicode.perform(on: model)
        let draft = try XCTUnwrap(model.unicodeInsertionDraft)
        XCTAssertTrue(model.commitUnicodeInsertion("\r", draft: draft))
        XCTAssertEqual(view.string, "一\n二\n三")
        XCTAssertEqual(try document.encodedData(), Data("一\r二\n三".utf8))
        withExtendedLifetime(coordinator) {}
    }

    func testSelectionNormalizationPreservesSelectionAndSavedNewlinesAndSupportsUndo() throws {
        let original = "前\r\nが👩‍💻\nパ\r\n後"
        let decoded = MarkdownTextFormat.read(text: original, hasUTF8BOM: false)
        var document = MarkdownDocument(text: decoded.text)
        document.format = decoded.format
        let binding = Binding(get: { document }, set: { document = $0 })
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        view.allowsUndo = true
        view.string = document.text
        let model = MarkdownEditorModel()
        let coordinator = MarkdownTextEditor.Coordinator(text: binding.text, model: model, document: binding)
        coordinator.textView = view
        view.delegate = coordinator
        model.connect(view)

        let command = EditorCommand.transformSelection(.nfd)
        XCTAssertFalse(command.canExecute(in: model))
        let selection = (view.string as NSString).range(of: "が👩‍💻\nパ")
        view.setSelectedRange(selection)
        XCTAssertTrue(EditorCommand.paletteMatches("", in: model).contains(command))
        XCTAssertTrue(EditorShortcutRegistry.commands.contains(command))
        XCTAssertEqual(Set(EditorCommand.textTransformations.map(\.toolbarIdentifier)).count, 11)

        command.perform(on: model)
        let decomposed = "か\u{3099}👩‍💻\nハ\u{309A}"
        XCTAssertEqual(view.selectedRange(), NSRange(location: selection.location, length: decomposed.utf16.count))
        XCTAssertEqual(try document.encodedData(), Data("前\r\nか\u{3099}👩‍💻\nハ\u{309A}\r\n後".utf8))

        view.undoManager?.undo()
        XCTAssertEqual(try document.encodedData(), Data(original.utf8))
        view.isEditable = false
        view.setSelectedRange(selection)
        XCTAssertFalse(command.canExecute(in: model))
        withExtendedLifetime(coordinator) {}
    }

    func testWidthCommandUsesEditorPreferences() {
        let view = NSTextView()
        view.string = "x Ａ！ガ `Ｂ` y"
        let model = MarkdownEditorModel()
        model.connect(view)
        model.textTransformationOptions.convertsSymbols = false
        model.textTransformationOptions.convertsKana = false
        model.textTransformationOptions.preservesCodeAndURLs = false
        view.setSelectedRange((view.string as NSString).range(of: "Ａ！ガ `Ｂ`"))

        EditorCommand.transformSelection(.fullwidthToHalfwidth).perform(on: model)

        XCTAssertEqual(view.string, "x A！ガ `B` y")
        XCTAssertEqual(view.selectedRange(), (view.string as NSString).range(of: "A！ガ `B`"))
    }

    func testWhitespaceCommandsUseTheActiveSelectionAndRespectReadOnlyMode() {
        let view = NSTextView()
        view.string = "一行目 \n二行目 \n    字下げ\n"
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 0, length: "一行目 \n".utf16.count))

        EditorCommand.trimTrailingWhitespace.perform(on: model)
        XCTAssertEqual(view.string, "一行目\n二行目 \n    字下げ\n")
        view.setSelectedRange((view.string as NSString).range(of: "    字下げ"))
        EditorCommand.convertIndentationToTabs.perform(on: model)
        XCTAssertEqual(view.string, "一行目\n二行目 \n\t字下げ\n")
        EditorCommand.convertIndentationToSpaces.perform(on: model)
        XCTAssertEqual(view.string, "一行目\n二行目 \n    字下げ\n")

        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.isEditable = false
        XCTAssertFalse(EditorCommand.trimTrailingWhitespace.canExecute(in: model))
        EditorCommand.trimTrailingWhitespace.perform(on: model)
        XCTAssertEqual(view.string, "一行目\n二行目 \n    字下げ\n")

        view.isEditable = true
        EditorCommand.trimTrailingWhitespace.perform(on: model)
        XCTAssertEqual(view.string, "一行目\n二行目\n    字下げ\n")
    }

    func testContextMenuUsesSharedCommandDefinitions() {
        let view = EditorTextView()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        view.imagePasteboard = pasteboard
        view.string = "abc"
        let model = MarkdownEditorModel()
        model.connect(view)
        view.commandModel = model
        view.setSelectedRange(NSRange(location: 0, length: 3))

        let menu = view.makeMarkdownMenu(baseMenu: nil)
        let actualCommands = menu.items.compactMap { $0.representedObject as? EditorCommand }
        let markdownMenu = try! XCTUnwrap(menu.items.last?.submenu)
        let headingMenu = markdownMenu.items.first(where: { $0.title == "見出しレベル" })?.submenu

        XCTAssertEqual(actualCommands, EditorCommand.context)
        XCTAssertLessThanOrEqual(menu.items.filter { !$0.isSeparatorItem }.count, 10)
        XCTAssertEqual(markdownMenu.items.compactMap { $0.representedObject as? EditorCommand },
                       EditorCommand.contextMarkdown)
        XCTAssertEqual(Set(EditorCommand.context).intersection(EditorCommand.contextMarkdown), [])
        XCTAssertEqual(headingMenu?.items.compactMap { $0.representedObject as? EditorCommand },
                       (0...6).map { .heading(level: $0) })
        XCTAssertTrue(menu.items.first?.isEnabled == true)
        menu.performActionForItem(at: 0)
        XCTAssertEqual(view.string, "**abc**")
        model.disconnect(view)
        XCTAssertFalse(view.makeMarkdownMenu(baseMenu: nil).items.first?.isEnabled == true)
    }

    func testContextMenuAvailabilitySurvivesValidationBeforeDisplay() {
        let view = EditorTextView()
        view.string = "plain"
        let model = MarkdownEditorModel()
        model.connect(view)
        view.commandModel = model
        view.setSelectedRange(NSRange(location: 0, length: 0))
        let menu = view.makeMarkdownMenu(baseMenu: nil)

        func commandItems(in menu: NSMenu) -> [NSMenuItem] {
            menu.update()
            return menu.items.flatMap { item in
                item.submenu.map(commandItems(in:)) ?? (item.representedObject is EditorCommand ? [item] : [])
            }
        }
        let items = commandItems(in: menu)
        XCTAssertGreaterThan(items.count, 20)
        for item in items {
            let command = item.representedObject as! EditorCommand
            XCTAssertEqual(item.isEnabled, command.canExecute(in: model), command.title)
        }
        XCTAssertTrue(items.contains { !$0.isEnabled }, "Some commands need a list or selection")
        model.disconnect(view)
        XCTAssertTrue(commandItems(in: menu).allSatisfy { !$0.isEnabled })
    }

    func testStrikethroughCommandUsesSharedActionAndShortcut() {
        let view = NSTextView()
        view.string = "word"
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 0, length: 4))

        EditorCommand.strikethrough.perform(on: model)

        XCTAssertEqual(view.string, "~~word~~")
        XCTAssertEqual(EditorCommand.strikethrough.title, "取り消し線")
        XCTAssertEqual(EditorCommand.strikethrough.shortcut?.key, "x")
        XCTAssertTrue(EditorCommand.strikethrough.shortcut?.modifiers.contains(.shift) == true)
    }

    func testOrderedListCommandConvertsSelectedBullets() {
        let view = NSTextView()
        view.string = "- one\n- two"
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))

        EditorCommand.orderedList.perform(on: model)

        XCTAssertEqual(view.string, "1. one\n2. two")
        XCTAssertEqual(EditorCommand.orderedList.title, "番号付きリスト")
    }

    func testTaskAndBulletCommandsConvertSelectedLines() {
        let view = NSTextView()
        view.string = "- one\n- two"
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))

        EditorCommand.taskList.perform(on: model)
        XCTAssertEqual(view.string, "- [ ] one\n- [ ] two")

        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        EditorCommand.unorderedList.perform(on: model)
        XCTAssertEqual(view.string, "- one\n- two")
    }

    func testTaskCompletionCommandChangesCaretLine() {
        let view = NSTextView()
        view.string = "- [ ] first\n- [ ] second"
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 7, length: 0))

        EditorCommand.toggleTaskCompletion.perform(on: model)

        XCTAssertEqual(view.string, "- [x] first\n- [ ] second")
    }

    func testCodeBlockContextMenuOffersLanguagesAndRunsSharedCommand() {
        let view = EditorTextView()
        view.string = "let x = 1"
        let model = MarkdownEditorModel()
        model.connect(view)
        view.commandModel = model
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))

        let menu = try! XCTUnwrap(view.makeMarkdownMenu(baseMenu: nil).items.last?.submenu)
        let codeMenu = try! XCTUnwrap(menu.items.first(where: { $0.title == "コードブロック" })?.submenu)
        let expected: [EditorCommand] = [.codeBlock(language: nil)] +
            MarkdownCodeLanguage.allCases.map { .codeBlock(language: $0) }
        XCTAssertEqual(codeMenu.items.compactMap { $0.representedObject as? EditorCommand }, expected)
        let swiftIndex = try! XCTUnwrap(codeMenu.items.firstIndex(where: {
            $0.representedObject as? EditorCommand == .codeBlock(language: .swift)
        }))
        codeMenu.performActionForItem(at: swiftIndex)
        XCTAssertEqual(view.string, "```swift\nlet x = 1\n```")
    }

    func testHorizontalRuleCommandWorksFromSharedContextMenu() {
        let view = EditorTextView()
        view.string = "beforeafter"
        let model = MarkdownEditorModel()
        model.connect(view)
        view.commandModel = model
        view.setSelectedRange(NSRange(location: 6, length: 0))

        let menu = try! XCTUnwrap(view.makeMarkdownMenu(baseMenu: nil).items.last?.submenu)
        let index = try! XCTUnwrap(menu.items.firstIndex(where: {
            $0.representedObject as? EditorCommand == .horizontalRule
        }))
        menu.performActionForItem(at: index)

        XCTAssertEqual(view.string, "before\n\n***\n\nafter")
        XCTAssertEqual(EditorCommand.horizontalRule.title, "区切り線")
        XCTAssertNil(EditorCommand.horizontalRule.shortcut)
    }

    func testLinkCommandOpensDraftWithoutMutatingDocument() {
        let view = NSTextView()
        view.string = "selected"
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 0, length: 8))

        EditorCommand.link.perform(on: model)

        XCTAssertEqual(view.string, "selected")
        XCTAssertEqual(model.linkDraft?.label, "selected")
        XCTAssertFalse(model.linkDraft?.isExisting ?? true)
    }

    func testImageCommandOpensDraftWithSelectedAltText() {
        let view = NSTextView()
        view.string = "図🙂"
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))

        EditorCommand.image.perform(on: model)

        XCTAssertEqual(view.string, "図🙂")
        XCTAssertEqual(model.imageDraft?.alt, "図🙂")
    }
}
