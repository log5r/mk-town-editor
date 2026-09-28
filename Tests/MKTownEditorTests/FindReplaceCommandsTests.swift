import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class FindReplaceCommandsTests: XCTestCase {
    func testCommandsUseStandardTextFinderActions() {
        let view = FinderSpyTextView()
        view.string = "alpha beta alpha"
        let model = MarkdownEditorModel()
        model.connect(view)

        model.showFindBar()
        model.showReplaceBar()
        model.findNext()
        model.findPrevious()
        model.replaceAllMatches()

        XCTAssertEqual(view.actions, [.showFindInterface, .showReplaceInterface,
                                      .nextMatch, .previousMatch, .replaceAll])
    }

    func testReplaceAllIsDisabledDuringMarkedText() {
        let view = FinderSpyTextView()
        view.simulatesMarkedText = true
        let model = MarkdownEditorModel()
        model.connect(view)

        model.replaceAllMatches()

        XCTAssertTrue(view.actions.isEmpty)
    }
}

@MainActor
private final class FinderSpyTextView: NSTextView {
    var actions: [NSTextFinder.Action] = []
    var simulatesMarkedText = false

    override func hasMarkedText() -> Bool { simulatesMarkedText }

    override func performTextFinderAction(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let action = NSTextFinder.Action(rawValue: item.tag) else { return }
        actions.append(action)
    }
}
