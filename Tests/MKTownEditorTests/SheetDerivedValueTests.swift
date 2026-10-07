import Foundation
import XCTest
@testable import MKTownEditor

@MainActor
final class SheetDerivedValueTests: XCTestCase {
    func testDerivedValueIsRecomputedOnlyWhenInputChanges() {
        let cache = DerivedValueCache<String, Int>()
        var computations = 0
        for _ in 0..<5 {
            XCTAssertEqual(cache.value(for: "abc") { computations += 1; return $0.count }, 3)
        }
        XCTAssertEqual(computations, 1)
        XCTAssertEqual(cache.value(for: "abcd") { computations += 1; return $0.count }, 4)
        XCTAssertEqual(cache.value(for: "abcd") { computations += 1; return $0.count }, 4)
        XCTAssertEqual(computations, 2)
        XCTAssertEqual(cache.computationCount, 2)
    }

    func testLimitedLineIndexMatchesFullIndexPrefix() {
        let text = "a\r\nb\rc\n\nd\r\n"
        let full = MarkdownLineIndex(text).starts
        for limit in 0...((text as NSString).length + 1) {
            let limited = MarkdownLineIndex(text, through: limit).starts
            XCTAssertEqual(limited, Array(full.prefix(limited.count)), "limit \(limit)")
            if let last = limited.last, last < limit { XCTAssertEqual(limited, full) }
        }
    }

    func testFrontMatterPropertiesDoNotDependOnTheBodyLength() throws {
        let header = "---\ntitle: 題名\ntags: [a, b]\n---\n"
        let short = header + "本文"
        let long = header + String(repeating: "本文の行\n", count: 200_000)
        XCTAssertEqual(FrontMatterProperties.items(in: long), FrontMatterProperties.items(in: short))
        XCTAssertEqual(FrontMatterProperties.items(in: long).map(\.key), ["title", "tags"])
        let edit = try XCTUnwrap(FrontMatterProperties.upsert(in: long, key: "author", value: "名前"))
        XCTAssertTrue(edit.applying(to: long).hasPrefix("---\ntitle: 題名\ntags: [a, b]\nauthor: 名前\n---\n"))
        XCTAssertNil(MarkdownFrontMatter(source: "本文\n---\n"))
        XCTAssertNil(MarkdownFrontMatter(source: "-- \n---"))

        let start = Date()
        for _ in 0..<20 { _ = FrontMatterProperties.items(in: long) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testFrontMatterScanMatchesFullLineIndexReference() {
        let pieces = ["---", "...", "title: a", "", "本文", "--- ", "\r\n", "\n", "\r"]
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            let source = (0..<Int.random(in: 0...8, using: &generator))
                .map { _ in pieces.randomElement(using: &generator)! }.joined()
            let expected = Self.referenceFrontMatter(source)
            let actual = MarkdownFrontMatter(source: source)
            XCTAssertEqual(actual?.sourceRange, expected?.range, source.debugDescription)
            XCTAssertEqual(actual?.content, expected?.content, source.debugDescription)
        }
    }

    private static func referenceFrontMatter(_ source: String) -> (range: NSRange, content: String)? {
        let text = source as NSString
        let starts = MarkdownLineIndex(source).starts
        guard starts.count >= 2 else { return nil }
        func line(_ index: Int) -> String {
            let end = index + 1 < starts.count ? starts[index + 1] : text.length
            return text.substring(with: NSRange(location: starts[index], length: end - starts[index]))
                .trimmingCharacters(in: .newlines)
        }
        guard line(0) == "---",
              let closing = (1..<starts.count).first(where: { line($0) == "---" || line($0) == "..." })
        else { return nil }
        let end = closing + 1 < starts.count ? starts[closing + 1] : text.length
        return (NSRange(location: 0, length: end),
                text.substring(with: NSRange(location: starts[1], length: starts[closing] - starts[1])))
    }
}
