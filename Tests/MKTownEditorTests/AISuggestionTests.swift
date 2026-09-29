import Foundation
import XCTest
@testable import MKTownEditor

final class AISuggestionTests: XCTestCase {
    func testRequestContainsOnlySelectionAndDisablesResponseStorage() throws {
        let fullDocument = "private prefix\nTARGET\nprivate suffix"
        let selection = "TARGET"
        let request = try AISuggestion.request(selectedText: selection, operation: .proofread,
                                               targetLanguage: "", apiKey: "test-key")
        XCTAssertEqual(request.url, AISuggestion.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["input"] as? String, selection)
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["model"] as? String, "gpt-6-luna")
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "none")
        let encoded = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertFalse(encoded.contains(fullDocument))
        XCTAssertFalse(encoded.contains("private prefix"))
    }

    func testTranslationRequiresLanguageAndRejectsEmptyOrLongSelection() {
        XCTAssertThrowsError(try AISuggestion.request(selectedText: "Hello", operation: .translate,
            targetLanguage: "", apiKey: "key"))
        XCTAssertThrowsError(try AISuggestion.request(selectedText: "", operation: .proofread,
            targetLanguage: "", apiKey: "key"))
        XCTAssertThrowsError(try AISuggestion.request(selectedText: String(repeating: "x", count: 6_001),
            operation: .proofread, targetLanguage: "", apiKey: "key"))
        XCTAssertThrowsError(try AISuggestion.request(selectedText: "Hello", operation: .proofread,
            targetLanguage: "", apiKey: "bad\nkey"))
    }

    func testResponseCollectsOnlyOutputTextAcrossItems() throws {
        let json = """
        {"status":"completed","output":[
          {"type":"reasoning"},
          {"type":"message","content":[{"type":"output_text","text":"Revised "}]},
          {"type":"message","content":[{"type":"output_text","text":"text"}]}]}
        """
        XCTAssertEqual(try AISuggestion.responseText(from: Data(json.utf8)), "Revised text")
        XCTAssertThrowsError(try AISuggestion.responseText(from:
            Data("{\"status\":\"incomplete\",\"output\":[]}".utf8)))
    }

    func testDiffMarksRemovedAndAddedLines() {
        let rows = AISuggestionDiff.rows(original: "one\nold\nthree", suggested: "one\nnew\nthree")
        XCTAssertEqual(rows.map(\.text), ["one", "old", "new", "three"])
        XCTAssertEqual(rows.map(\.kind), [.unchanged, .removed, .added, .unchanged])
    }

    func testDiffRowsReconstructBothVersionsAcrossSeparateChanges() {
        let examples = [
            ("a\nb\nc\nd", "a\nx\nc\ny"),
            ("a\nb\nc", "c\na\nb"),
            ("", "new"),
            ("old", ""),
            ("a\n", "a\nnew\n")
        ]
        for (original, suggested) in examples {
            let rows = AISuggestionDiff.rows(original: original, suggested: suggested)
            XCTAssertEqual(rows.filter { $0.kind != .added }.map(\.text).joined(separator: "\n"), original)
            XCTAssertEqual(rows.filter { $0.kind != .removed }.map(\.text).joined(separator: "\n"), suggested)
        }
    }

    func testRevisionChangesOnlyCapturedSelectionAndRejectsStaleDocument() throws {
        let original = "前👨‍👩‍👧後"
        let revision = try XCTUnwrap(AISuggestionRevision(source: original,
            range: NSRange(location: 1, length: 8)))
        XCTAssertEqual(revision.selectedText, "👨‍👩‍👧")
        let edit = try XCTUnwrap(revision.edit(suggested: "🌟", currentSource: original))
        XCTAssertEqual(edit.range, NSRange(location: 1, length: 8))
        XCTAssertEqual(edit.replacement, "🌟")
        XCTAssertEqual(edit.selection, NSRange(location: 3, length: 0))
        XCTAssertNil(revision.edit(suggested: "🌟", currentSource: "変更"))
        XCTAssertNil(revision.edit(suggested: "👨‍👩‍👧", currentSource: original))
    }
}
