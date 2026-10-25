import XCTest
#if canImport(MKTownMobileCore)
@testable import MKTownMobileCore
#else
@testable import MKTownEditorMobile
#endif

final class MobileEditorLayoutTests: XCTestCase {
    func testAutomaticLayoutFollowsAvailableWidthAcrossRepeatedFoldTransitions() {
        for width in [390.0, 960, 500, 720, 719, 1200, 320] {
            let layout = MobileEditorLayout(width: width, accessibilityText: false,
                                            presentation: .automatic, compactPreview: false)
            XCTAssertTrue(layout.showsEditor)
            XCTAssertEqual(layout.showsPreview, width >= 720)
        }
    }

    func testPreviewPreferenceSurvivesUnfoldAndFold() {
        for width in [390.0, 960, 390] {
            let layout = MobileEditorLayout(width: width, accessibilityText: false,
                                            presentation: .automatic, compactPreview: true)
            XCTAssertTrue(layout.showsPreview)
            XCTAssertEqual(layout.showsEditor, width >= 720)
        }
    }

    func testAccessibilityTextUsesOneReadableColumnEvenOnWideDisplay() {
        for preview in [false, true] {
            let layout = MobileEditorLayout(width: 1200, accessibilityText: true,
                                            presentation: .automatic, compactPreview: preview)
            XCTAssertEqual(layout.showsEditor, !preview)
            XCTAssertEqual(layout.showsPreview, preview)
        }
    }

    func testExplicitPresentationIsRespectedAtEveryWidth() {
        for width in [320.0, 960, 1200] {
            for size in [false, true] {
                let editor = MobileEditorLayout(width: width, accessibilityText: size,
                                                presentation: .editor, compactPreview: true)
                XCTAssertTrue(editor.showsEditor)
                XCTAssertFalse(editor.showsPreview)
                let preview = MobileEditorLayout(width: width, accessibilityText: size,
                                                 presentation: .preview, compactPreview: false)
                XCTAssertFalse(preview.showsEditor)
                XCTAssertTrue(preview.showsPreview)
            }
        }
    }
}
