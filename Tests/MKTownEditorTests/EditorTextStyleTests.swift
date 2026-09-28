import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class EditorTextStyleTests: XCTestCase {
    func testApplyingStyleUpdatesLayoutWithoutChangingSourceOrUndo() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.allowsUndo = true
        textView.string = "# 見出し\n本文"
        let source = textView.string
        let selection = NSRange(location: 3, length: 2)
        textView.setSelectedRange(selection)

        EditorTextStyle(fontChoice: .menlo, fontSize: 17, lineSpacing: 6,
                        horizontalMargin: 22, verticalMargin: 16).apply(to: textView)

        XCTAssertEqual(textView.font?.pointSize, 17)
        XCTAssertEqual(textView.textContainerInset, NSSize(width: 22, height: 16))
        XCTAssertEqual(textView.defaultParagraphStyle?.lineSpacing, 6)
        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(textView.selectedRange(), selection)
        XCTAssertFalse(textView.undoManager?.canUndo ?? false)
    }
}
