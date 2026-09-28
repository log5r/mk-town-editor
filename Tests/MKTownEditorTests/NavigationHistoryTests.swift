import Foundation
import XCTest
@testable import MKTownEditor

final class NavigationHistoryTests: XCTestCase {
    func testBackForwardTrackExplicitJumpsWithoutRecordingTyping() {
        let url = URL(fileURLWithPath: "/tmp/chapter.md")
        let start = NavigationPoint(documentURL: url, utf16Location: 2)
        let heading = NavigationPoint(documentURL: url, utf16Location: 50)
        let afterTyping = NavigationPoint(documentURL: url, utf16Location: 54)
        var history = NavigationHistory()

        history.recordJump(from: start, to: heading)
        XCTAssertTrue(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.goBack(from: afterTyping), start)
        XCTAssertEqual(history.goForward(from: start), afterTyping)
        XCTAssertEqual(history.back.count, 1)
    }

    func testNewJumpClearsForwardAndSameLocationDoesNotAddHistory() {
        let start = NavigationPoint(documentURL: nil, utf16Location: 0)
        let second = NavigationPoint(documentURL: nil, utf16Location: 12)
        let third = NavigationPoint(documentURL: nil, utf16Location: 24)
        var history = NavigationHistory()

        history.recordJump(from: start, to: start)
        XCTAssertFalse(history.canGoBack)
        history.recordJump(from: start, to: second)
        XCTAssertEqual(history.goBack(from: second), start)
        history.recordJump(from: start, to: third)
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.goBack(from: third), start)
    }

    func testDocumentIdentityIsKeptWithSameTextPosition() {
        let first = NavigationPoint(documentURL: URL(fileURLWithPath: "/tmp/one.md"), utf16Location: 8)
        let second = NavigationPoint(documentURL: URL(fileURLWithPath: "/tmp/two.md"), utf16Location: 8)
        var history = NavigationHistory()

        history.recordJump(from: first, to: second)
        XCTAssertEqual(history.goBack(from: second), first)
    }

    func testHistoryFollowsFirstSaveAndRename() {
        let saved = URL(fileURLWithPath: "/tmp/saved.md")
        let renamed = URL(fileURLWithPath: "/tmp/renamed.md")
        let start = NavigationPoint(documentURL: nil, utf16Location: 4)
        let later = NavigationPoint(documentURL: nil, utf16Location: 20)
        var history = NavigationHistory()
        history.recordJump(from: start, to: later)
        XCTAssertEqual(history.goBack(from: later), start)

        history.moveDocument(from: nil, to: saved)
        history.moveDocument(from: saved, to: renamed)

        XCTAssertEqual(history.forward.last, NavigationPoint(documentURL: renamed, utf16Location: 20))
        XCTAssertEqual(history.goForward(from: NavigationPoint(documentURL: renamed, utf16Location: 4))?.documentURL,
                       renamed)
        XCTAssertEqual(history.back.last, NavigationPoint(documentURL: renamed, utf16Location: 4))
    }

    func testBookmarkRelocatesByNearbyTextAndHeadingAfterEdits() {
        let body = String(repeating: "a", count: 35) + "目印🙂" + String(repeating: "b", count: 35)
        let original = "# 第一\n\(body)\n\n# 第二\n\(body)\n"
        let marker = (original as NSString).range(of: "目印🙂", options: .backwards).location
        let bookmark = DocumentBookmark.capture(in: original, at: marker,
            documentURL: URL(fileURLWithPath: "/tmp/note.md"))
        let updated = "前置き\n" + original
        let expected = (updated as NSString).range(of: "目印🙂", options: .backwards).location
        XCTAssertEqual(bookmark.resolvedLocation(in: updated), expected)
        let changed = NSMutableString(string: updated)
        changed.replaceCharacters(in: NSRange(location: expected,
            length: ("目印🙂" as NSString).length), with: "変更")
        let heading = changed.range(of: "# 第二").location
        XCTAssertEqual(bookmark.resolvedLocation(in: changed as String),
            heading + (bookmark.sectionOffset ?? 0))
    }
}
