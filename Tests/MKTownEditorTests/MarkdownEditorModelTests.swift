import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownEditorModelTests: XCTestCase {
    func testSelectionExpandsThroughLinkParagraphAndSectionThenShrinks() {
        let source = "# Guide\n\nSee [site](https://example.com).\n\n# Next"
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.string = source
        let model = MarkdownEditorModel()
        model.connect(view)
        let caret = (source as NSString).range(of: "site").location + 1
        view.setSelectedRange(NSRange(location: caret, length: 0))

        model.expandSelection()
        XCTAssertEqual((source as NSString).substring(with: view.selectedRange()),
            "[site](https://example.com)")
        model.expandSelection()
        XCTAssertTrue((source as NSString).substring(with: view.selectedRange()).hasPrefix("See "))
        model.expandSelection()
        XCTAssertTrue((source as NSString).substring(with: view.selectedRange()).hasPrefix("# Guide"))
        model.shrinkSelection()
        XCTAssertTrue((source as NSString).substring(with: view.selectedRange()).hasPrefix("See "))
        model.shrinkSelection()
        XCTAssertEqual((source as NSString).substring(with: view.selectedRange()),
            "[site](https://example.com)")
        model.shrinkSelection()
        XCTAssertEqual(view.selectedRange(), NSRange(location: caret, length: 0))
    }

    func testSelectionExpansionIncludesNestedListItemButNotNextSibling() {
        let source = "- 親\n  - 子\n- 次"
        let location = (source as NSString).range(of: "親").location
        let next = try! XCTUnwrap(MarkdownSelectionExpansion.next(in: source,
            selection: NSRange(location: location, length: 0)))
        XCTAssertEqual((source as NSString).substring(with: next), "- 親\n  - 子\n")
    }

    func testSelectionExpansionIgnoresLinkSyntaxInsideCodeSpan() {
        let source = "`[literal](target)` and [real](target)"
        let location = (source as NSString).range(of: "literal").location
        let next = try! XCTUnwrap(MarkdownSelectionExpansion.next(in: source,
            selection: NSRange(location: location, length: 0)))
        XCTAssertNotEqual((source as NSString).substring(with: next), "[literal](target)")
    }

    func testHeadingAndCodeFoldsHideOnlyFollowingContent() {
        let source = "# 親\n本文\n## 子\n内容\n# 次\n```swift\nlet x = 1\n```\n後"
        let parent = try! XCTUnwrap(MarkdownFoldPlan.at(0, in: source))
        XCTAssertEqual((source as NSString).substring(with: parent.hiddenRange),
            "本文\n## 子\n内容\n")
        let codeLocation = (source as NSString).range(of: "let x").location
        let code = try! XCTUnwrap(MarkdownFoldPlan.at(codeLocation, in: source))
        XCTAssertEqual((source as NSString).substring(with: code.hiddenRange),
            "let x = 1\n```\n")
        XCTAssertEqual(code.headerLocation, (source as NSString).range(of: "```swift").location)
    }

    func testFoldChangesGlyphsWithoutChangingSourceAndNavigationExpands() {
        let source = "# 見出し\n隠す本文\n# 次"
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.string = source
        view.layoutManager?.delegate = view
        let model = MarkdownEditorModel()
        model.connect(view)
        let manager = try! XCTUnwrap(view.layoutManager)
        let container = try! XCTUnwrap(view.textContainer)
        manager.ensureLayout(for: container)
        let expandedHeight = manager.usedRect(for: container).height
        view.setSelectedRange(NSRange(location: 0, length: 0))
        model.toggleFold()
        XCTAssertEqual(view.foldedPlans.count, 1)
        XCTAssertEqual(view.string, source)
        let hidden = (source as NSString).range(of: "隠す本文").location
        manager.ensureGlyphs(forCharacterRange: NSRange(location: 0, length: (source as NSString).length))
        let glyph = manager.glyphIndexForCharacter(at: hidden)
        XCTAssertTrue(manager.propertyForGlyph(at: glyph).contains(.null))
        manager.ensureLayout(for: container)
        XCTAssertLessThan(manager.usedRect(for: container).height, expandedHeight)
        model.navigate(to: hidden)
        XCTAssertTrue(view.foldedPlans.isEmpty)
        XCTAssertEqual(view.selectedRange().location, hidden)
    }

    func testSnippetReplacesTriggerAndTabsThroughEditedPlaceholders() {
        let snippet = EditorSnippet(trigger: "sig", template: "${2:名前}、${1:🙂}より$0")
        let plan = try! XCTUnwrap(MarkdownSnippetPlan.make(snippet, in: "sig",
            selection: NSRange(location: 3, length: 0)))
        let expanded = plan.edit.applying(to: "sig")
        XCTAssertEqual(expanded, "名前、🙂より")
        XCTAssertEqual((expanded as NSString).substring(with: plan.edit.selection), "🙂")
        XCTAssertEqual(plan.placeholders.map { (expanded as NSString).substring(with: $0) },
            ["🙂", "名前"])
        let embedded = try! XCTUnwrap(MarkdownSnippetPlan.make(snippet, in: "prefixsig",
            selection: NSRange(location: 9, length: 0)))
        XCTAssertEqual(embedded.edit.range, NSRange(location: 9, length: 0))

        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.string = "sig"
        let model = MarkdownEditorModel()
        model.connect(view)
        view.commandModel = model
        view.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertTrue(model.insertSnippet(snippet))
        let chosen = view.selectedRange()
        view.textStorage?.replaceCharacters(in: chosen, with: "山田太郎")
        view.setSelectedRange(NSRange(location: chosen.location + 4, length: 0))
        view.insertTab(nil)
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "名前")
        view.insertTab(nil)
        XCTAssertEqual(view.selectedRange(), NSRange(location: (view.string as NSString).length, length: 0))
        XCTAssertEqual(view.string, "名前、山田太郎より")
    }

    func testTabExpandsConfiguredSnippetTrigger() {
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.string = "sig"
        let model = MarkdownEditorModel()
        model.connect(view)
        model.snippets = [EditorSnippet(trigger: "sig", template: "${1:名前}$0")]
        view.commandModel = model
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.insertTab(nil)
        XCTAssertEqual(view.string, "名前")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 2))
    }

    func testRestoredSelectionIsClampedToCurrentDocument() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.string = "short"
        let model = MarkdownEditorModel()
        model.restorePosition(selection: NSRange(location: 40, length: 10),
                              scrollX: 20, scrollY: 120)
        model.connect(view)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 5, length: 0))
        XCTAssertEqual(model.scrollOrigin.y, 120)
        XCTAssertEqual(model.scrollOrigin.x, 20)
        model.restorePosition(selection: NSRange(location: 1, length: 3), scrollY: 0)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 3))
    }

    func testRejectedEditDoesNotChangeTextOrSelection() {
        let view = RejectingTextView()
        view.string = "hello"
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 1, length: 2))

        model.apply(.bold)

        XCTAssertEqual(view.string, "hello")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 2))
    }

    func testMarkedTextDoesNotChangeDuringComposition() {
        let view = MarkedTextView()
        view.string = "日本語"
        let model = MarkdownEditorModel()
        model.connect(view)

        model.apply(.bold)

        XCTAssertEqual(view.string, "日本語")
    }

    func testConsecutiveCommandsUndoIndividually() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.string = "hello"
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 0, length: 5))

        model.apply(.bold)
        XCTAssertEqual(view.string, "**hello**")
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        model.apply(.italic)
        XCTAssertEqual(view.string, "**_hello_**")
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "**hello**")
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "hello")
    }

    func testFootnoteInsertionMovesCaretToDefinitionAndUndoesTogether() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.string = "Text"
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 4, length: 0))

        XCTAssertTrue(model.insertFootnote())
        XCTAssertEqual(view.string, "Text[^fn1]\n\n[^fn1]: ")
        XCTAssertEqual(view.selectedRange().location, (view.string as NSString).length)
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "Text")
    }

    func testToggleRemovesFormattingAndUndoRestoresMarkersAndSelection() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.string = "**word**"
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 2, length: 4))

        model.apply(.bold)
        XCTAssertEqual(view.string, "word")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 4))
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "**word**")
    }

    func testTaskCompletionCommandIsUndoable() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.string = "- [ ] first\n- [x] second"
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))

        model.toggleTaskCompletion()
        XCTAssertEqual(view.string, "- [x] first\n- [x] second")
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "- [ ] first\n- [x] second")
    }

    func testPreviewTaskActionPreservesSourceSelectionAndFocus() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.string = "- [ ] first\n- [ ] second"
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 22, length: 0))

        model.toggleTask(at: 0)

        XCTAssertEqual(view.string, "- [x] first\n- [ ] second")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 22, length: 0))
    }

    func testCodeBlockCommandIsUndoable() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.string = "print(1)"
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 0, length: 8))

        model.apply(.codeBlock(language: .swift))
        XCTAssertEqual(view.string, "```swift\nprint(1)\n```")
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "print(1)")
    }

    func testLinkDialogEditsExistingLinkAndUndoRestoresIt() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.string = "before [old](url \"title\") after"
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: (view.string as NSString).range(of: "old").location, length: 0))

        model.presentLinkEditor()
        XCTAssertEqual(model.linkDraft?.label, "old")
        XCTAssertEqual(model.linkDraft?.destination, "url")
        XCTAssertEqual(model.linkDraft?.title, "title")
        XCTAssertTrue(model.commitLink(label: "new", destination: "path (one)", title: "next"))
        XCTAssertNil(model.linkDraft)
        XCTAssertEqual(view.string, "before [new](path%20\\(one\\) \"next\") after")
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "before [old](url \"title\") after")
    }

    func testLinkDialogRejectsStaleSourceWithoutChangingText() {
        let view = NSTextView()
        view.string = "[old](url)"
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 2, length: 0))
        model.presentLinkEditor()
        view.string = "[changed](url)"

        XCTAssertFalse(model.commitLink(label: "new", destination: "next", title: ""))
        XCTAssertEqual(view.string, "[changed](url)")
    }

    func testDisconnectAndReconnectRestoreSelectionWithoutKeepingOldView() {
        let oldView = NSTextView()
        oldView.string = "前🙂後"
        let model = MarkdownEditorModel()
        model.connect(oldView)
        oldView.setSelectedRange(NSRange(location: 1, length: 2))
        model.selectionDidChange(oldView.selectedRange())
        model.disconnect(oldView)
        XCTAssertNil(model.textView)

        let newView = NSTextView()
        newView.string = oldView.string
        model.connect(newView)
        model.disconnect(oldView)

        XCTAssertTrue(model.textView === newView)
        XCTAssertEqual(newView.selectedRange(), NSRange(location: 1, length: 2))
    }

    func testViewModeTransitionIgnoresSelectionResetDuringRemoval() {
        let model = MarkdownEditorModel()
        let source = "alpha beta alpha"
        let oldView = NSTextView()
        oldView.string = source
        model.connect(oldView)
        let selection = NSRange(location: 6, length: 4)
        oldView.setSelectedRange(selection)
        model.selectionDidChange(selection)

        model.prepareForViewTransition()
        oldView.setSelectedRange(NSRange(location: 0, length: 0))
        model.selectionDidChange(oldView.selectedRange())
        model.disconnect(oldView)

        let replacement = NSTextView()
        replacement.string = source
        model.connect(replacement)
        XCTAssertEqual(model.selectedRange, selection)
        XCTAssertEqual(replacement.selectedRange(), selection)
    }

    func testReconnectClampsSelectionAfterExternalTextChange() {
        let view = NSTextView()
        view.string = "long text"
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 5, length: 4))
        model.disconnect(view)

        let replacement = NSTextView()
        replacement.string = "短"
        model.connect(replacement)

        XCTAssertEqual(replacement.selectedRange(), NSRange(location: 1, length: 0))
    }

    func testNavigationInPreviewModeIsRestoredWhenEditorReconnects() {
        let model = MarkdownEditorModel()
        let text = (0..<80).map { "line \($0)" }.joined(separator: "\n")
        model.navigate(to: (text as NSString).length)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 1_200))
        view.string = text
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        scrollView.documentView = view
        model.connect(view, scrollView: scrollView)

        XCTAssertEqual(view.selectedRange(), NSRange(location: (text as NSString).length, length: 0))
        XCTAssertEqual(model.selectedRange, view.selectedRange())
        XCTAssertGreaterThan(scrollView.contentView.bounds.origin.y, 0)
    }

    func testNavigationInEditorMovesCaretWithoutChangingSourceOrUndo() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.string = "first\nsecond"
        let model = MarkdownEditorModel()
        model.connect(view)

        model.navigate(to: 6)

        XCTAssertEqual(view.selectedRange(), NSRange(location: 6, length: 0))
        XCTAssertEqual(view.string, "first\nsecond")
        XCTAssertFalse(view.undoManager?.canUndo ?? false)
    }

    func testFocusRestoresOnlyForCurrentEditorView() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let model = MarkdownEditorModel()
        model.connect(view)
        model.disconnect(view)
        XCTAssertTrue(model.shouldRestoreFocus)

        let replacement = NSTextView(frame: view.frame)
        window.contentView = replacement
        model.connect(replacement)
        model.restoreFocusIfNeeded(view)
        XCTAssertFalse(window.firstResponder === view)
        model.restoreFocusIfNeeded(replacement)
        XCTAssertTrue(window.firstResponder === replacement)
    }

    func testReconnectRestoresScrollPosition() {
        let model = MarkdownEditorModel()
        let oldView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 1_000))
        let oldScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        oldScrollView.documentView = oldView
        model.connect(oldView, scrollView: oldScrollView)
        oldScrollView.contentView.scroll(to: NSPoint(x: 0, y: 200))
        model.disconnect(oldView, scrollView: oldScrollView)

        let newView = NSTextView(frame: oldView.frame)
        let newScrollView = NSScrollView(frame: oldScrollView.frame)
        newScrollView.documentView = newView
        model.connect(newView, scrollView: newScrollView)

        XCTAssertEqual(newScrollView.contentView.bounds.origin.y, 200)
    }

    func testFocusStateSurvivesViewRemovalBeforeDisconnect() {
        let model = MarkdownEditorModel()
        let view = NSTextView()
        model.connect(view)
        model.editorDidGainFocus(view)

        model.disconnect(view)

        XCTAssertTrue(model.shouldRestoreFocus)
    }

    func testPlainTextHeadingCommandDoesNotCreateAnEdit() {
        let view = ChangeCountingTextView()
        view.string = "本文"
        let model = MarkdownEditorModel()
        model.connect(view)

        model.apply(.heading(level: 0))

        XCTAssertEqual(view.string, "本文")
        XCTAssertEqual(view.changeRequests, 0)
    }
}

private final class RejectingTextView: NSTextView {
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        false
    }
}

private final class MarkedTextView: NSTextView {
    override func hasMarkedText() -> Bool {
        true
    }
}

private final class ChangeCountingTextView: NSTextView {
    var changeRequests = 0

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        changeRequests += 1
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }
}
