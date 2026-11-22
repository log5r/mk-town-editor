import AppKit
import Combine
import XCTest
@testable import MKTownEditor

/// macOSの外観（ライト・ダーク）に合わせた配色の切り替え。仕様は docs/preview-themes.md の
/// 「外観に合わせた配色の切り替え」を参照。外観はテストで差し替え、ホストのMacの外観に左右されないようにする。
@MainActor
final class AppearanceThemeSwitchingTests: XCTestCase {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "AppearanceThemeSwitchingTests." + UUID().uuidString
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    private func package(id: String = "example.theme", theme: DeclarativeExtension.Theme) throws -> DeclarativeExtension {
        var package = try JSONDecoder().decode(DeclarativeExtension.self, from: Data(
            "{\"schemaVersion\":1,\"id\":\"\(id)\",\"name\":\"Example\"}".utf8))
        package.theme = theme
        return package
    }

    // MARK: - 配色の決定

    func testFixedThemeIsUsedRegardlessOfAppearanceWhenSwitchingIsOff() {
        var settings = AppEditorSettings()
        settings.editorTheme = .preset(.nord)
        settings.previewTheme = .paper
        // 切り替えがオフなら、ライト用・ダーク用の配色は使わない。
        settings.editorLightTheme = .preset(.tomorrow)
        settings.previewDarkTheme = .preset(.dracula)
        for appearance in [InterfaceAppearance.light, .dark] {
            XCTAssertEqual(settings.theme(for: .editor, appearance: appearance), .preset(.nord))
            XCTAssertEqual(settings.theme(for: .preview, appearance: appearance), .paper)
            XCTAssertEqual(settings.themeSlot(for: .editor, appearance: appearance), .fixed)
        }
        // 明示的にオフにした場合も同じ。
        settings.editorThemeFollowsAppearance = false
        XCTAssertEqual(settings.theme(for: .editor, appearance: .dark), .preset(.nord))
    }

    func testAppearanceSelectsLightOrDarkThemeAndUnsetSideUsesDefault() {
        var settings = AppEditorSettings()
        settings.editorThemeFollowsAppearance = true
        settings.previewThemeFollowsAppearance = true
        // どちらも未設定なら既定。エディタはGitHub風（ライト）と紺色、プレビューはGitHub風（ライト）とGitHub風（ダーク）。
        XCTAssertEqual(settings.theme(for: .editor, appearance: .light), .preset(.githubLight))
        XCTAssertEqual(settings.theme(for: .editor, appearance: .dark), .navy)
        XCTAssertEqual(settings.theme(for: .preview, appearance: .light), .preset(.githubLight))
        XCTAssertEqual(settings.theme(for: .preview, appearance: .dark), .preset(.githubDark))

        settings.editorLightTheme = .paper
        settings.previewDarkTheme = .preset(.nord)
        XCTAssertEqual(settings.theme(for: .editor, appearance: .light), .paper)
        XCTAssertEqual(settings.theme(for: .editor, appearance: .dark), .navy, "未設定の側は既定のまま")
        XCTAssertEqual(settings.theme(for: .preview, appearance: .light), .preset(.githubLight))
        XCTAssertEqual(settings.theme(for: .preview, appearance: .dark), .preset(.nord))
    }

    func testEditorAndPreviewSwitchIndependently() {
        var settings = AppEditorSettings()
        settings.editorTheme = .preset(.tomorrowNight)
        settings.previewTheme = .paper
        settings.previewThemeFollowsAppearance = true
        settings.previewLightTheme = .preset(.tomorrow)
        settings.previewDarkTheme = .preset(.dracula)
        // プレビューだけが外観に合わせて変わり、エディタは固定の配色のまま。
        XCTAssertEqual(settings.theme(for: .editor, appearance: .light), .preset(.tomorrowNight))
        XCTAssertEqual(settings.theme(for: .editor, appearance: .dark), .preset(.tomorrowNight))
        XCTAssertEqual(settings.theme(for: .preview, appearance: .light), .preset(.tomorrow))
        XCTAssertEqual(settings.theme(for: .preview, appearance: .dark), .preset(.dracula))

        settings.previewThemeFollowsAppearance = nil
        settings.editorThemeFollowsAppearance = true
        XCTAssertEqual(settings.theme(for: .editor, appearance: .light), .preset(.githubLight))
        XCTAssertEqual(settings.theme(for: .preview, appearance: .dark), .paper)
    }

