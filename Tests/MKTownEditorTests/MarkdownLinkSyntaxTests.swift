import XCTest
@testable import MKTownEditor

final class MarkdownLinkSyntaxTests: XCTestCase {
    func testNewLinkUsesSelectedUnicodeAsLabel() {
        let source = "前🙂後"
        let draft = MarkdownLinkSyntax.draft(in: source,
            selection: (source as NSString).range(of: "🙂"))

        XCTAssertFalse(draft.isExisting)
        XCTAssertEqual(draft.label, "🙂")
        let edit = try! XCTUnwrap(MarkdownLinkSyntax.edit(in: source, draft: draft,
            label: draft.label, destination: "https://example.com/a b(c)", title: "A \"title\""))
        XCTAssertEqual(edit.applying(to: source),
                       "前[🙂](https://example.com/a%20b\\(c\\) \"A \\\"title\\\"\")後")
        XCTAssertEqual(edit.selection.location, (edit.applying(to: source) as NSString).range(of: "後").location)
    }

    func testExistingLinkAtCaretLoadsAndReplacesWholeSyntax() {
        let source = "before [label](foo\\(bar\\) \"old\\\"title\") after"
        let draft = MarkdownLinkSyntax.draft(in: source,
            selection: NSRange(location: (source as NSString).range(of: "label").location + 2, length: 0))

        XCTAssertTrue(draft.isExisting)
        XCTAssertEqual(draft.label, "label")
        XCTAssertEqual(draft.destination, "foo(bar)")
        XCTAssertEqual(draft.title, "old\"title")
        let edit = try! XCTUnwrap(MarkdownLinkSyntax.edit(in: source, draft: draft,
            label: "new", destination: "next path", title: ""))
        XCTAssertEqual(edit.applying(to: source), "before [new](next%20path) after")
    }

    func testAngleDestinationAndFormattedLabelArePreservedWhenOnlyURLChanges() {
        let source = "[**bold**](<a b(c)> \"title\")"
        let draft = MarkdownLinkSyntax.draft(in: source,
            selection: NSRange(location: 0, length: (source as NSString).length))

        XCTAssertTrue(draft.isExisting)
        XCTAssertEqual(draft.destination, "a b(c)")
        let edit = try! XCTUnwrap(MarkdownLinkSyntax.edit(in: source, draft: draft,
            label: draft.label, destination: "next (path)", title: draft.title))
        XCTAssertEqual(edit.applying(to: source), "[**bold**](next%20\\(path\\) \"title\")")
    }

    func testCodeAndImageSyntaxAreNotEditedAsLinks() {
        for source in ["`[code](url)`", "![image](url)"] {
            let draft = MarkdownLinkSyntax.draft(in: source,
                selection: NSRange(location: (source as NSString).range(of: "url").location, length: 0))
            XCTAssertFalse(draft.isExisting)
        }
        let escapedImageMarker = "\\![link](url)"
        let draft = MarkdownLinkSyntax.draft(in: escapedImageMarker,
            selection: NSRange(location: (escapedImageMarker as NSString).range(of: "url").location, length: 0))
        XCTAssertTrue(draft.isExisting)
    }

    func testStaleDraftCannotReplaceChangedDocument() {
        let source = "[old](url)"
        let draft = MarkdownLinkSyntax.draft(in: source, selection: NSRange(location: 2, length: 0))
        XCTAssertNil(MarkdownLinkSyntax.edit(in: "[new](url)", draft: draft,
                                              label: "other", destination: "next", title: ""))
        XCTAssertNil(MarkdownLinkSyntax.edit(in: "x[old](url)", draft: draft,
                                              label: "other", destination: "next", title: ""))
    }

    func testLiteralBackslashBeforeLetterIsNotRemovedFromExistingURL() {
        let source = "[label](foo\\bar)"
        let draft = MarkdownLinkSyntax.draft(in: source, selection: NSRange(location: 2, length: 0))
        XCTAssertEqual(draft.destination, "foo\\bar")
    }

    func testDestinationEscapingLeavesExistingPercentEncodingAlone() {
        XCTAssertEqual(MarkdownLinkSyntax.escapeDestination("a%20b(c) d"), "a%20b\\(c\\)%20d")
    }

    @MainActor
    func testGeneratedLinkRendersWithDestinationContainingSpaceAndParentheses() {
        let markdown = MarkdownLinkSyntax.makeLink(label: "例", destination: "https://example.com/a b(c)")
        let rendered = MarkdownRenderer.render(markdown)

        XCTAssertEqual(rendered.string, "例")
        XCTAssertEqual(rendered.attribute(.link, at: 0, effectiveRange: nil) as? URL,
                       URL(string: "https://example.com/a%20b(c)"))
    }

