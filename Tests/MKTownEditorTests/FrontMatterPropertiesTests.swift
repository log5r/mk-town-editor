import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

final class FrontMatterPropertiesTests: XCTestCase {
    private func previewRows(_ content: String) throws -> [FrontMatterPreviewProperties.Row] {
        let frontMatter = try XCTUnwrap(MarkdownFrontMatter(source: "---\n\(content)\n---\n# Body"))
        return try XCTUnwrap(FrontMatterPreviewProperties.rows(in: frontMatter))
    }

    func testPreviewFormatsObsidianPropertiesInSourceOrder() throws {
        let rows = try previewRows("title: 'My note'\ntags: [swift, project/app]\naliases:\n  - First name\n  - 'Other name'\ndate: 2026-10-26\npublish: false\n評価: 3")
        XCTAssertEqual(rows.map(\.key), ["title", "tags", "aliases", "date", "publish", "評価"])
        XCTAssertEqual(rows.map(\.values), [["My note"], ["swift", "project/app"],
            ["First name", "Other name"], ["2026-10-26"], ["false"], ["3"]])
        XCTAssertTrue(rows.allSatisfy { !$0.isVerbatim })
    }

    func testPreviewSupportsUnindentedObsidianListsAndCRLF() throws {
        let source = "---\r\ntags:\r\n- journal\r\n- personal\r\naliases: []\r\n...\r\nBody"
        let frontMatter = try XCTUnwrap(MarkdownFrontMatter(source: source))
        let rows = try XCTUnwrap(FrontMatterPreviewProperties.rows(in: frontMatter))
        XCTAssertEqual(rows.map(\.values), [["journal", "personal"], []])
        XCTAssertEqual(rows.map(\.key), ["tags", "aliases"])
        XCTAssertEqual(frontMatter.raw, "---\r\ntags:\r\n- journal\r\n- personal\r\naliases: []\r\n...\r\n")
        let complex = try XCTUnwrap(MarkdownFrontMatter(source:
            "---\r\ndescription: |\r\n  first\r\n\r\n  second\r\n---\r\n"))
        let complexRows = try XCTUnwrap(FrontMatterPreviewProperties.rows(in: complex))
        XCTAssertEqual(complexRows[0].values, ["|\n  first\n\n  second\n"])
    }

    func testPreviewPreservesQuotedCommasHashesEscapesAndLiteralMarkdown() throws {
        let rows = try previewRows(#"tags: ["one,two", '#literal', project/app] # comment"# + "\n" +
            #"title: "A \"quote\" # hash" # comment"# + "\n" +
            "aliases: 'It''s a note'\nlink: '[[Note]]'\ntext: **bold**\nurl: https://example.com/#section")
        XCTAssertEqual(rows.map(\.values), [["one,two", "#literal", "project/app"],
            ["A \"quote\" # hash"], ["It's a note"], ["[[Note]]"], ["**bold**"],
            ["https://example.com/#section"]])
    }

    func testPreviewRetainsComplexYAMLAndDuplicateProperties() throws {
        let rows = try previewRows("custom:\n  nested: keep\ndescription: |\n  line one\n\n  # actual content\n  line two\ntags: [a, [b, c]]\ntitle: First\ntitle: Second")
        XCTAssertEqual(rows.map(\.key), ["custom", "description", "tags", "title", "title"])
        XCTAssertTrue(rows[0].isVerbatim)
        XCTAssertEqual(rows[0].values, ["\n  nested: keep"])
        XCTAssertTrue(rows[1].isVerbatim)
        XCTAssertEqual(rows[1].values, ["|\n  line one\n\n  # actual content\n  line two"])
        XCTAssertTrue(rows[2].isVerbatim)
        XCTAssertEqual(rows[2].values, ["[a, [b, c]]"])
        XCTAssertEqual(rows.suffix(2).map(\.values), [["First"], ["Second"]])
    }

    func testPreviewRetainsUnsupportedAndMalformedScalarAndListValues() throws {
        for value in ["[one, two", "'unclosed", #""YAML\eescape""#, "&anchor value", "[one # comment, two]",
                      "{nested: value}", "[one,,two]", "[one, {nested: two}]", "*alias", "|"] {
            let row = try XCTUnwrap(previewRows("custom: \(value)").first)
            XCTAssertTrue(row.isVerbatim, value)
            XCTAssertTrue(row.values[0].hasPrefix(value), value)
        }
        let nested = try previewRows("tags:\n  - one\n    - nested")
        XCTAssertTrue(nested[0].isVerbatim)
        XCTAssertEqual(nested[0].values, ["\n  - one\n    - nested\n"])
    }

    func testPreviewUsesRawFallbackForUnsupportedDocumentStructures() throws {
        for content in ["{\"tags\": [\"one\"]}", "'quoted key': value", "- list root", "invalid YAML"] {
            let frontMatter = try XCTUnwrap(MarkdownFrontMatter(source: "---\n\(content)\n---\n"))
            XCTAssertNil(FrontMatterPreviewProperties.rows(in: frontMatter), content)
            XCTAssertTrue(frontMatter.raw.contains(content))
        }
    }

    func testPreviewCommentsAndEmptyPropertiesDoNotCreateExtraRows() throws {
        let rows = try previewRows("# note\ntitle: Hello # comment\n\n# next\nempty: # later\ntags:\n  # tags\n  - swift # comment\n  - app\n")
        XCTAssertEqual(rows.map(\.key), ["title", "empty", "tags"])
        XCTAssertEqual(rows.map(\.values), [["Hello"], [""], ["swift", "app"]])
        XCTAssertTrue(rows.allSatisfy { !$0.isVerbatim })
        XCTAssertTrue(try previewRows("").isEmpty)
    }

    func testPreviewPreservesNegativeNumbersAndHyphenatedText() throws {
        let rows = try previewRows("offset: -3.5\nlabel: -draft\ntags: [-draft, app]")
        XCTAssertEqual(rows.map(\.values), [["-3.5"], ["-draft"], ["-draft", "app"]])
        XCTAssertTrue(rows.allSatisfy { !$0.isVerbatim })
    }

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
    func testPropertyCardWrapsLongValuesAndRespectsPreviewZoom() throws {
        let source = "---\ntitle: A long note title with enough words to wrap in a narrow preview pane\ntags: [journal, personal, project/app]\n---\n"
        let frontMatter = try XCTUnwrap(MarkdownFrontMatter(source: source))
        func height(width: CGFloat, zoom: Double, formatted: Bool = true) -> CGFloat {
            let view = NSHostingView(rootView: FrontMatterPreviewView(frontMatter: frontMatter,
                formatsProperties: formatted, theme: .paper, zoom: zoom).frame(width: width))
            return view.fittingSize.height
        }
        let narrow = height(width: 280, zoom: 1)
        XCTAssertGreaterThan(narrow, height(width: 700, zoom: 1))
        XCTAssertGreaterThan(height(width: 280, zoom: 2), narrow)
        XCTAssertGreaterThan(height(width: 280, zoom: 1, formatted: false), 0)
    }

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
