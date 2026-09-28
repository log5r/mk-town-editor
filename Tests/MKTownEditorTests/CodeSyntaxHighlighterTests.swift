import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class CodeSyntaxHighlighterTests: XCTestCase {
    func testSwiftHighlightSeparatesKeywordsStringsCommentsAndNumbers() {
        let source = "let count = 42\nlet text = \"if // still string\" // comment"
        let tokens = CodeSyntaxHighlighter.tokenRanges(in: source, language: "swift")
        let text = source as NSString
        let values = tokens.map { (text.substring(with: $0.0), $0.1) }

        XCTAssertTrue(values.contains { $0.0 == "let" && $0.1 == .keyword })
        XCTAssertTrue(values.contains { $0.0 == "42" && $0.1 == .number })
        XCTAssertTrue(values.contains { $0.0 == "\"if // still string\"" && $0.1 == .string })
        XCTAssertTrue(values.contains { $0.0 == "// comment" && $0.1 == .comment })
        XCTAssertFalse(values.contains { $0.0 == "if" })
    }

    func testAliasesAndUnsupportedLanguages() {
        XCTAssertTrue(CodeSyntaxHighlighter.tokenRanges(in: "def work(): # note",
                                                       language: "py").contains { $0.1 == .keyword })
        XCTAssertTrue(CodeSyntaxHighlighter.tokenRanges(in: "const value = 1",
                                                       language: "js").contains { $0.1 == .keyword })
        XCTAssertTrue(CodeSyntaxHighlighter.tokenRanges(in: "{\"ok\": true}",
                                                       language: "json").contains { $0.1 == .keyword })
        XCTAssertTrue(CodeSyntaxHighlighter.tokenRanges(in: "let x = 1",
                                                       language: "unknown").isEmpty)
    }

    func testRendererUsesFenceLanguageAndPreservesPlainFallback() throws {
        let highlighted = MarkdownRenderer.render("```swift\nlet x = 1\n```")
        let plain = MarkdownRenderer.render("```unknown\nlet x = 1\n```")
        let keyword = (highlighted.string as NSString).range(of: "let")
        XCTAssertEqual(highlighted.attribute(.foregroundColor, at: keyword.location,
                                             effectiveRange: nil) as? NSColor, .systemBlue)
        XCTAssertEqual(plain.attribute(.foregroundColor, at: keyword.location,
                                       effectiveRange: nil) as? NSColor, .textColor)
        XCTAssertEqual(highlighted.string, plain.string)
        XCTAssertNotNil(highlighted.attribute(.font, at: keyword.location, effectiveRange: nil))
    }
}
