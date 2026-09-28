import Foundation
import XCTest
@testable import MKTownEditor

final class MarkdownEncodingConverterTests: XCTestCase {
    func testShiftJISCanBePreviewedAndConvertedToUTF8() throws {
        let original = "# 見出し\r\n\r\n本文です。"
        let legacy = try MarkdownEncodingConverter.encode(original, as: .shiftJIS)
        XCTAssertEqual(try MarkdownEncodingConverter.decode(legacy, as: .shiftJIS), original)
        XCTAssertThrowsError(try MarkdownEncodingConverter.decode(legacy, as: .utf8))
        let converted = try MarkdownEncodingConverter.convert(legacy, from: .shiftJIS, to: .utf8)
        XCTAssertEqual(String(data: converted, encoding: .utf8), original)
    }

    func testUnrepresentableCharactersCannotBeSavedSilently() throws {
        XCTAssertThrowsError(try MarkdownEncodingConverter.encode("絵文字🙂", as: .shiftJIS))
        XCTAssertThrowsError(try MarkdownEncodingConverter.encode("日本語", as: .latin1))
        XCTAssertEqual(try MarkdownEncodingConverter.encode("café", as: .latin1),
                       Data([0x63, 0x61, 0x66, 0xE9]))
    }

    func testUTF16EndiannessNeedsExplicitSelection() throws {
        let data = try MarkdownEncodingConverter.encode("A日本語", as: .utf16LE)
        XCTAssertEqual(try MarkdownEncodingConverter.decode(data, as: .utf16LE), "A日本語")
        XCTAssertEqual(try MarkdownEncodingConverter.convert(data, from: .utf16LE, to: .utf8),
                       Data("A日本語".utf8))
    }
}
