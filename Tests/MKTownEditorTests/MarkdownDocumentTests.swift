import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import MKTownEditor

final class MarkdownDocumentTests: XCTestCase {
    #if !SWIFT_PACKAGE
    @MainActor
    func testDocumentControllerOpensLegacyFileAndProtectsUnresolvedFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (name, bytes, requiresChoice) in [
            ("legacy.md", Data("# coding: cp932\r\n".utf8) + Data([0xFA, 0x40, 0xFB, 0xFC]), false),
            ("undecidable.md", Data([0xFF, 0xFE, 0x41]), true)
        ] {
            let url = folder.appendingPathComponent(name)
            try bytes.write(to: url)
            let (document, _) = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: false)
            defer { document.close() }
            let type = try XCTUnwrap(document.fileType)
            let destination = folder.appendingPathComponent("copy-" + name)
            if requiresChoice {
                XCTAssertThrowsError(try document.write(to: destination, ofType: type))
            } else {
                try document.write(to: destination, ofType: type)
                XCTAssertEqual(try Data(contentsOf: destination), bytes)
            }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }
    #endif

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
        XCTAssertEqual(try document.encodedData(), Data(text.utf8))
        XCTAssertThrowsError(try MarkdownDocument(data: Data([0xC3, 0x28])))
    }

    func testUTF8RoundTrip() throws {
        let original = MarkdownDocument(text: "# 見出し\n\n本文")
        let restored = try MarkdownDocument.decode(original.encodedData())

        XCTAssertEqual(restored, original.text)
    }

    func testSaveWhitespacePolicyPreservesEncodingAndLineEndingsWithoutChangingTheBuffer() throws {
        let original = "行末 \t\r\n強制  \n次の行\n\n```\r空白 \t\r```\r末尾 \t"
        let encoding = MarkdownTextEncoding.shiftJIS
        let bytes = try MarkdownEncodingConverter.encode(original, as: encoding)
        let document = try MarkdownDocument(data: bytes, encoding: encoding)
        let anotherDocument = try MarkdownDocument(data: bytes, encoding: encoding)
        XCTAssertEqual(try document.dataForSave(), bytes)

        document.saveWhitespaceConfiguration.update(.init(includingWhitespaceOnlyLines: false, dialect: .extended))
        let expected = "行末\r\n強制  \n次の行\n\n```\r空白 \t\r```\r末尾"
        XCTAssertEqual(try document.dataForSave(), try MarkdownEncodingConverter.encode(expected, as: encoding))
        XCTAssertEqual(try document.encodedData(), bytes)
        XCTAssertEqual(try anotherDocument.dataForSave(), bytes)

        document.saveWhitespaceConfiguration.update(nil)
        XCTAssertEqual(try document.dataForSave(), bytes)
    }

    func testTruncatedUTF16IsRejected() {
        XCTAssertThrowsError(
            try MarkdownDocument.decode(Data([0xFF, 0xFE, 0x41]))
        )
    }

    func testInteractiveOpenKeepsUndecidableBytesUntilEncodingIsChosen() throws {
        let data = Data([0xE9]) // A complete Latin-1 character but incomplete UTF-8.
        let unresolved = try MarkdownDocument(opening: data, candidates: MarkdownTextEncoding.defaultDetectionOrder)
        XCTAssertEqual(unresolved.pendingEncodingData, data)
        XCTAssertThrowsError(try unresolved.encodedData())
        XCTAssertThrowsError(try MarkdownDocument.decode(data, candidates: [.utf8, .shiftJIS]))

        let resolved = try MarkdownDocument(data: data, encoding: .latin1)
        XCTAssertNil(resolved.pendingEncodingData)
        XCTAssertEqual(resolved.text, "é")
        XCTAssertEqual(try resolved.encodedData(), data)
    }

    func testUTF16KeepsBOMByteOrderMixedNewlinesAndLiteralBOMInText() throws {
        for encoding in [MarkdownTextEncoding.utf16LE, .utf16BE] {
            let bom = Data(encoding == .utf16LE ? [0xFF, 0xFE] : [0xFE, 0xFF])
            let original = "\u{FEFF}日本\r\n二行目\n"
            let data = try XCTUnwrap(original.data(using: encoding.foundationEncoding))
            var document = try MarkdownDocument(opening: bom + data)
            XCTAssertNil(document.pendingEncodingData)
            XCTAssertEqual(document.encoding, encoding)
            XCTAssertEqual(document.text, "\u{FEFF}日本\n二行目\n")
            XCTAssertEqual(try document.encodedData(), bom + data)
            document.text += "末尾"
            XCTAssertEqual(try document.encodedData(), try bom + XCTUnwrap(
                (original + "末尾").data(using: encoding.foundationEncoding)))
        }
    }

    func testUntouchedCP932FileRetainsIBMAndNECByteSequences() throws {
        // Both byte pairs decode to U+9AD9 (髙).
        let data = Data([0xFB, 0xFC, 0xEE, 0xE0])
        let document = try MarkdownDocument(data: data, encoding: .shiftJIS)
        XCTAssertEqual(document.text, "髙髙")
        XCTAssertEqual(try document.encodedData(), data)
    }

    func testUnrepresentableEditRequiresExplicitRecovery() throws {
        let original = "# coding: Shift_JIS\r\n日本"
        let data = try MarkdownEncodingConverter.encode(original, as: .shiftJIS)
        var document = try MarkdownDocument(opening: data)
        XCTAssertEqual(document.encoding, .shiftJIS)
        document.text += "🙂"
        XCTAssertThrowsError(try document.encodedData()) {
            XCTAssertTrue($0 is MarkdownDocument.UnrepresentableTextError)
        }
        var replacement = document
        try replacement.replaceUnrepresentableCharacters()
        XCTAssertEqual(replacement.encoding, .shiftJIS)
        XCTAssertEqual(try MarkdownEncodingConverter.decode(replacement.encodedData(), as: .shiftJIS),
                       original + "?")
        document.convertToUTF8()
        let reopened = try MarkdownDocument(data: document.encodedData())
        XCTAssertEqual(reopened.encoding, .utf8)
        XCTAssertEqual(reopened.text, original.replacingOccurrences(of: "\r\n", with: "\n") + "🙂")
    }

    func testLFCRLFAndCRArePreservedOnSave() throws {
        for newline in MarkdownTextFormat.Newline.allCases {
            let original = Data("a\(newline.sequence)b\(newline.sequence)".utf8)
            let document = try MarkdownDocument(data: original)
            XCTAssertEqual(document.text, "a\nb\n")
            XCTAssertEqual(document.format.newline, newline)
            XCTAssertEqual(try document.encodedData(), original)
        }
    }

    func testUTF8BOMIsSeparatedFromEditableTextAndPreserved() throws {
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("# 見出し\r\n本文".utf8)
        var document = try MarkdownDocument(data: original)
        XCTAssertEqual(document.text, "# 見出し\n本文")
        XCTAssertTrue(document.format.hasUTF8BOM)
        XCTAssertEqual(try document.encodedData(), original)
        document.text += "\n追記"
        XCTAssertEqual(try document.encodedData(),
                       Data([0xEF, 0xBB, 0xBF]) + Data("# 見出し\r\n本文\r\n追記".utf8))
    }

    func testExplicitFormatConversionChangesOnlySerializedBytes() throws {
        var document = try MarkdownDocument(data: Data("A\r\nB".utf8))
        document.format.newline = .lf
        document.format.hasUTF8BOM = true
        XCTAssertEqual(document.text, "A\nB")
        XCTAssertEqual(try document.encodedData(), Data([0xEF, 0xBB, 0xBF]) + Data("A\nB".utf8))
    }

    func testMixedNewlinesChooseMostFrequentFormat() throws {
        var document = try MarkdownDocument(data: Data("A\r\nB\r\nC\nD".utf8))
        XCTAssertEqual(document.text, "A\nB\nC\nD")
        XCTAssertEqual(document.format.newline, .crlf)
        XCTAssertEqual(try document.encodedData(), Data("A\r\nB\r\nC\nD".utf8))
        document.text += "\nE"
        XCTAssertEqual(try document.encodedData(), Data("A\r\nB\r\nC\nD\r\nE".utf8))
    }

    func testMixedWarningsUseEditorOffsetsAndNormalizationPreservesBOMAndText() throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let data = bom + Data("A🙂\r\ne\u{301}\r終\nD\r\n".utf8)
        var document = try MarkdownDocument(data: data)
        let originalText = document.text
        let warnings = document.format.newlineWarnings(in: document.text)
        XCTAssertTrue(document.format.hasMixedNewlines)
        XCTAssertEqual(warnings.map(\.line), [2, 3])
        XCTAssertEqual(warnings.map(\.range), [NSRange(location: 6, length: 1), NSRange(location: 8, length: 1)])
        XCTAssertEqual(warnings.map(\.newline), [.cr, .lf])
        XCTAssertEqual(try document.encodedData(), data)

        document.format.normalizeNewlines()
        XCTAssertFalse(document.format.hasMixedNewlines)
        XCTAssertTrue(document.format.newlineWarnings(in: document.text).isEmpty)
        XCTAssertEqual(document.text, originalText)
        XCTAssertEqual(try document.encodedData(), bom + Data("A🙂\r\ne\u{301}\r\n終\r\nD\r\n".utf8))
    }

    func testExplicitPasteCanKeepDifferentEndingsWithIdenticalEditorText() throws {
        var document = try MarkdownDocument(data: Data("A\r\nB\r\nC".utf8))
        let range = NSRange(location: 1, length: 3)
        XCTAssertTrue(document.acceptEditorText("A\nB\nC", replacing: range, with: "\nB\r", preservingNewlines: true))
        XCTAssertEqual(document.text, "A\nB\nC")
        XCTAssertEqual(try document.encodedData(), Data("A\nB\rC".utf8))
        XCTAssertEqual(document.format.newlineWarnings(in: document.text).map(\.newline), [.lf, .cr])
        XCTAssertTrue(document.format.matchesNewlineCount(in: document.text))
        XCTAssertFalse(document.format.matchesNewlineCount(in: "A\nBC"))
        XCTAssertTrue(document.acceptEditorText("A\nB\nC", replacing: range, with: "\r\nB\r\n", preservingNewlines: true))
        XCTAssertFalse(document.format.hasMixedNewlines)
        XCTAssertTrue(document.acceptEditorText("A\nB\nC", replacing: range, with: "\nB\r", preservingNewlines: false))
        XCTAssertEqual(try document.encodedData(), Data("A\r\nB\r\nC".utf8))
    }

    func testDeletingAndInsertingNextToIdenticalBlankLinesRetainsTheIntendedEndings() throws {
        var document = try MarkdownDocument(data: Data("A\r\n\n\rB".utf8))
        XCTAssertTrue(document.acceptEditorText("A\n\nB", replacing: NSRange(location: 1, length: 1),
                                                with: "", preservingNewlines: false))
        XCTAssertEqual(try document.encodedData(), Data("A\n\rB".utf8))
        XCTAssertTrue(document.acceptEditorText("A\n\n\nB", replacing: NSRange(location: 2, length: 0),
                                                with: "\n", preservingNewlines: false))
        XCTAssertEqual(try document.encodedData(), Data("A\n\r\n\rB".utf8))
        XCTAssertEqual(document.format.newlineWarnings(in: document.text).map(\.line), [1, 3])
    }

    func testEditingRequiresMatchingBufferAndAllowsACombiningMarkSelection() throws {
        let bytes = Data("e\u{301}🙂\r\nx\ny".utf8)
        var document = try MarkdownDocument(data: bytes)
        XCTAssertFalse(document.acceptEditorText("other", replacing: NSRange(location: 1, length: 1),
                                                 with: "", preservingNewlines: false))
        XCTAssertFalse(document.acceptEditorText("", replacing: NSRange(location: 3, length: 0),
                                                 with: "", preservingNewlines: false))
        XCTAssertEqual(try document.encodedData(), bytes)
        XCTAssertTrue(document.acceptEditorText("e🙂\nx\ny", replacing: NSRange(location: 1, length: 1),
                                                with: "", preservingNewlines: false))
        XCTAssertEqual(try document.encodedData(), Data("e🙂\r\nx\ny".utf8))
    }

    func testWholeBufferEditsRetainUntouchedMixedEndingsAndWarnings() throws {
        var document = try MarkdownDocument(data: Data("A\rB\nC\rD".utf8))
        document.text = "A\nnew\nB\nC\nD"
        XCTAssertEqual(try document.encodedData(), Data("A\rnew\rB\nC\rD".utf8))
        XCTAssertEqual(document.format.newlineWarnings(in: document.text).map(\.line), [3])
        document.text = "A\nnew\nBC\nD"
        XCTAssertFalse(document.format.hasMixedNewlines)
        XCTAssertEqual(try document.encodedData(), Data("A\rnew\rBC\rD".utf8))
    }

    func testDeletingTextBetweenCRAndLFDoesNotMergeTwoLineBreaksOnDisk() throws {
        var document = try MarkdownDocument(data: Data("a\rdelete\nb\rc".utf8))
        XCTAssertTrue(document.acceptEditorText("a\n\nb\nc", replacing: NSRange(location: 2, length: 6),
                                                with: "", preservingNewlines: false))
        XCTAssertEqual(document.format.newlineWarnings(in: document.text).map(\.newline), [.crlf])
        let saved = try document.encodedData()
        XCTAssertEqual(saved, Data("a\r\r\nb\rc".utf8))
        let reopened = try MarkdownDocument(data: saved)
        XCTAssertEqual(reopened.text, document.text)
        XCTAssertEqual(reopened.format.newlineWarnings(in: reopened.text), document.format.newlineWarnings(in: document.text))
    }

    func testEncodingWarningsIdentifyEveryScalarAndMatchActualReplacement() throws {
        var document = try MarkdownDocument(data: Data("header\n".utf8), encoding: .latin1)
        document.text += "é e\u{301} 👩‍💻"
        let loss = try XCTUnwrap(MarkdownEncodingLoss(source: document.text, encoding: document.encoding))
        XCTAssertEqual(loss.occurrences.map(\.character), ["e\u{301}", "👩‍💻"])
        XCTAssertEqual(loss.occurrences.map(\.codePoints), ["U+0065 U+0301", "U+1F469 U+200D U+1F4BB"])
        XCTAssertEqual(loss.occurrences.map(\.line), [2, 2])
        XCTAssertEqual(loss.occurrences.map(\.utf16Column), [3, 6])
        try document.replaceUnrepresentableCharacters()
        XCTAssertEqual(document.text, "header\né " + loss.occurrences.map(\.replacement).joined(separator: " "))
        XCTAssertNoThrow(try document.encodedData())
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
