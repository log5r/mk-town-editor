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
        XCTAssertEqual(PreviewCodeBlockStyle.fillLayers(for: .system, isSearchMatch: false),
                       [Color.primary.opacity(0.05)])
        XCTAssertEqual(PreviewCodeBlockStyle.fillLayers(for: .paper, isSearchMatch: false),
                       [Color(nsColor: try XCTUnwrap(PreviewTheme.paper.codeBackground))])
    }

    /// 不具合: 紙色・拡張テーマの不透明な枠の面が、行の背景に付けた検索一致の色を覆い隠していた。
    func testSearchMatchTintIsDrawnAboveOpaqueCodeFrameFill() throws {
        let layers = PreviewCodeBlockStyle.fillLayers(for: .paper, isSearchMatch: true)
        XCTAssertEqual(layers, [Color(nsColor: try XCTUnwrap(PreviewTheme.paper.codeBackground)),
                                PreviewCodeBlockStyle.searchMatchTint])
    }

    /// 不具合: 暗いコード背景の拡張テーマで、コピーボタンが標準の色のまま背景に埋もれていた。
    func testCopyButtonUsesThemeCodeColorValidatedAgainstCodeBackground() throws {
        XCTAssertNil(PreviewCodeBlockStyle.copyButtonColor(for: .system))
        let theme = DeclarativeExtension.Theme(name: "Deep", background: "#FFFFFF", body: "#000000",
                                               heading: "#000000", code: "#FFFFFF", link: "#000080",
                                               codeBackground: "#003399")
        let themed = PreviewTheme.extensionTheme(theme)
        let code = try XCTUnwrap(themed.codeColor)
        XCTAssertEqual(PreviewCodeBlockStyle.copyButtonColor(for: themed), Color(nsColor: code))
        XCTAssertGreaterThanOrEqual(PreviewTypography.contrastRatio(code, try XCTUnwrap(themed.codeBackground)), 4.5)
        XCTAssertEqual(PreviewCodeBlockStyle.copyButtonColor(for: .paper),
                       Color(nsColor: try XCTUnwrap(PreviewTheme.paper.codeColor)))
    }

    /// 不具合: 空のコードブロックでは本文の高さがなく、重ねたコピーボタンが枠の下へはみ出していた。
    func testEmptyCodeBlockFrameIsTallEnoughForCopyButton() {
        let button = NSHostingView(rootView: PreviewCodeBlockStyle.copyButton(action: {}))
        let frame = NSHostingView(rootView: PreviewCodeBlockFrame(theme: .system, onCopy: {}) {
            Text(AttributedString(""))
        }.frame(width: 400))
        let padding = PreviewCodeBlockStyle.padding
        XCTAssertGreaterThan(button.fittingSize.height, 0)
        XCTAssertGreaterThanOrEqual(frame.fittingSize.height, button.fittingSize.height + 2 * padding - 0.5)
    }
}
