import Foundation
import XCTest
@testable import MKTownEditor

@MainActor
final class LocalizedIdentifierTests: XCTestCase {
    func testSidebarTabsAreStoredByIdentifierAndReadLegacyJapaneseValues() {
        XCTAssertEqual(EditorWorkspace.SidebarTab.allCases.map(\.rawValue),
                       ["outline", "inspector", "bookmarks", "files"])
        let legacy = ["アウトライン": EditorWorkspace.SidebarTab.outline, "インスペクタ": .inspector,
                      "ブックマーク": .bookmarks, "ファイル": .files]
        for (stored, tab) in legacy {
            XCTAssertEqual(EditorWorkspace.SidebarTab(storedValue: stored), tab)
            XCTAssertEqual(EditorWorkspace.SidebarTab(storedValue: tab.rawValue), tab)
        }
        XCTAssertNil(EditorWorkspace.SidebarTab(storedValue: "unknown"))
    }

    func testSplitOrientationEncodesIdentifiersAndDecodesLegacyJapaneseValues() throws {
        XCTAssertEqual(String(data: try JSONEncoder().encode([EditorSplitOrientation.stacked]), encoding: .utf8),
                       #"["stacked"]"#)
        let decoded = try JSONDecoder().decode([EditorSplitOrientation].self,
                                               from: Data(#"["左右","上下","sideBySide","stacked"]"#.utf8))
        XCTAssertEqual(decoded, [.sideBySide, .stacked, .sideBySide, .stacked])
        XCTAssertThrowsError(try JSONDecoder().decode([EditorSplitOrientation].self, from: Data(#"["縦"]"#.utf8)))
    }

    func testNamedLayoutSavedByAnEarlierVersionStillLoads() throws {
        let layout = WorkspaceNamedLayout.capture(
            name: "執筆", root: URL(fileURLWithPath: "/tmp"), openDocuments: [], activeDocument: nil,
            mode: .split, sidebarTab: "アウトライン", sidebarVisible: true, splitRatio: 0.5,
            splitOrientation: .stacked, previewFirst: false)
        var json = String(data: try JSONEncoder().encode(layout), encoding: .utf8)!
        json = json.replacingOccurrences(of: #""stacked""#, with: #""上下""#)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceNamedLayout.self, from: Data(json.utf8)).splitOrientation,
                       .stacked)
    }
}
