import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class EditorCommandTests: XCTestCase {
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

    func testContextMenuUsesSharedCommandDefinitions() {
        let view = EditorTextView()
        view.string = "abc"
        let model = MarkdownEditorModel()
        model.connect(view)
        view.commandModel = model
        view.setSelectedRange(NSRange(location: 0, length: 3))

        let menu = view.makeMarkdownMenu(baseMenu: nil)
        let actualCommands = menu.items.compactMap { $0.representedObject as? EditorCommand }
        let headingMenu = menu.items.last?.submenu

        XCTAssertEqual(actualCommands, EditorCommand.context)
        XCTAssertEqual(headingMenu?.items.compactMap { $0.representedObject as? EditorCommand },
                       (0...6).map { .heading(level: $0) })
        XCTAssertTrue(menu.items.first?.isEnabled == true)
        menu.performActionForItem(at: 0)
        XCTAssertEqual(view.string, "**abc**")
        model.disconnect(view)
        XCTAssertFalse(view.makeMarkdownMenu(baseMenu: nil).items.first?.isEnabled == true)
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

        let menu = view.makeMarkdownMenu(baseMenu: nil)
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

        let menu = view.makeMarkdownMenu(baseMenu: nil)
        let index = try! XCTUnwrap(menu.items.firstIndex(where: {
            $0.representedObject as? EditorCommand == .horizontalRule
        }))
        menu.performActionForItem(at: index)

        XCTAssertEqual(view.string, "before\n\n***\n\nafter")
        XCTAssertEqual(EditorCommand.horizontalRule.title, "区切り線")
        XCTAssertNil(EditorCommand.horizontalRule.shortcut)
    }
}
