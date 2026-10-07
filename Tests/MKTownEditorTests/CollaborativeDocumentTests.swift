import Foundation
import XCTest
@testable import MKTownEditor

final class CollaborativeDocumentTests: XCTestCase {
    @MainActor
    func testPeerNameRespectsMultipeerUTF8Limit() {
        let value = CollaborationSession.peerDisplayName(String(repeating: "あ", count: 50))
        XCTAssertLessThanOrEqual(value.utf8.count, 63)
        XCTAssertFalse(value.isEmpty)
    }

    func testConcurrentInsertionsConvergeAcrossDeliveryOrder() {
        let room = UUID()
        let host = CollaborativeDocument(text: "ab", roomID: room, siteID: "host")
        var a = CollaborativeDocument(text: "", roomID: room, siteID: "alice")
        var b = CollaborativeDocument(text: "", roomID: room, siteID: "bob")
        a.merge(host)
        b.merge(host)
        let left = a.edit(to: "aXb")
        let right = b.edit(to: "aYb")
        a.apply(right)
        b.apply(left)
        XCTAssertEqual(a.text, b.text)
        XCTAssertTrue(a.text.contains("X"))
        XCTAssertTrue(a.text.contains("Y"))
        XCTAssertTrue(a.text.hasPrefix("a"))
        XCTAssertTrue(a.text.hasSuffix("b"))
    }

    func testOfflineMergeKeepsIndependentEditsAndDeletes() {
        let room = UUID()
        var host = CollaborativeDocument(text: "cat", roomID: room, siteID: "host")
        var guest = CollaborativeDocument(text: "", roomID: room, siteID: "guest")
        guest.merge(host)
        _ = host.edit(to: "cats")
        _ = guest.edit(to: "bat")
        host.merge(guest)
        guest.merge(host)
        XCTAssertEqual(host.text, guest.text)
        XCTAssertTrue(host.text.contains("b"))
        XCTAssertTrue(host.text.contains("s"))
        XCTAssertFalse(host.text.contains("c"))
    }

    func testDeleteBeforeInsertAndCommentRepliesConverge() throws {
        let room = UUID()
        var host = CollaborativeDocument(text: "hi", roomID: room, siteID: "host")
        var guest = CollaborativeDocument(text: "", roomID: room, siteID: "guest")
        guest.merge(host)
        let insert = guest.edit(to: "hi!")
        let inserted = try XCTUnwrap(insert.inserts.first)
        host.apply(.init(deletes: [inserted.id]))
        host.apply(insert)
        XCTAssertEqual(host.text, "hi")
        let added = try XCTUnwrap(host.addComment(author: "A", text: "Check", range: 0..<2))
        guest.apply(added)
        let id = try XCTUnwrap(host.comments.first?.id)
        let reply = try XCTUnwrap(guest.reply(to: id, author: "B", text: "OK"))
        let resolved = try XCTUnwrap(host.resolveComment(id))
        host.apply(reply)
        guest.apply(resolved)
        XCTAssertEqual(host.comments, guest.comments)
        XCTAssertEqual(host.comments.first?.replies.count, 1)
        XCTAssertEqual(host.comments.first?.resolved, true)
    }

    func testUnicodeRangeAndSerialization() throws {
        let room = UUID()
        var document = CollaborativeDocument(text: "A👨‍👩‍👧B", roomID: room, siteID: "one")
        XCTAssertEqual(document.characterRange(for: NSRange(location: 1, length: 8)), 1..<2)
        XCTAssertNil(document.characterRange(for: NSRange(location: 2, length: 1)))
        _ = document.addComment(author: "A", text: "Emoji", range: 1..<2)
        let restored = try JSONDecoder().decode(CollaborativeDocument.self,
                                                from: JSONEncoder().encode(document))
        XCTAssertEqual(restored.text, document.text)
        XCTAssertEqual(restored.comments, document.comments)
    }

    func testSequentialLocalEditsAlwaysMatchRequestedText() {
        var document = CollaborativeDocument(text: "abc", siteID: "writer")
        var expected = "abc"
        for index in 0..<80 {
            let position = index % (expected.count + 1)
            var characters = Array(expected)
            if index % 3 == 0, !characters.isEmpty {
                characters.remove(at: min(position, characters.count - 1))
            } else {
                characters.insert(index % 2 == 0 ? "🌟" : "あ", at: position)
            }
            expected = String(characters)
            _ = document.edit(to: expected)
            XCTAssertEqual(document.text, expected, "operation \(index)")
        }
    }

    func testCachedOrderMatchesFullTraversalThroughLocalAndRemoteEdits() throws {
        let room = UUID()
        var host = CollaborativeDocument(text: "base 文書🙂", roomID: room, siteID: "host")
        var guest = CollaborativeDocument(text: "", roomID: room, siteID: "guest")
        guest.merge(host)
        var generator = SystemRandomNumberGenerator()
        let pieces = ["a", "あ", "🙂", "e\u{301}", "\n", ""]
        for step in 0..<300 {
            func mutate(_ text: String) -> String {
                var characters = Array(text)
                let location = Int.random(in: 0...characters.count, using: &generator)
                let length = Int.random(in: 0...min(3, characters.count - location), using: &generator)
                characters.replaceSubrange(location..<(location + length),
                                           with: Array(pieces.randomElement(using: &generator)!))
                return String(characters)
            }
            let fromHost = host.edit(to: mutate(host.text))
            let fromGuest = guest.edit(to: mutate(guest.text))
            for document in [host, guest] {
                XCTAssertEqual(document.visibleAtoms, document.orderedVisibleAtoms(), "step \(step)")
                XCTAssertEqual(document.text, document.orderedVisibleAtoms().map(\.character).joined())
            }
            if step.isMultiple(of: 3) {
                host.apply(fromGuest)
                guest.apply(fromHost)
            } else {
                host.merge(guest)
                guest.merge(host)
            }
            XCTAssertEqual(host.visibleAtoms, host.orderedVisibleAtoms())
            XCTAssertEqual(guest.visibleAtoms, guest.orderedVisibleAtoms())
            XCTAssertEqual(host.text, guest.text, "step \(step)")
        }
        let restored = try JSONDecoder().decode(CollaborativeDocument.self, from: JSONEncoder().encode(host))
        XCTAssertEqual(restored, host)
        XCTAssertEqual(restored.text, host.text)
        var edited = restored
        _ = edited.edit(to: restored.text + "!")
        XCTAssertEqual(edited.text, host.text + "!")
    }

    func testTypingInLargeDocumentDoesNotTraverseWholeTreePerKeystroke() {
        var document = CollaborativeDocument(text: String(repeating: "本文の段落です。\n", count: 2_000),
                                             siteID: "local")
        var text = document.text
        let start = Date()
        for index in 0..<500 {
            let insertion = text.index(text.startIndex, offsetBy: 9_000 + index)
            text.insert("字", at: insertion)
            let delta = document.edit(to: text)
            XCTAssertEqual(delta.inserts.count, 1)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(document.text, text)
        XCTAssertEqual(document.visibleAtoms, document.orderedVisibleAtoms())
        XCTAssertTrue(document.edit(to: text).isEmpty)
    }
}
