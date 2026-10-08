import XCTest
@testable import MKTownEditor

/// The window toolbar shows a few frequent items and never reuses a symbol (#23).
final class WorkspaceToolbarTests: XCTestCase {
    func testEveryToolbarSymbolIsDistinct() {
        // The display mode item is a picker that shows the editor modes' own symbols.
        let items = WorkspaceToolbarItem.allCases.filter { $0 != .displayMode }.map(\.symbolName)
        let symbols = items + EditorCommand.toolbar.map(\.symbolName) + EditorMode.allCases.map(\.symbolName)
        let duplicates = Dictionary(grouping: symbols, by: { $0 }).filter { $0.value.count > 1 }.keys
        XCTAssertTrue(duplicates.isEmpty, "Duplicated toolbar symbols: \(duplicates.sorted())")
        // The system Share symbol means sharing, not publishing.
        XCTAssertFalse(symbols.contains("square.and.arrow.up"))
    }

    func testOnlyFrequentItemsShowByDefault() {
        let defaults = WorkspaceToolbarItem.allCases.filter(\.showsByDefault)
        XCTAssertEqual(Set(defaults), [.displayMode, .splitLayout, .detachedPreview, .exportMenu,
                                       .historyMenu, .writingTools])
        XCTAssertLessThanOrEqual(defaults.count + EditorCommand.defaultToolbar.count, 9)
    }

    func testIdentifiersAndTitlesAreUnique() {
        let items = WorkspaceToolbarItem.allCases
        XCTAssertEqual(Set(items.map(\.rawValue)).count, items.count)
        XCTAssertEqual(Set(items.map(\.title)).count, items.count)
        let commandIDs = Set(EditorCommand.toolbar.map { "command-\($0.toolbarIdentifier)" })
        XCTAssertTrue(commandIDs.isDisjoint(with: items.map(\.rawValue)))
    }

    func testWorkspaceDeclaresEveryToolbarItem() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/MKTownEditor/EditorWorkspace.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for item in WorkspaceToolbarItem.allCases {
            XCTAssertEqual(source.components(separatedBy: "toolbarItem(.\(item)").count - 1, 1, "\(item)")
        }
    }
}
