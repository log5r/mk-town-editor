import XCTest
#if canImport(MKTownMobileCore)
@testable import MKTownMobileCore
#else
@testable import MKTownEditorMobile
#endif

final class MobileEditorLayoutTests: XCTestCase {
    func testFindShowsEditorFromEveryPresentationAtEveryLayout() {
        for presentation in MobileEditorPresentation.allCases {
            for compactPreview in [false, true] {
                var state = MobileEditorState(presentation: presentation, compactPreview: compactPreview)
                state.showFindNavigator()
                XCTAssertTrue(state.findRequested)
                XCTAssertFalse(state.showsFindNavigator)
                state.presentRequestedFindNavigator()
                XCTAssertTrue(state.showsFindNavigator)
                XCTAssertEqual(state.presentation, presentation == .preview ? .editor : presentation)
                for width in [320.0, 720, 1200] {
                    for accessibilityText in [false, true] {
                        XCTAssertTrue(MobileEditorLayout(width: width, accessibilityText: accessibilityText,
                            presentation: state.presentation, compactPreview: state.compactPreview).showsEditor)
                    }
                }
            }
        }
    }

    func testReturningToPreviewClosesFindAndAllowsReopening() {
        for presentation in [MobileEditorPresentation.automatic, .editor] {
            var state = MobileEditorState(presentation: presentation)
            state.showFindNavigator()
            state.presentRequestedFindNavigator()
            state.togglePreview(showsEditor: true)
            XCTAssertFalse(state.showsFindNavigator)
            XCTAssertTrue(MobileEditorLayout(width: 390, accessibilityText: false,
                presentation: state.presentation, compactPreview: state.compactPreview).showsPreview)
            state.showFindNavigator()
            state.presentRequestedFindNavigator()
            XCTAssertTrue(state.showsFindNavigator)
            XCTAssertTrue(MobileEditorLayout(width: 390, accessibilityText: false,
                presentation: state.presentation, compactPreview: state.compactPreview).showsEditor)
        }
    }

    func testHidingEditorDismissesSearch() {
        var state = MobileEditorState()
        state.showFindNavigator()
        state.dismissFindNavigator()
        state.presentRequestedFindNavigator()
        XCTAssertFalse(state.showsFindNavigator)
        XCTAssertFalse(state.findRequested)
    }

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