    /// 切り替えをオンにしても固定の配色は消えず、オフに戻すと元の配色に戻る。
    func testTurningSwitchingOffRestoresFixedTheme() {
        var settings = AppEditorSettings()
        settings.editorTheme = .preset(.dracula)
        settings.editorThemeFollowsAppearance = true
        settings.editorDarkTheme = .preset(.nord)
        XCTAssertEqual(settings.theme(for: .editor, appearance: .dark), .preset(.nord))
        XCTAssertEqual(settings.editorTheme, .preset(.dracula))
        settings.editorThemeFollowsAppearance = false
        XCTAssertEqual(settings.theme(for: .editor, appearance: .dark), .preset(.dracula))
    }

    /// 編集画面に「システム」は使えないため、ライト用・ダーク用に保存されていても「紺色」にする。
    func testEditorResultNeverUsesSystemTheme() {
        var settings = AppEditorSettings()
        settings.editorThemeFollowsAppearance = true
        settings.editorLightTheme = .system
        settings.editorDarkTheme = .system
        settings.previewThemeFollowsAppearance = true
        settings.previewLightTheme = .system
        XCTAssertEqual(settings.theme(for: .editor, appearance: .light), .navy)
        XCTAssertEqual(settings.theme(for: .editor, appearance: .dark), .navy)
        XCTAssertEqual(settings.theme(for: .editor, slot: .light), .navy)
        XCTAssertEqual(settings.theme(for: .preview, appearance: .light), .system, "プレビューの「システム」はそのまま")
    }

    // MARK: - 配色の変更

    func testSelectThemeChangesOnlyCurrentAppearanceSideWhenSwitchingIsOn() {
        var settings = AppEditorSettings()
        settings.editorTheme = .paper
        settings.editorThemeFollowsAppearance = true
        settings.selectTheme(.preset(.dracula), for: .editor, appearance: .dark)
        XCTAssertEqual(settings.editorDarkTheme, .preset(.dracula))
        XCTAssertNil(settings.editorLightTheme)
        XCTAssertEqual(settings.editorTheme, .paper, "固定の配色は変えない")

        settings.selectTheme(.preset(.tomorrow), for: .editor, appearance: .light)
        XCTAssertEqual(settings.editorLightTheme, .preset(.tomorrow))
        XCTAssertEqual(settings.editorDarkTheme, .preset(.dracula))
        XCTAssertEqual(settings.editorTheme, .paper)
        XCTAssertNil(settings.previewTheme, "プレビューの配色は変えない")
        XCTAssertNil(settings.previewLightTheme)
        XCTAssertNil(settings.previewDarkTheme)
    }

    func testSelectThemeChangesFixedThemeWhenSwitchingIsOff() {
        var settings = AppEditorSettings()
        settings.selectTheme(.preset(.nord), for: .preview, appearance: .dark)
        XCTAssertEqual(settings.previewTheme, .preset(.nord))
        XCTAssertNil(settings.previewLightTheme)
        XCTAssertNil(settings.previewDarkTheme)
        settings.selectTheme(.paper, for: .editor, appearance: .light)
        XCTAssertEqual(settings.editorTheme, .paper)
        XCTAssertNil(settings.editorLightTheme)
    }

    // MARK: - 保存

