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

    // MARK: - ツールバーの背景（Liquid Glass）

    @MainActor
    func testToolbarBackgroundIsOpaqueOnlyWithoutLiquidGlass() {
        XCTAssertEqual(WorkspaceToolbarBackground.policy(usesLiquidGlass: false), .opaqueWindowBackground)
        XCTAssertEqual(WorkspaceToolbarBackground.policy(usesLiquidGlass: true), .systemGlass)
        if #available(macOS 26, *) {
            XCTAssertEqual(WorkspaceToolbarBackground.current, .systemGlass)
        } else {
            XCTAssertEqual(WorkspaceToolbarBackground.current, .opaqueWindowBackground)
        }
        XCTAssertEqual(WorkspaceToolbarBackgroundModifier().background, .current)
    }

    /// 不透明な帯を直接指定すると、macOS 26以降でもシステムのガラスの帯を塗りつぶす。背景は方針を通してだけ指定する。
    func testWorkspaceAppliesToolbarBackgroundOnlyThroughThePolicy() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/MKTownEditor/EditorWorkspace.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let policy = try XCTUnwrap(source.range(of: "struct WorkspaceToolbarBackgroundModifier"))
        let body = try XCTUnwrap(source.range(of: "/// ForEach cannot provide individually customizable toolbar items."))
        let outside = String(source[..<policy.lowerBound]) + String(source[body.lowerBound...])
        XCTAssertFalse(outside.contains(".toolbarBackground("))
        XCTAssertFalse(outside.contains(".toolbarBackgroundVisibility("))
        XCTAssertEqual(source.components(separatedBy: ".modifier(WorkspaceToolbarBackgroundModifier())").count - 1, 1)
        // ツールバーの項目に独自のガラスを重ねない（システムが描く）。
        XCTAssertFalse(source.contains(".buttonStyle(.glass"))
        XCTAssertFalse(source.contains(".glassEffect("))
    }
}
