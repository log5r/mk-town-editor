import Foundation
import XCTest
@testable import MKTownEditor

/// The window-side decision for "書類を開いたときの表示". The hosted workspace checks are in
/// EditorWorkspacePersistenceTests.
@MainActor
final class DocumentOpeningModeTests: XCTestCase {
    func testAlwaysPreviewShowsPreviewFromTheFirstFrameWithoutChangingTheSavedMode() {
        for saved in EditorMode.allCases {
            var session = EditorSessionMode()
            XCTAssertEqual(session.resolve(saved: saved, opening: .alwaysPreview), .preview,
                           "the frames before onAppear already show the preview")
            session.open(opening: .alwaysPreview)
            XCTAssertEqual(session.resolve(saved: saved, opening: .alwaysPreview), .preview)
            XCTAssertEqual(session.override, .preview)
        }
    }

    func testPickedModeSticksAndLaterAppearancesDoNotReturnToPreview() {
        var session = EditorSessionMode()
        session.open(opening: .alwaysPreview)
        session.select()
        XCTAssertEqual(session.resolve(saved: .editor, opening: .alwaysPreview), .editor,
                       "the picked mode is the saved one and stays")
        session.open(opening: .alwaysPreview)
        XCTAssertEqual(session.resolve(saved: .editor, opening: .alwaysPreview), .editor,
                       "the same window appearing again keeps its mode")
    }

    func testModeChangeBeforeOnAppearPreventsTheOpeningPreview() {
        var session = EditorSessionMode()
        session.select()
        session.open(opening: .alwaysPreview)
        XCTAssertEqual(session.resolve(saved: .split, opening: .alwaysPreview), .split)
    }

    func testLastUsedAndUntitledDocumentsUseTheSavedMode() {
        for opening: DocumentOpeningMode? in [.lastUsed, nil] {
            var session = EditorSessionMode()
            XCTAssertEqual(session.resolve(saved: .editor, opening: opening), .editor)
            session.open(opening: opening)
            XCTAssertNil(session.override)
            XCTAssertEqual(session.resolve(saved: .split, opening: opening), .split)
        }
    }

    func testOpeningsThatDecideTheModeThemselvesSkipThePreview() {
        var session = EditorSessionMode()
        XCTAssertEqual(session.resolve(saved: .split, opening: .alwaysPreview, usesSavedMode: true), .split)
        session.open(opening: .alwaysPreview, usesSavedMode: true)
        XCTAssertNil(session.override)
    }

    func testOpeningModeTitlesAreDistinct() {
        XCTAssertEqual(DocumentOpeningMode.default, .alwaysPreview)
        XCTAssertEqual(Set(DocumentOpeningMode.allCases.map(\.title)).count, DocumentOpeningMode.allCases.count)
    }

    func testPendingLineOrSearchPositionMeansTheWindowOpensForEditing() {
        let navigation = DocumentLinkNavigation()
        let file = URL(fileURLWithPath: "/tmp/opening/../opening-line.md")
        let other = URL(fileURLWithPath: "/tmp/opening-other.md")
        XCTAssertFalse(navigation.hasPendingEditorPosition(for: file))
        navigation.requestLine(in: file, line: 4)
        XCTAssertTrue(navigation.hasPendingEditorPosition(for: URL(fileURLWithPath: "/tmp/opening-line.md")))
        XCTAssertFalse(navigation.hasPendingEditorPosition(for: other))
        XCTAssertEqual(navigation.takeLine(for: file), 4)
        XCTAssertFalse(navigation.hasPendingEditorPosition(for: file))
        navigation.requestPosition(in: other, range: NSRange(location: 2, length: 1))
        XCTAssertTrue(navigation.hasPendingEditorPosition(for: other))
        navigation.cancelPosition(for: other)
        XCTAssertFalse(navigation.hasPendingEditorPosition(for: other))
    }

    func testNamedLayoutDocumentsOpenOnceWithTheLayoutMode() {
        let activation = WorkspaceLayoutActivation()
        let first = URL(fileURLWithPath: "/tmp/layout-first.md")
        let second = URL(fileURLWithPath: "/tmp/layout-second.md")
        let layout = WorkspaceNamedLayout.capture(name: "Review", root: URL(fileURLWithPath: "/tmp"),
            openDocuments: [first, second], activeDocument: first, mode: .editor, sidebarTab: "outline",
            sidebarVisible: false, splitRatio: 0.5, splitOrientation: .sideBySide, previewFirst: false)
        activation.activate(layout, documents: [first, second])
        XCTAssertTrue(activation.isOpening(first))
        activation.finishOpening(first)
        XCTAssertFalse(activation.isOpening(first), "a later open of the document starts as usual")
        XCTAssertTrue(activation.isOpening(second))
        activation.activate(layout, documents: [first])
        XCTAssertFalse(activation.isOpening(second), "a new activation replaces the documents")
    }
}
