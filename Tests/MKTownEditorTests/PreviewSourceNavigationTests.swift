import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class PreviewSourceNavigationTests: XCTestCase {
    func testPreviewBlockRangeSelectsSourceWithoutChangingText() {
        let source = "# Heading\n\nParagraph\n\n```swift\nprint(1)\n```"
        let analysis = MarkdownAnalysis(source)
        let view = NSTextView()
        view.string = source
        let model = MarkdownEditorModel()
        model.connect(view)

        for block in analysis.blocks where block.kind != .blank {
            model.selectAndReveal(block.sourceRange)
            XCTAssertEqual(view.selectedRange(), block.sourceRange)
            XCTAssertEqual(view.string, source)
        }
    }

    func testInspectorWarningsFollowTheSourceAndSelectTheExactCharacters() throws {
        var document = try MarkdownDocument(data: Data("a\r\nb\nc\r\n".utf8), encoding: .latin1)
        document.text = "a🙂\nb\nc\n🍎"
        let warnings = DocumentSaveWarnings(input: try XCTUnwrap(.init(document: document)))

        XCTAssertEqual(warnings.items.map(\.range), [
            NSRange(location: 1, length: 2), NSRange(location: 5, length: 1),
            NSRange(location: 8, length: 2)
        ])
        let model = MarkdownEditorModel()
        let editor = NSTextView()
        editor.string = document.text
        model.connect(editor)
        for (item, expected) in zip(warnings.items, ["🙂", "\n", "🍎"]) {
            model.selectAndReveal(item.range, focusesEditor: false)
            XCTAssertEqual((editor.string as NSString).substring(with: editor.selectedRange()), expected)
        }

        document.format.normalizeNewlines()
        XCTAssertNotEqual(warnings.input, DocumentSaveWarnings.Input(document: document))
        let updated = DocumentSaveWarnings(input: try XCTUnwrap(.init(document: document)))
        XCTAssertEqual(updated.items.count, 2)
        document.convertToUTF8()
        XCTAssertNil(DocumentSaveWarnings.Input(document: document))
    }

    func testSelectionSurvivesPreviewToEditorViewCreation() {
        let source = "# Heading\n\nBody"
        let analysis = MarkdownAnalysis(source)
        let block = analysis.blocks.first { $0.kind == .paragraph }!
        let model = MarkdownEditorModel()

        model.selectAndReveal(block.sourceRange)
        let view = NSTextView()
        view.string = source
        model.connect(view)

        XCTAssertEqual(view.selectedRange(), block.sourceRange)
        XCTAssertEqual(model.selectedRange, block.sourceRange)
    }
}
