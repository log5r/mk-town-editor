import UniformTypeIdentifiers
import XCTest
@testable import MKTownEditor

final class MarkdownDocumentTests: XCTestCase {
    func testApplicationDeclaresMarkdownImportedType() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Support/Info.plist"))
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(
            from: data, format: nil) as? [String: Any])
        let declarations = try XCTUnwrap(plist["UTImportedTypeDeclarations"] as? [[String: Any]])
        let markdown = try XCTUnwrap(declarations.first {
            $0["UTTypeIdentifier"] as? String == "net.daringfireball.markdown"
        })
        XCTAssertTrue((markdown["UTTypeConformsTo"] as? [String] ?? []).contains("public.plain-text"))
        let tags = try XCTUnwrap(markdown["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertTrue((tags["public.filename-extension"] as? [String] ?? []).contains("md"))
        XCTAssertTrue(MarkdownDocument.markdownType.conforms(to: .plainText))
        XCTAssertEqual(MarkdownDocument.writableContentTypes, [MarkdownDocument.markdownType])
    }

    func testReadProducesContiguousUTF8WithoutReplacingInvalidBytes() throws {
        let text = String(repeating: "日本語🙂e\u{301}\r\n", count: 100)
        let document = try MarkdownDocument(data: Data(text.utf8))
        XCTAssertTrue(document.text.isContiguousUTF8)
        XCTAssertEqual(document.encodedData(), Data(text.utf8))
        XCTAssertThrowsError(try MarkdownDocument(data: Data([0xC3, 0x28])))
    }

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

    func testLFCRLFAndCRArePreservedOnSave() throws {
        for newline in MarkdownTextFormat.Newline.allCases {
            let original = Data("a\(newline.sequence)b\(newline.sequence)".utf8)
            let document = try MarkdownDocument(data: original)
            XCTAssertEqual(document.text, "a\nb\n")
            XCTAssertEqual(document.format.newline, newline)
            XCTAssertEqual(document.encodedData(), original)
        }
    }

    func testUTF8BOMIsSeparatedFromEditableTextAndPreserved() throws {
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("# 見出し\r\n本文".utf8)
        var document = try MarkdownDocument(data: original)
        XCTAssertEqual(document.text, "# 見出し\n本文")
        XCTAssertTrue(document.format.hasUTF8BOM)
        XCTAssertEqual(document.encodedData(), original)
        document.text += "\n追記"
        XCTAssertEqual(document.encodedData(),
                       Data([0xEF, 0xBB, 0xBF]) + Data("# 見出し\r\n本文\r\n追記".utf8))
    }

    func testExplicitFormatConversionChangesOnlySerializedBytes() throws {
        var document = try MarkdownDocument(data: Data("A\r\nB".utf8))
        document.format.newline = .lf
        document.format.hasUTF8BOM = true
        XCTAssertEqual(document.text, "A\nB")
        XCTAssertEqual(document.encodedData(), Data([0xEF, 0xBB, 0xBF]) + Data("A\nB".utf8))
    }

    func testMixedNewlinesChooseMostFrequentFormat() throws {
        var document = try MarkdownDocument(data: Data("A\r\nB\r\nC\nD".utf8))
        XCTAssertEqual(document.text, "A\nB\nC\nD")
        XCTAssertEqual(document.format.newline, .crlf)
        XCTAssertEqual(document.encodedData(), Data("A\r\nB\r\nC\nD".utf8))
        document.text += "\nE"
        XCTAssertEqual(document.encodedData(), Data("A\r\nB\r\nC\r\nD\r\nE".utf8))
    }

    func testSinglePassNewlineScanMatchesReferenceForEveryCombination() throws {
        let pieces = ["a", "日本", "🙂", "e\u{301}", "\r\n", "\r", "\n", ""]
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<400 {
            let text = (0..<Int.random(in: 0...12, using: &generator))
                .map { _ in pieces.randomElement(using: &generator)! }.joined()
            for bom in [false, true] {
                let data = (bom ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(text.utf8)
                let (value, format) = try MarkdownTextFormat.read(data)
                let expected = text.replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n")
                XCTAssertEqual(value, expected)
                XCTAssertTrue(value.isContiguousUTF8)
                XCTAssertEqual(format.newline, Self.referenceNewline(text), text.debugDescription)
                XCTAssertEqual(format.encode(value), data, text.debugDescription)
                var changed = format
                changed.newline = .crlf
                XCTAssertEqual(changed.encode(value),
                               (bom ? Data([0xEF, 0xBB, 0xBF]) : Data())
                                + Data(expected.replacingOccurrences(of: "\n", with: "\r\n").utf8))
            }
        }
    }

    func testMixedNewlineOrderIsDroppedWhenLineCountChanges() throws {
        let (value, format) = try MarkdownTextFormat.read(Data("A\rB\nC".utf8))
        XCTAssertEqual(format.encode(value), Data("A\rB\nC".utf8))
        XCTAssertEqual(format.encode(value + "\nD"), Data("A\rB\rC\rD".utf8))
        XCTAssertEqual(format.encode("A\r\nB\rC"), Data("A\rB\nC".utf8))
    }

    private static func referenceNewline(_ value: String) -> MarkdownTextFormat.Newline {
        // Characterで数えると、CRLFを除いた後に隣接したCRとLFが1つの書記素になるため、スカラーで数える。
        let crlfCount = value.components(separatedBy: "\r\n").count - 1
        let withoutCRLF = value.replacingOccurrences(of: "\r\n", with: "").unicodeScalars
        let crCount = withoutCRLF.filter { $0 == "\r" }.count
        let lfCount = withoutCRLF.filter { $0 == "\n" }.count
        if crlfCount > 0 && crlfCount >= crCount && crlfCount >= lfCount { return .crlf }
        if crCount > 0 && crCount >= lfCount { return .cr }
        return .lf
    }
}
