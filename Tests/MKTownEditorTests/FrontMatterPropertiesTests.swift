import AppKit
import XCTest
@testable import MKTownEditor

final class FrontMatterPropertiesTests: XCTestCase {
    func testUpdatesScalarWithoutChangingUnknownPropertiesOrComments() throws {
        let source = "---\ntitle: Old # editorial note\ncustom:\n  nested: keep\ntags: [swift, app]\n---\n# Body"
        let items = FrontMatterProperties.items(in: source)
        XCTAssertEqual(items.map(\.key), ["title", "tags"])
        XCTAssertEqual(items.first?.value, "Old")
        let edit = try XCTUnwrap(FrontMatterProperties.upsert(in: source, key: "title", value: "New"))
        XCTAssertEqual(edit.applying(to: source),
            "---\ntitle: New # editorial note\ncustom:\n  nested: keep\ntags: [swift, app]\n---\n# Body")
        XCTAssertNil(FrontMatterProperties.upsert(in: source, key: "custom", value: "changed"))
    }

    func testAddsAndRemovesPropertiesWhilePreservingCRLF() throws {
        let source = "---\r\ntitle: Old\r\n# keep\r\n---\r\nBody"
        let added = try XCTUnwrap(FrontMatterProperties.upsert(in: source, key: "author", value: "A"))
            .applying(to: source)
        XCTAssertEqual(added, "---\r\ntitle: Old\r\n# keep\r\nauthor: A\r\n---\r\nBody")
        let removed = try XCTUnwrap(FrontMatterProperties.remove(in: added, key: "title"))
            .applying(to: added)
        XCTAssertEqual(removed, "---\r\n# keep\r\nauthor: A\r\n---\r\nBody")
    }

    func testCreatesFrontMatterAndRejectsInvalidInput() throws {
        let source = "# Body\n"
        let edit = try XCTUnwrap(FrontMatterProperties.upsert(in: source,
            key: "title", value: "A document"))
        XCTAssertEqual(edit.applying(to: source), "---\ntitle: A document\n---\n# Body\n")
        XCTAssertNil(FrontMatterProperties.upsert(in: source, key: "bad key", value: "value"))
        XCTAssertNil(FrontMatterProperties.upsert(in: source, key: "title", value: "line\nnext"))
        XCTAssertNil(FrontMatterProperties.upsert(in: source, key: "title", value: "#comment"))
        XCTAssertNotNil(FrontMatterProperties.upsert(in: source, key: "title", value: "\"#literal\""))
        XCTAssertNil(FrontMatterProperties.remove(in: source, key: "title"))
    }

    func testQuotedHashesAndDuplicateKeysDoNotLoseCommentsOrDuplicateRows() throws {
        let source = "---\ntitle: \"A \\\"# B\" # keep\ntitle: Duplicate\n---\n"
        let properties = FrontMatterProperties.items(in: source)
        XCTAssertEqual(properties.count, 1)
        XCTAssertEqual(properties[0].value, "\"A \\\"# B\"")
        let edit = try XCTUnwrap(FrontMatterProperties.upsert(in: source,
            key: "title", value: "\"New\""))
        XCTAssertEqual(edit.applying(to: source),
                       "---\ntitle: \"New\" # keep\ntitle: Duplicate\n---\n")
    }

    func testEmptyScalarCanBeEditedWhileNestedAndBlockValuesStayProtected() throws {
        let source = "---\ntitle: # add later\ntags:\n  - swift\ndescription: |\n  line\n---\n"
        XCTAssertEqual(FrontMatterProperties.items(in: source).map(\.key), ["title"])
        let edit = try XCTUnwrap(FrontMatterProperties.upsert(in: source,
            key: "title", value: "Document"))
        XCTAssertEqual(edit.applying(to: source),
                       "---\ntitle: Document # add later\ntags:\n  - swift\ndescription: |\n  line\n---\n")
        XCTAssertNil(FrontMatterProperties.upsert(in: source, key: "tags", value: "swift"))
    }
}

@MainActor
final class FrontMatterPropertiesEditorTests: XCTestCase {
    func testPropertyEditUsesUndoableRangeReplacement() throws {
        let source = "---\ntitle: Old\nunknown: keep\n---\nBody"
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.string = source
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let model = MarkdownEditorModel()
        model.connect(view)
        let edit = try XCTUnwrap(FrontMatterProperties.upsert(in: source,
            key: "title", value: "New"))

        XCTAssertTrue(model.applyRegexEdit(edit, expectedSource: source))
        XCTAssertEqual(view.string, "---\ntitle: New\nunknown: keep\n---\nBody")
        view.undoManager?.undo()
        XCTAssertEqual(view.string, source)
    }
}
