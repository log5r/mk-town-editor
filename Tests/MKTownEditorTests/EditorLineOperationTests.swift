import XCTest
@testable import MKTownEditor

final class EditorLineOperationTests: XCTestCase {
    func testSortAscendingWithoutSelectionUsesWholeDocumentAndKeepsFinalLineUnterminated() {
        let source = "B 日本語\nA 用語\nC 絵文字🙂"
        let edit = MarkdownFormatter.apply(.lineOperation(.sortAscending), to: source,
                                           selection: NSRange(location: 2, length: 0))
        let updated = edit.applying(to: source)

        XCTAssertEqual(updated, "A 用語\nB 日本語\nC 絵文字🙂")
        XCTAssertEqual((updated as NSString).substring(with: edit.selection), updated)
    }

    func testReverseUsesTouchedLinesWithoutIncludingAnUntouchedLineAfterCRLF() {
        let source = "前\r\n🙂二\r\n三\r\n後"
        let selection = (source as NSString).range(of: "二\r\n三\r\n")
        let edit = MarkdownFormatter.apply(.lineOperation(.reverse), to: source, selection: selection)
        let updated = edit.applying(to: source)

        XCTAssertEqual(updated, "前\r\n三\r\n🙂二\r\n後")
        XCTAssertEqual((updated as NSString).substring(with: edit.selection), "三\r\n🙂二\r\n")
        XCTAssertEqual(MarkdownFormatter.lineOperationSample(in: source, selection: selection), ["🙂二", "三"])
        XCTAssertEqual(MarkdownFormatter.lineOperationSample(in: source, selection: selection, limit: 1), ["🙂二"])
    }

    func testReverseKeepsBlankLineWhenLFMovesNextToCR() {
        let source = "end\n\rmiddle\nstart"
        let edit = MarkdownFormatter.apply(.lineOperation(.reverse), to: source,
                                           selection: NSRange(location: 0, length: 0))

        XCTAssertEqual(edit.applying(to: source), "start\nmiddle\r\r\nend")
    }

    func testRemoveDuplicatesKeepsFirstExactOccurrenceAndFinalLineEnding() {
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        let source = "\(composed)\r\n\(decomposed)\r\n後\r\n\(composed)\r\n後"

        let edit = MarkdownFormatter.apply(.lineOperation(.removeDuplicates), to: source,
                                           selection: NSRange(location: 0, length: 0))

        XCTAssertEqual(Array(edit.applying(to: source).utf8), Array("\(composed)\r\n\(decomposed)\r\n後".utf8))
    }

    func testJoinNormalizesWhitespaceAndOmitsSpacesBetweenJapaneseCharacters() {
        let source = "  日本 \r\n　語。\r\n\r\n\tEnglish   \r\n words  \r\n"
        let edit = MarkdownFormatter.apply(.lineOperation(.join), to: source,
                                           selection: NSRange(location: 0, length: 0))

        XCTAssertEqual(edit.applying(to: source), "  日本語。 English words  \r\n")
    }

    func testJoinUsesOneSpaceAcrossBlankLinesBetweenJapaneseCharacters() {
        let source = "前\n\n\t\n後"
        let edit = MarkdownFormatter.apply(.lineOperation(.join), to: source,
                                           selection: NSRange(location: 0, length: 0))

        XCTAssertEqual(edit.applying(to: source), "前 後")
    }

    func testJoinRecognizesKanaAndSymbolsSharedAcrossJapaneseScripts() {
        let source = "〆\n切〜\nﾃｽﾄ\n資料"
        let edit = MarkdownFormatter.apply(.lineOperation(.join), to: source,
                                           selection: NSRange(location: 0, length: 0))

        XCTAssertEqual(edit.applying(to: source), "〆切〜ﾃｽﾄ資料")
    }

    func testSortByColumnKeepsHeaderAndStableOrderForEquivalentAndMissingKeys() {
        let source = "row|rank\nfirst|a2\nmissing\nunit|a10\nsecond|A2\nlast"
        let options = EditorLineSortOptions(key: .column(separator: "|", number: 2),
                                           ignoresCase: true, numeric: true, descending: true,
                                           keepsFirstLine: true)
        let edit = MarkdownFormatter.apply(.lineOperation(.sort(options)), to: source,
                                           selection: NSRange(location: 0, length: 0))

        XCTAssertEqual(edit.applying(to: source), "row|rank\nunit|a10\nfirst|a2\nsecond|A2\nmissing\nlast")
    }

    func testLocalizedSortTreatsFullwidthAndHalfwidthKeysAsEqual() {
        let source = "wide|ａ\nnarrow|a"
        let key = EditorLineSortOptions.Key.column(separator: "|", number: 2)
        let defaultOrder = MarkdownFormatter.apply(.lineOperation(.sort(.init(key: key))), to: source,
                                                    selection: NSRange(location: 0, length: 0))
        let localizedOrder = MarkdownFormatter.apply(.lineOperation(.sort(.init(key: key, localized: true))),
                                                      to: source, selection: NSRange(location: 0, length: 0))

        XCTAssertEqual(defaultOrder.applying(to: source), "narrow|a\nwide|ａ")
        XCTAssertEqual(localizedOrder.applying(to: source), source)
    }

    func testSortByRegularExpressionUsesTheSelectedCaptureAndPartialsBecomeMissingKeys() throws {
        let source = "前\n品目20\n品目\n品目2\n後"
        let selection = (source as NSString).range(of: "20\n品目\n品目2")
        let options = EditorLineSortOptions(key: .regularExpression(pattern: #"品目(\d+)?"#, capture: 1),
                                           numeric: true)
        let extract = try options.makeKeyExtractor()
        let edit = MarkdownFormatter.apply(.lineOperation(.sort(options)), to: source, selection: selection)

        XCTAssertEqual(extract("品目20"), "20")
        XCTAssertNil(extract("品目"))
        XCTAssertNil(extract("無関係"))
        XCTAssertEqual(edit.applying(to: source), "前\n品目2\n品目20\n品目\n後")
    }

    func testInvalidSortConfigurationDoesNotChangeTextOrSelection() {
        let source = "two\none"
        let selection = NSRange(location: 1, length: 5)
        let invalidKeys: [EditorLineSortOptions.Key] = [
            .column(separator: "", number: 1), .column(separator: ":", number: 0),
            .regularExpression(pattern: "[", capture: 0), .regularExpression(pattern: "(a)", capture: 2)
        ]
        for key in invalidKeys {
            let options = EditorLineSortOptions(key: key)
            XCTAssertThrowsError(try options.makeKeyExtractor())
            for shortSource in ["", "one"] {
                XCTAssertThrowsError(try MarkdownFormatter.lineOperationEdit(.sort(options), in: shortSource,
                    selection: NSRange(location: 0, length: 0)))
            }
            let edit = MarkdownFormatter.apply(.lineOperation(.sort(options)), to: source, selection: selection)
            XCTAssertEqual(edit.applying(to: source), source)
            XCTAssertEqual(edit.selection, selection)
        }
    }

    @MainActor
    func testCancelledRegexSortDoesNotProduceAnEdit() async throws {
        let options = EditorLineSortOptions(key: .regularExpression(pattern: "(.+)", capture: 1))
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try MarkdownFormatter.lineOperationEdit(.sort(options), in: "b\na",
                                                            selection: NSRange(location: 0, length: 0))
        }
        do {
            _ = try await worker.value
            XCTFail("A cancelled sort returned an edit.")
        } catch is CancellationError {
        }
    }
}
