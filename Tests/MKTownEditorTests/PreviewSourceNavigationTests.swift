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
