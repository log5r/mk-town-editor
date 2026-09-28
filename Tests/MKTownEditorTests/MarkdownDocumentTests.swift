import UniformTypeIdentifiers
import XCTest
@testable import MKTownEditor

final class MarkdownDocumentTests: XCTestCase {
    func testUTF8RoundTrip() throws {
        let original = MarkdownDocument(text: "# 見出し\n\n本文")
        let restored = try MarkdownDocument.decode(original.encodedData())

        XCTAssertEqual(restored, original.text)
    }

    func testInvalidUTF8IsRejected() {
        XCTAssertThrowsError(
            try MarkdownDocument.decode(Data([0xFF, 0xFE]))
        )
    }
}
