import XCTest
@testable import MKTownEditor

final class EditorToolbarInstanceIDTests: XCTestCase {
    func testSimultaneousDocumentToolbarsHaveSeparateCustomizationFamilies() {
        let first = EditorToolbarInstanceID(documentURL: nil,
            uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let second = EditorToolbarInstanceID(documentURL: nil,
            uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.rawValue, "mktown-editor-00000000-0000-0000-0000-000000000001")

        let document = URL(fileURLWithPath: "/private/tmp/toolbar-document.md")
        let other = URL(fileURLWithPath: "/private/tmp/other-document.md")
        XCTAssertEqual(EditorToolbarInstanceID(documentURL: document),
                       EditorToolbarInstanceID(documentURL: document))
        XCTAssertNotEqual(EditorToolbarInstanceID(documentURL: document),
                          EditorToolbarInstanceID(documentURL: other))
    }
}
