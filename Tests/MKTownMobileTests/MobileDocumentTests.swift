import XCTest
import UniformTypeIdentifiers
@testable import MKTownEditorMobile

final class MobileDocumentTests: XCTestCase {
    func testUTF8BOMAndMixedNewlinesSurviveMobileSave() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("# 日本語🙂\r\nA\nB\r".utf8)
        let document = try MarkdownDocument(data: data)
        XCTAssertEqual(document.text, "# 日本語🙂\nA\nB\n")
        XCTAssertEqual(document.encodedData(), data)
    }

    func testEditedDocumentCanBeReopenedWithoutLosingUnicode() throws {
        var document = try MarkdownDocument(data: Data("First\r\n".utf8))
        document.text += "日本語🙂e\u{301}\n"
        XCTAssertEqual(try MarkdownDocument(data: document.encodedData()).text, document.text)
        XCTAssertEqual(String(data: document.encodedData(), encoding: .utf8), "First\r\n日本語🙂e\u{301}\r\n")
    }

    func testInvalidEncodingIsRejectedRatherThanOverwritten() {
        XCTAssertThrowsError(try MarkdownDocument(data: Data([0xFF, 0xFE])))
    }

    func testDocumentBrowserConfiguration() throws {
        let bundle = Bundle.main
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "LSSupportsOpeningDocumentsInPlace") as? Bool, true)
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "UISupportsDocumentBrowser") as? Bool, true)
        XCTAssertNil(bundle.object(forInfoDictionaryKey: "UIRequiresFullScreen"))
        XCTAssertTrue(MarkdownDocument.markdownType.conforms(to: .plainText))
    }
}
