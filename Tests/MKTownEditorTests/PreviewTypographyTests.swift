import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

@MainActor
final class PreviewTypographyTests: XCTestCase {
    func testZoomChangesFontsWithoutChangingLinksOrText() throws {
        let source = "# Title\n\n[link](https://example.com) and **bold**"
        let rendered = MarkdownRenderer.render(source)
        let scaled = PreviewTypography.scaled(rendered, by: 1.5)
        let title = (rendered.string as NSString).range(of: "Title")
        let originalFont = try XCTUnwrap(rendered.attribute(.font, at: title.location,
                                                          effectiveRange: nil) as? NSFont)
        let largerFont = try XCTUnwrap(scaled.attribute(.font, at: title.location,
                                                      effectiveRange: nil) as? NSFont)
        XCTAssertEqual(largerFont.pointSize, originalFont.pointSize * 1.5, accuracy: 0.01)
        XCTAssertEqual(scaled.string, rendered.string)
        let link = (rendered.string as NSString).range(of: "link")
        XCTAssertEqual(scaled.attribute(.link, at: link.location, effectiveRange: nil) as? URL,
                       URL(string: "https://example.com"))
    }

    func testPaperPaletteKeepsTextReadableAndChangesHeadingAndCode() throws {
        let theme = PreviewTheme.paper
        let background = try XCTUnwrap(theme.background)
        XCTAssertGreaterThanOrEqual(PreviewTypography.contrastRatio(try XCTUnwrap(theme.bodyColor), background), 7)
        XCTAssertGreaterThanOrEqual(PreviewTypography.contrastRatio(try XCTUnwrap(theme.headingColor), background), 7)
        XCTAssertGreaterThanOrEqual(PreviewTypography.contrastRatio(try XCTUnwrap(theme.codeColor), background), 7)
        let source = NSAttributedString(string: "Heading")
        let themed = PreviewTypography.themed(source, kind: .heading(level: 1), theme: theme)
        XCTAssertEqual(themed.string, source.string)
        XCTAssertEqual(themed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       theme.headingColor)
        let code = PreviewTypography.themed(source, kind: .codeBlock, theme: theme)
        XCTAssertEqual(code.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       theme.codeColor)
        // コードブロックの背景は囲み枠が塗るため、文字ごとの背景は付けない。
        XCTAssertNil(code.attribute(.backgroundColor, at: 0, effectiveRange: nil))
        XCTAssertTrue(PreviewTypography.themed(source, kind: nil, theme: .system) === source)
    }

    func testCodeBlockBodyDropsPerCharacterBackgroundAndKeepsOtherAttributes() {
        let source = CodeSyntaxHighlighter.render("let x = 1\nprint(x)", language: "swift")
        XCTAssertNotNil(source.attribute(.backgroundColor, at: 0, effectiveRange: nil))

        let body = PreviewTypography.codeBlockBody(source)
        let range = NSRange(location: 0, length: body.length)
        var backgrounds = 0
        body.enumerateAttribute(.backgroundColor, in: range) { value, _, _ in
            if value != nil { backgrounds += 1 }
        }
        XCTAssertEqual(backgrounds, 0)
        XCTAssertEqual(body.string, source.string)
        XCTAssertEqual(body.attribute(.codeSyntaxToken, at: 0, effectiveRange: nil) as? String, "keyword")
        XCTAssertNotNil(body.attribute(.font, at: 0, effectiveRange: nil))

        let plain = NSAttributedString(string: "code")
        XCTAssertTrue(PreviewTypography.codeBlockBody(plain) === plain)
    }

    func testCodeBlockFrameUsesThemeBackgroundOrTranslucentPrimary() throws {
        XCTAssertEqual(PreviewCodeBlockFrame.fill(for: .system), Color.primary.opacity(0.05))
        XCTAssertEqual(PreviewCodeBlockFrame.fill(for: .paper),
                       Color(nsColor: try XCTUnwrap(PreviewTheme.paper.codeBackground)))
    }
}
