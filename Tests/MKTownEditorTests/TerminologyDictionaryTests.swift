import Foundation
import AppKit
import XCTest
@testable import MKTownEditor

final class TerminologyDictionaryTests: XCTestCase {
    func testJapaneseAndEnglishMatchesUseUTF16RangesAndProvideReplacement() {
        let source = "😀 コンピュータ and color. コンピュータ"
        let entries = [TerminologyEntry(prohibited: "コンピュータ", preferred: "コンピューター"),
                       TerminologyEntry(prohibited: "color", preferred: "colour")]
        let issues = TerminologyDictionary.inspect(source, entries: entries)
        let text = source as NSString

        XCTAssertEqual(issues.count, 3)
        XCTAssertEqual(issues.map { text.substring(with: $0.range) },
                       ["コンピュータ", "color", "コンピュータ"])
        let edit = issues[0].replacement(in: source)
        XCTAssertEqual(edit?.applying(to: source), "😀 コンピューター and color. コンピュータ")
        XCTAssertEqual(edit?.selection.location,
                       issues[0].range.location + ("コンピューター" as NSString).length)
        XCTAssertNil(issues[0].replacement(in: "変更された本文"))
    }

    func testCodeQuoteAndLinkDestinationExclusionsCanBeConfigured() {
        let source = "word\n> word\n`word`\n```\nword\n```\n[word](word.md)"
        let entry = TerminologyEntry(prohibited: "word", preferred: "term")
        let text = source as NSString
        let standard = TerminologyDictionary.inspect(source, entries: [entry])
        XCTAssertEqual(standard.map { $0.range.location },
                       [text.range(of: "word").location, text.range(of: "[word]").location + 1])

        let allProse = TerminologyDictionary.inspect(source, entries: [entry],
            options: TerminologyOptions(excludesCode: false, excludesQuotes: false))
        XCTAssertEqual(allProse.count, 5)
        XCTAssertFalse(allProse.contains { $0.range.location == text.range(of: "word.md").location })
    }

    func testEarlierDictionaryEntryWinsOverOverlappingLaterEntry() {
        let source = "data base"
        let first = TerminologyEntry(prohibited: "data", preferred: "dataset")
        let second = TerminologyEntry(prohibited: "data base", preferred: "database")
        let issues = TerminologyDictionary.inspect(source, entries: [first, second])
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].entryID, first.id)
        XCTAssertEqual(TerminologyDictionary.inspect(source, entries: [second, first])[0].entryID,
                       second.id)
    }

    func testEmptyAndIdentityEntriesAreIgnored() {
        let entries = [TerminologyEntry(prohibited: "", preferred: "new"),
                       TerminologyEntry(prohibited: "old", preferred: ""),
                       TerminologyEntry(prohibited: "old", preferred: "old")]
        XCTAssertTrue(TerminologyDictionary.inspect("old", entries: entries).isEmpty)
    }

    func testCancelledScanReturnsNoPartialIssues() async {
        let entry = TerminologyEntry(prohibited: "old", preferred: "new")
        let worker = Task.detached {
            try? await Task.sleep(for: .milliseconds(100))
            return TerminologyDictionary.inspect("old old", entries: [entry])
        }
        worker.cancel()
        let result = await worker.value
        XCTAssertTrue(result.isEmpty)
    }
}

@MainActor
final class TerminologyDictionaryEditorTests: XCTestCase {
    func testSuggestedReplacementUsesOneUndoableRangeEdit() throws {
        let source = "古い語と古い語"
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.string = source
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let model = MarkdownEditorModel()
        model.connect(view)
        let issue = try XCTUnwrap(TerminologyDictionary.inspect(source,
            entries: [TerminologyEntry(prohibited: "古い語", preferred: "新しい語")]).first)
        let edit = try XCTUnwrap(issue.replacement(in: source))

        XCTAssertTrue(model.applyRegexEdit(edit, expectedSource: source))
        XCTAssertEqual(view.string, "新しい語と古い語")
        view.undoManager?.undo()
        XCTAssertEqual(view.string, source)
        XCTAssertFalse(model.applyRegexEdit(edit, expectedSource: "変更された本文"))
    }
}
