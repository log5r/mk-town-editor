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

    func testShiftJISWithIBMExtensionsIsReadAlthoughItEncodesBackDifferently() throws {
        // ⅰ (IBM FA 40), 髙 (IBM FB FC), ① (NEC 87 40) as written by Windows.
        let data = Data([0xFA, 0x40, 0xFB, 0xFC, 0x87, 0x40, 0x0D, 0x0A])
        XCTAssertEqual(try MarkdownEncodingConverter.decode(data, as: .shiftJIS), "ⅰ髙①\r\n")
        XCTAssertEqual(try MarkdownEncodingConverter.convert(data, from: .shiftJIS, to: .utf8),
                       Data("ⅰ髙①\r\n".utf8))
        XCTAssertThrowsError(try MarkdownEncodingConverter.decode(Data([0x41, 0x81]), as: .shiftJIS))
        XCTAssertThrowsError(try MarkdownEncodingConverter.decode(Data([0xFF]), as: .shiftJIS))
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

    func testAutoDetectsJapaneseFilesIncludingBothCP932ExtensionRanges() throws {
        let sample = "# 日本語の原稿\r\n本文です。\r\n"
        for encoding in [MarkdownTextEncoding.utf8, .shiftJIS, .eucJP, .iso2022JP, .utf16LE, .utf16BE] {
            let data = try MarkdownEncodingConverter.encode(sample, as: encoding)
            let result = try MarkdownEncodingConverter.detect(data)
            XCTAssertEqual(result.text, sample, encoding.title)
            XCTAssertEqual(result.encoding, encoding)
            XCTAssertFalse(result.hasBOM)
        }
        let extensions = Data([0xFA, 0x40, 0xFB, 0xFC, 0x87, 0x40])
        let result = try MarkdownEncodingConverter.detect(extensions)
        XCTAssertEqual(result.encoding, .shiftJIS)
        XCTAssertEqual(result.text, "ⅰ髙①")
    }

    func testByteOrderMarkWinsOverDeclarationAndCandidateList() throws {
        let text = "# coding: cp932\r\n本文"
        for encoding in [MarkdownTextEncoding.utf8, .utf16LE, .utf16BE] {
            let data = try MarkdownEncodingConverter.encode(text, as: encoding, hasBOM: true)
            let result = try MarkdownEncodingConverter.detect(data, candidates: [.eucJP])
            XCTAssertEqual(result.text, text)
            XCTAssertEqual(result.encoding, encoding)
            XCTAssertTrue(result.hasBOM)
            XCTAssertEqual(try MarkdownEncodingConverter.encode(result.text, as: result.encoding, hasBOM: result.hasBOM), data)
        }
        let twoMarks = Data([0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF])
        XCTAssertEqual(try MarkdownEncodingConverter.detect(twoMarks).text, "\u{FEFF}")
    }

    func testDeclarationResolvesAmbiguousContentAndTakesPrecedenceOverCandidateOrder() throws {
        for header in ["# -*- coding: windows-31j -*-", "<meta charset=\"CP932\">",
                       "<!doctype html>\n<html>\n<head>\n<meta charset=\"Windows-31J\">",
                       "<?xml version='1.0' encoding='Shift_JIS'?>"] {
            let data = Data((header + "\n").utf8) + Data([0xA4, 0xA2])
            let result = try MarkdownEncodingConverter.detect(data, candidates: [.eucJP])
            XCTAssertEqual(result.encoding, .shiftJIS)
            XCTAssertEqual(result.text, header + "\n､｢")
        }
        let quoted = "この例では charset=Shift_JIS と書きます。\n\n# coding: euc-jp"
        for example in [quoted, "# HTML の charset=Shift_JIS を調べる\n日本語の本文",
                        "# HTML で <meta charset=Shift_JIS> と書く例"] {
            XCTAssertEqual(try MarkdownEncodingConverter.detect(Data(example.utf8)).text, example)
        }
    }

    func testAmbiguousShortInputRequiresChoiceAndLongerInputHonorsPriority() throws {
        // A4 A2 is あ in EUC-JP, or two half-width punctuation characters in CP932.
        let short = Data([0xA4, 0xA2])
        XCTAssertThrowsError(try MarkdownEncodingConverter.detect(short))
        XCTAssertThrowsError(try MarkdownEncodingConverter.detect(Data([0xC3, 0x28])))
        XCTAssertEqual(try MarkdownEncodingConverter.read(short, as: .eucJP).text, "あ")
        XCTAssertEqual(try MarkdownEncodingConverter.read(short, as: .shiftJIS).text, "､｢")
        XCTAssertEqual(try MarkdownEncodingConverter.detect(Data("ASCII".utf8), candidates: [.iso2022JP]).encoding,
                       .iso2022JP)
        let data = short + short
        XCTAssertEqual(try MarkdownEncodingConverter.detect(data, candidates: [.shiftJIS, .eucJP]).text, "､｢､｢")
        XCTAssertEqual(try MarkdownEncodingConverter.detect(data, candidates: [.eucJP, .shiftJIS]).text, "ああ")
        XCTAssertThrowsError(try MarkdownEncodingConverter.detect(data, candidates: [.utf8]))
    }

    func testConversionKeepsDeclarationsReadableAndPreservesIdenticalEncodingBytes() throws {
        let text = "# coding: cp932\n本文"
        let input = try MarkdownEncodingConverter.encode(text, as: .shiftJIS)
        for target in [MarkdownTextEncoding.utf8, .utf16LE, .utf16BE] {
            let output = try MarkdownEncodingConverter.convert(input, from: .shiftJIS, to: target)
            let reopened = try MarkdownEncodingConverter.detect(output)
            XCTAssertEqual(reopened.text, text)
            XCTAssertEqual(reopened.encoding, target)
            XCTAssertTrue(reopened.hasBOM)
            XCTAssertEqual(try MarkdownEncodingConverter.convert(output, from: target, to: target), output)
        }
        let ibmBytes = Data([0xFA, 0x40, 0xFB, 0xFC])
        XCTAssertEqual(try MarkdownEncodingConverter.convert(ibmBytes, from: .shiftJIS, to: .shiftJIS), ibmBytes)
    }

    func testLegacyConversionUpdatesOnlyDeclaredLabelAndReopensWithDestinationEncoding() throws {
        let text = "# 日本語\r\n# -*- CoDiNg : 'cp932' -*-\r\nああ cp932\r\n"
        let original = try MarkdownEncodingConverter.encode(text, as: .shiftJIS)
        let output = try MarkdownEncodingConverter.convert(original, from: .shiftJIS, to: .eucJP)
        let reopened = try MarkdownEncodingConverter.detect(output, candidates: [.shiftJIS])
        XCTAssertEqual(reopened.encoding, .eucJP)
        XCTAssertEqual(reopened.text, "# 日本語\r\n# -*- CoDiNg : 'EUC-JP' -*-\r\nああ cp932\r\n")

        let markup = "<html>\r\n<meta name='説明' charset = \"euc-jp\">\r\nああ euc-jp"
        let utf8 = try MarkdownEncodingConverter.encode(markup, as: .utf8, hasBOM: true)
        let cp932 = try MarkdownEncodingConverter.convert(utf8, from: .utf8, to: .shiftJIS)
        let imported = try MarkdownEncodingConverter.detect(cp932)
        XCTAssertEqual(imported.encoding, .shiftJIS)
        XCTAssertEqual(imported.text, "<html>\r\n<meta name='説明' charset = \"Windows-31J\">\r\nああ euc-jp")
    }

    func testSameLegacyEncodingRepairsUnknownDeclarationWithoutReencodingBody() throws {
        let body = Data([0xFA, 0x40, 0xFB, 0xFC]) // IBM code points with alternative CP932 spellings.
        let original = Data("# coding: UNKNOWN\r\n".utf8) + body
        let output = try MarkdownEncodingConverter.convert(original, from: .shiftJIS, to: .shiftJIS)
        XCTAssertEqual(output, Data("# coding: Windows-31J\r\n".utf8) + body)
        XCTAssertEqual(try MarkdownEncodingConverter.detect(output).text, "# coding: Windows-31J\r\nⅰ髙")

        let longHeader = "# coding:" + String(repeating: " ", count: 4084)
        let splitLabel = Data((longHeader + "unknown-name\n").utf8) + body
        XCTAssertEqual(try MarkdownEncodingConverter.convert(splitLabel, from: .shiftJIS, to: .shiftJIS),
                       Data((longHeader + "Windows-31J\n").utf8) + body)

        let matching = Data("# coding: sJiS\r\n".utf8) + body
        XCTAssertEqual(try MarkdownEncodingConverter.convert(matching, from: .shiftJIS, to: .shiftJIS), matching)
        let staleUTF8 = Data("# coding: cp932\nああ".utf8)
        let marked = try MarkdownEncodingConverter.convert(staleUTF8, from: .utf8, to: .utf8)
        XCTAssertEqual(try MarkdownEncodingConverter.detect(marked).encoding, .utf8)
    }

    func testTruncatedBOMPayloadAndUnsupportedUTF32AreRejected() {
        for bytes: [UInt8] in [[0xFF, 0xFE, 0x41], [0xFE, 0xFF, 0xD8, 0x00],
                               [0xEF, 0xBB, 0xBF, 0xFF], [0xFF, 0xFE, 0x00, 0x00]] {
            XCTAssertThrowsError(try MarkdownEncodingConverter.detect(Data(bytes)))
        }
    }

    func testShortNULContainingFilesRequireExplicitByteOrder() throws {
        for encoding in [MarkdownTextEncoding.utf16LE, .utf16BE] {
            let data = try MarkdownEncodingConverter.encode("A", as: encoding)
            XCTAssertThrowsError(try MarkdownEncodingConverter.detect(data))
            XCTAssertEqual(try MarkdownEncodingConverter.read(data, as: encoding).text, "A")
            let text = "\u{FEFF}本文"
            let marked = try MarkdownEncodingConverter.encode(text, as: encoding, hasBOM: true)
            XCTAssertEqual(try MarkdownEncodingConverter.detect(marked).text, text)
        }
        XCTAssertThrowsError(try MarkdownEncodingConverter.read(Data([0x41, 0, 0x42]), as: .utf16LE))
        XCTAssertThrowsError(try MarkdownEncodingConverter.read(Data([0, 0xD8]), as: .utf16LE))
    }

    func testISO2022JPRejectsTruncatedShiftAndIllegallyUnshiftedHighBytes() throws {
        for suffix: [UInt8] in [[0x1B], [0x1B, 0x24], [0xE9], [0x1B, 0x24, 0x42, 0x24]] {
            let data = try MarkdownEncodingConverter.encode("見出し", as: .iso2022JP) + Data(suffix)
            XCTAssertThrowsError(try MarkdownEncodingConverter.detect(data))
            XCTAssertThrowsError(try MarkdownEncodingConverter.read(data, as: .iso2022JP))
        }
    }

    func testLossLocationsUseUTF16RangesAndPreserveExactUnicodeScalars() throws {
        let text = "髙\n🙂①e\u{0301}"
        let ranges = MarkdownEncodingConverter.unrepresentableRanges(in: text, as: .shiftJIS)
        XCTAssertEqual(ranges, [NSRange(location: 2, length: 2), NSRange(location: 5, length: 2)])
        XCTAssertEqual(ranges.map { (text as NSString).substring(with: $0) }, ["🙂", "e\u{0301}"])
        // Foundation may compose the combining mark in a supposedly lossless Latin-1 conversion.
        XCTAssertThrowsError(try MarkdownEncodingConverter.encode("e\u{0301}", as: .latin1))
        XCTAssertEqual(try MarkdownEncodingConverter.encode("é", as: .latin1), Data([0xE9]))
        XCTAssertTrue(MarkdownEncodingConverter.unrepresentableRanges(in: text, as: .utf16LE).isEmpty)
    }
}
