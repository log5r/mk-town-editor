import AppKit
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
}