    func testImageSyntaxSharesDestinationAndTitleEscaping() {
        XCTAssertEqual(MarkdownLinkSyntax.makeImage(alt: "a]b", destination: "assets/a b(c).png",
                                                      title: "A \"title\""),
                       "![a\\]b](assets/a%20b\\(c\\).png \"A \\\"title\\\"\")")
    }

    func testConvertInlineLinkToReferenceAndBackWithoutDeletingSharedDefinition() throws {
        let source = "[案内](guide%20one.md \"説明\") と [別](other.md)"
        let selection = (source as NSString).range(of: "案内")
        let edit = try XCTUnwrap(MarkdownReferenceConversion.edit(in: source,
            selection: selection))
        let converted = try XCTUnwrap(edit.applying(to: source))
        XCTAssertTrue(converted.contains("[案内][案内] と [別](other.md)"))
        XCTAssertTrue(converted.contains("[案内]: guide%20one.md \"説明\""))
        let back = try XCTUnwrap(MarkdownReferenceConversion.edit(in: converted,
            selection: NSRange(location: 2, length: 0)))
        let restored = try XCTUnwrap(back.applying(to: converted))
        XCTAssertTrue(restored.contains("[案内](guide%20one.md \"説明\")"))
        XCTAssertTrue(restored.contains("[案内]: guide%20one.md \"説明\""))
    }

    func testConvertInlineLinkReusesMatchingDefinitionAndSkipsCode() throws {
        let source = "[site](https://example.com) [shared][id]\n\n[id]: https://example.com"
        let range = (source as NSString).range(of: "site")
        let edit = try XCTUnwrap(MarkdownReferenceConversion.edit(in: source,
            selection: range))
        XCTAssertEqual(edit.applying(to: source),
            "[site][id] [shared][id]\n\n[id]: https://example.com")
        let code = "`[site](https://example.com)`"
        XCTAssertNil(MarkdownReferenceConversion.edit(in: code,
            selection: (code as NSString).range(of: "site")))
    }

    func testConvertLinkKeepsConflictingReferenceAndEscapedLabel() throws {
        let source = "[site](new.md)\n\n[site]: old.md"
        let edit = try XCTUnwrap(MarkdownReferenceConversion.edit(in: source,
            selection: NSRange(location: 2, length: 0)))
        let converted = try XCTUnwrap(edit.applying(to: source))
        XCTAssertTrue(converted.contains("[site][site-2]"))
        XCTAssertTrue(converted.contains("[site]: old.md"))
        XCTAssertTrue(converted.contains("[site-2]: new.md"))
        let escaped = "[a\\]b][id]\n\n[id]: doc.md"
        let back = try XCTUnwrap(MarkdownReferenceConversion.edit(in: escaped,
            selection: NSRange(location: 2, length: 0)))
        XCTAssertTrue(try XCTUnwrap(back.applying(to: escaped)).hasPrefix("[a\\]b](doc.md)"))
    }

    func testImageDraftUsesSelectedTextAndRejectsStaleDocument() {
        let source = "前🙂後"
        let draft = MarkdownLinkSyntax.imageDraft(in: source,
            selection: (source as NSString).range(of: "🙂"))
        XCTAssertEqual(draft.alt, "🙂")
        let edit = try! XCTUnwrap(MarkdownLinkSyntax.imageEdit(in: source, draft: draft,
            alt: draft.alt, destination: "assets/a b.png", title: "写真"))
        XCTAssertEqual(edit.applying(to: source), "前![🙂](assets/a%20b.png \"写真\")後")
        let sized = try! XCTUnwrap(MarkdownLinkSyntax.imageEdit(in: source, draft: draft,
            alt: draft.alt, destination: "assets/a b.png", title: "写真", width: 320))
        XCTAssertEqual(sized.applying(to: source),
            "前![🙂](assets/a%20b.png \"写真\"){width=320}後")
        XCTAssertNil(MarkdownLinkSyntax.imageEdit(in: source, draft: draft,
            alt: draft.alt, destination: "image.png", title: "", width: 0))
        XCTAssertNil(MarkdownLinkSyntax.imageEdit(in: "変化" + source, draft: draft,
            alt: draft.alt, destination: "assets/a b.png", title: ""))
        XCTAssertNil(MarkdownLinkSyntax.imageEdit(in: source, draft: draft,
            alt: " ", destination: "assets/a b.png", title: ""))
    }
}
