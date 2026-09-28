import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownURLPasteTests: XCTestCase {
    func testSelectedUnicodeTextBecomesLink() throws {
        let source = "前🙂後"
        let selection = (source as NSString).range(of: "🙂")
        let edit = try XCTUnwrap(MarkdownURLPaste.edit(in: source, selection: selection,
                                                     pastedText: " https://example.com/a(b) \n"))
        XCTAssertEqual(edit.applying(to: source), "前[🙂](https://example.com/a\\(b\\))後")
        XCTAssertEqual(edit.selection.location, (edit.applying(to: source) as NSString).range(of: "後").location)
    }

    func testOnlyValidURLOnPlainSelectionIsConverted() {
        let source = "text [link](https://example.com)"
        XCTAssertNil(MarkdownURLPaste.edit(in: source, selection: NSRange(location: 0, length: 0),
                                           pastedText: "https://example.com"))
        XCTAssertNil(MarkdownURLPaste.edit(in: source, selection: NSRange(location: 0, length: 4),
                                           pastedText: "ordinary text"))
        let insideLink = (source as NSString).range(of: "link")
        XCTAssertNil(MarkdownURLPaste.edit(in: source, selection: insideLink,
                                           pastedText: "https://example.com/new"))
        XCTAssertNil(MarkdownURLPaste.validURL("javascript:alert(1)"))
        XCTAssertEqual(MarkdownURLPaste.validURL("mailto:person@example.com"), "mailto:person@example.com")
    }

    func testPasteActionUsesSingleEditorEditAndOffersPlainPaste() {
        let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("https://example.com", forType: .string)
        let view = EditorTextView()
        view.string = "selected"
        view.imagePasteboard = board
        let model = MarkdownEditorModel()
        model.connect(view)
        view.commandModel = model
        view.setSelectedRange(NSRange(location: 0, length: 8))

        XCTAssertNotNil(view.makeMarkdownMenu(baseMenu: nil)
            .items.first(where: { $0.title == "URL をそのまま貼り付け" }))
        view.paste(nil)
        XCTAssertEqual(view.string, "[selected](https://example.com)")
    }
}
