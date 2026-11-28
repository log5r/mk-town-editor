import XCTest
@testable import MKTownEditor

final class EditorUnicodeTests: XCTestCase {
    func testSupplementaryScalarIsOneCodePoint() throws {
        let grapheme = try XCTUnwrap(EditorUnicode.inspect("😀").first)
        XCTAssertEqual(grapheme.scalars.count, 1)
        let scalar = try XCTUnwrap(grapheme.scalars.first)
        XCTAssertEqual(scalar.codePoint, "U+1F600")
        XCTAssertEqual(scalar.name, "GRINNING FACE")
        XCTAssertEqual(scalar.block, "Emoticons")
        XCTAssertEqual(scalar.category, "Other Symbol (So)")
    }

    func testCombiningMarkPreservesOriginalScalars() {
        let graphemes = EditorUnicode.inspect("e\u{0301}é")
        XCTAssertEqual(graphemes.map { $0.scalars.map(\.codePoint) }, [
            ["U+0065", "U+0301"],
            ["U+00E9"]
        ])
        let mark = graphemes.first?.scalars.last
        XCTAssertEqual(mark?.name, "COMBINING ACUTE ACCENT")
        XCTAssertEqual(mark?.block, "Combining Diacritical Marks")
        XCTAssertEqual(mark?.category, "Nonspacing Mark (Mn)")
    }

    func testIdeographicVariationSelectorRemainsPartOfGrapheme() {
        let graphemes = EditorUnicode.inspect("葛\u{E0100}")
        XCTAssertEqual(graphemes.map { $0.scalars.map(\.codePoint) }, [["U+845B", "U+E0100"]])
        let selector = graphemes.first?.scalars.last
        XCTAssertEqual(selector?.name, "VARIATION SELECTOR-17")
        XCTAssertEqual(selector?.block, "Variation Selectors Supplement")
    }

    func testJoinedEmojiStaysTogetherWithZeroWidthJoiner() {
        let graphemes = EditorUnicode.inspect("👩‍💻!")
        XCTAssertEqual(graphemes.map(\.text), ["👩‍💻", "!"])
        XCTAssertEqual(graphemes.map { $0.scalars.map(\.codePoint) }, [["U+1F469", "U+200D", "U+1F4BB"], ["U+0021"]])
        let joiner = graphemes.first?.scalars.first { $0.scalar.value == 0x200D }
        XCTAssertEqual(joiner?.name, "ZERO WIDTH JOINER")
        XCTAssertEqual(joiner?.category, "Format (Cf)")
    }

    func testInspectionShowsStoredNewlineScalarsAtTheirEditorOffsets() {
        let (source, format) = MarkdownTextFormat.read(text: "前\r\n😀\r中\n後", hasUTF8BOM: false)
        let selection = (source as NSString).range(of: "\n😀\n中\n")
        let text = format.textForUnicodeInspection(in: source, selection: selection)
        XCTAssertEqual(EditorUnicode.inspect(text).map { $0.scalars.map(\.codePoint) }, [
            ["U+000D", "U+000A"], ["U+1F600"], ["U+000D"], ["U+4E2D"], ["U+000A"]
        ])
    }

    func testCodePointParsingAcceptsPlainAndPrefixedHex() throws {
        let wideSpace = try XCTUnwrap(EditorUnicode.parseCodePoint("3000"))
        XCTAssertEqual(wideSpace, EditorUnicode.parseCodePoint(" \tu+3000\n"))
        XCTAssertEqual(wideSpace.codePoint, "U+3000")
        XCTAssertEqual(wideSpace.name, "IDEOGRAPHIC SPACE")
        XCTAssertEqual(String(wideSpace.scalar), "　")
        XCTAssertEqual(EditorUnicode.parseCodePoint("U+1f600")?.scalar.value, 0x1F600)
        XCTAssertEqual(EditorUnicode.parseCodePoint("0")?.codePoint, "U+0000")
        XCTAssertEqual(EditorUnicode.parseCodePoint("10FFFF")?.codePoint, "U+10FFFF")
    }

    func testCodePointParsingRejectsMalformedInputAndNonScalars() {
        for input in ["", "U+", "U++21", "+21", "0x21", "２１", "U+0020 U+0021",
                      "U+GGGG", "D800", "DFFF", "110000"] {
            XCTAssertNil(EditorUnicode.parseCodePoint(input), input)
        }
    }

    func testUnnamedScalarsStillHaveBlockAndCategory() throws {
        let privateUse = try XCTUnwrap(EditorUnicode.parseCodePoint("E000"))
        XCTAssertEqual(privateUse.name, "No formal name")
        XCTAssertEqual(privateUse.block, "Private Use Area")
        XCTAssertEqual(privateUse.category, "Private Use (Co)")

        let unallocated = try XCTUnwrap(EditorUnicode.parseCodePoint("40000"))
        XCTAssertEqual(unallocated.block, "No Block")
        XCTAssertEqual(unallocated.category, "Unassigned (Cn)")
    }
}
