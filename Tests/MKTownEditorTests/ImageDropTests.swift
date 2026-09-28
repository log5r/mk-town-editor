import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class ImageDropTests: XCTestCase {
    func testPasteboardAcceptsOneImageFileOnly() throws {
        let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { board.releaseGlobally() }
        let image = URL(fileURLWithPath: "/tmp/figure.png")
        let text = URL(fileURLWithPath: "/tmp/notes.txt")

        board.clearContents()
        XCTAssertTrue(board.writeObjects([image as NSURL]))
        XCTAssertEqual(EditorTextView.imageURL(in: board), image)

        board.clearContents()
        XCTAssertTrue(board.writeObjects([text as NSURL]))
        XCTAssertNil(EditorTextView.imageURL(in: board))

        board.clearContents()
        XCTAssertTrue(board.writeObjects([image as NSURL, text as NSURL]))
        XCTAssertNil(EditorTextView.imageURL(in: board))
    }

    func testDropLocationUsesTextLayoutCoordinates() {
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.string = "first\nsecond"
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let firstPoint = view.convert(NSPoint(x: 12, y: 12), to: nil)

        XCTAssertEqual(view.dropInsertionLocation(for: firstPoint), 0)
        XCTAssertNotNil(view.imageDropIndicatorRect(at: 0))
        XCTAssertLessThanOrEqual(view.dropInsertionLocation(for: NSPoint(x: 1000, y: 1000)),
                                 (view.string as NSString).length)
    }
}