    func testSwitchingSettingsPersistAndLegacySettingsLeaveThemUnset() throws {
        let legacy = try JSONDecoder().decode(AppEditorSettings.self, from: Data(
            "{\"defaultMode\":\"split\",\"fontSize\":13,\"lineSpacing\":3,\"wrapsLines\":true,\"previewTheme\":\"paper\"}".utf8))
        XCTAssertNil(legacy.editorThemeFollowsAppearance)
        XCTAssertNil(legacy.editorLightTheme)
        XCTAssertNil(legacy.editorDarkTheme)
        XCTAssertNil(legacy.previewThemeFollowsAppearance)
        XCTAssertNil(legacy.previewLightTheme)
        XCTAssertNil(legacy.previewDarkTheme)
        XCTAssertEqual(legacy.theme(for: .preview, appearance: .dark), .paper)

        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false, appearance: .light)
        var settings = store.app
        settings.editorThemeFollowsAppearance = true
        settings.editorLightTheme = .paper
        settings.editorDarkTheme = .navy
        settings.previewThemeFollowsAppearance = true
        settings.previewLightTheme = .preset(.tomorrow)
        settings.previewDarkTheme = .preset(.tomorrowNight)
        store.setAppSettings(settings)
        let reopened = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false, appearance: .dark)
        XCTAssertEqual(reopened.app, settings)
        XCTAssertEqual(reopened.editorTheme, .navy)
        XCTAssertEqual(reopened.previewTheme, .preset(.tomorrowNight))
    }

    // MARK: - カスタムテーマの入れ替えと削除

    func testExtensionThemeReplacementAndRemovalCoverLightAndDarkSelections() throws {
        let theme = PreviewThemePreset.nord.theme
        var package = try package(theme: theme)
        var settings = AppEditorSettings()
        settings.installExtension(package)
        for target in ThemeTarget.allCases {
            for slot in ThemeSlot.allCases {
                settings[keyPath: target.keyPath(for: slot)] = .extensionTheme(theme)
            }
        }

        // 同じ id で読み込み直すと、ライト用・ダーク用の選択も新しいテーマに移る。
        var updated = theme
        updated.name = "Example 2"
        package.theme = updated
        settings.installExtension(package)
        for target in ThemeTarget.allCases {
            for slot in ThemeSlot.allCases {
                XCTAssertEqual(settings[keyPath: target.keyPath(for: slot)], .extensionTheme(updated), "\(target) \(slot)")
            }
        }

        // 削除すると未設定（既定）に戻る。プレビューの固定の配色は従来どおり「システム」に戻す。
        settings.removeExtension("example.theme")
        XCTAssertNil(settings.editorTheme)
        XCTAssertNil(settings.editorLightTheme)
        XCTAssertNil(settings.editorDarkTheme)
        XCTAssertEqual(settings.previewTheme, .system)
        XCTAssertNil(settings.previewLightTheme)
        XCTAssertNil(settings.previewDarkTheme)
        settings.editorThemeFollowsAppearance = true
        XCTAssertEqual(settings.theme(for: .editor, appearance: .dark), .navy)
    }

    func testRemovingOtherExtensionKeepsLightAndDarkSelections() throws {
        let selected = try package(id: "selected", theme: PreviewThemePreset.nord.theme)
        var other = PreviewThemePreset.dracula.theme
        other.name = "Other"
        let unrelated = try package(id: "other", theme: other)
        var settings = AppEditorSettings()
        settings.installExtension(selected)
        settings.installExtension(unrelated)
        settings.editorDarkTheme = .extensionTheme(PreviewThemePreset.nord.theme)
        settings.previewLightTheme = .extensionTheme(PreviewThemePreset.nord.theme)
        settings.removeExtension("other")
        XCTAssertEqual(settings.editorDarkTheme, .extensionTheme(PreviewThemePreset.nord.theme))
        XCTAssertEqual(settings.previewLightTheme, .extensionTheme(PreviewThemePreset.nord.theme))
    }

    // MARK: - ストア

    func testAppearanceChangePublishesOnceAndChangesResolvedThemes() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false, appearance: .light)
        var settings = store.app
        settings.editorThemeFollowsAppearance = true
        settings.previewThemeFollowsAppearance = true
        store.setAppSettings(settings)
        XCTAssertEqual(store.editorTheme, .preset(.githubLight))
        XCTAssertEqual(store.previewTheme, .preset(.githubLight))

        var notifications = 0
        let subscription = store.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel() }
        store.updateAppearance(.dark)
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(store.appearance, .dark)
        XCTAssertEqual(store.editorTheme, .navy)
        XCTAssertEqual(store.previewTheme, .preset(.githubDark))

        // 明暗が同じなら通知しない。
        store.updateAppearance(.dark)
        XCTAssertEqual(notifications, 1)
        store.updateAppearance(.light)
        XCTAssertEqual(notifications, 2)
        XCTAssertEqual(store.editorTheme, .preset(.githubLight))
    }

    func testStoreSelectThemeUsesCurrentAppearance() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false, appearance: .dark)
        store.selectTheme(.preset(.nord), for: .editor)
        XCTAssertEqual(store.app.editorTheme, .preset(.nord), "切り替えがオフなら固定の配色を変える")

        var settings = store.app
        settings.editorThemeFollowsAppearance = true
        store.setAppSettings(settings)
        store.selectTheme(.preset(.dracula), for: .editor)
        XCTAssertEqual(store.app.editorDarkTheme, .preset(.dracula))
        XCTAssertNil(store.app.editorLightTheme)
        XCTAssertEqual(store.app.editorTheme, .preset(.nord))
        XCTAssertEqual(store.editorTheme, .preset(.dracula))
        XCTAssertEqual(EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false, appearance: .dark)
            .app.editorDarkTheme, .preset(.dracula))
    }

    /// アプリの外観（`NSApp.appearance`）を変えると、KVOで監視しているストアの外観が変わる。
    func testApplicationAppearanceChangeUpdatesStoreThroughKeyValueObservation() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let application = NSApplication.shared
        let original = application.appearance
        defer { application.appearance = original }
        let store = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false)

        for (name, expected) in [(NSAppearance.Name.darkAqua, InterfaceAppearance.dark), (.aqua, .light),
                                 (.darkAqua, .dark)] {
            application.appearance = NSAppearance(named: name)
            let deadline = Date().addingTimeInterval(2)
            while store.appearance != expected, Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(store.appearance, expected, name.rawValue)
        }
    }
}
