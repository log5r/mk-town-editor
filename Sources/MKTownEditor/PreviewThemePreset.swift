import AppKit
import SwiftUI

/// 標準装備のプレビュー配色。JSON拡張のテーマと同じ形（`DeclarativeExtension.Theme`）で定義する。
///
/// 色は各配色の公開パレットに基づく。本文・見出し・リンクは背景に対して、コードと字句の色はコード背景に対して
/// 4.5:1 以上のコントラストを保つよう、足りない色だけ明度を補正している（`PreviewThemePresetTests`）。
/// 出典とライセンスは docs/preview-themes.md と docs/third-party-licenses.md を参照。
enum PreviewThemePreset: String, CaseIterable, Codable, Hashable, Sendable {
    case githubLight = "github-light"
    case githubDark = "github-dark"
    case tomorrow
    case tomorrowNight = "tomorrow-night"
    case dracula
    case nord

    var theme: DeclarativeExtension.Theme { Self.themes[self]! }

    /// 選択肢に表示する名前。GitHubの配色は同社の製品ではないため「風」を付ける。
    var title: String {
        switch self {
        case .githubLight: String(localized: "GitHub風（ライト）")
        case .githubDark: String(localized: "GitHub風（ダーク）")
        default: theme.name
        }
    }

    private static let themes: [Self: DeclarativeExtension.Theme] = [
        .githubLight: .init(
            name: "GitHub Light", background: "#FFFFFF", body: "#1F2328", heading: "#1F2328",
            code: "#1F2328", link: "#0969DA", codeBackground: "#F6F8FA",
            syntax: ["keyword": "#CF222E", "type": "#6639BA", "string": "#0A3069", "comment": "#59636E",
                     "number": "#0550AE", "attribute": "#0550AE", "variable": "#953800",
                     "inserted": "#116329", "deleted": "#82071E"]),
        .githubDark: .init(
            name: "GitHub Dark", background: "#0D1117", body: "#F0F6FC", heading: "#F0F6FC",
            code: "#F0F6FC", link: "#4493F8", codeBackground: "#151B23",
            syntax: ["keyword": "#FF7B72", "type": "#D2A8FF", "string": "#A5D6FF", "comment": "#9198A1",
                     "number": "#79C0FF", "attribute": "#7EE787", "variable": "#FFA657",
                     "inserted": "#AFF5B4", "deleted": "#FFDCD7"]),
        .tomorrow: .init(
            name: "Tomorrow", background: "#FFFFFF", body: "#4D4D4C", heading: "#4D4D4C",
            code: "#4D4D4C", link: "#4271AE", codeBackground: "#EFEFEF",
            syntax: ["keyword": "#8858A6", "type": "#3F6CA7", "string": "#5E7400", "comment": "#6A6C69",
                     "number": "#A25914", "attribute": "#30767A", "variable": "#C82829",
                     "inserted": "#5E7400", "deleted": "#C82829"]),
        .tomorrowNight: .init(
            name: "Tomorrow Night", background: "#1D1F21", body: "#C5C8C6", heading: "#C5C8C6",
            code: "#C5C8C6", link: "#81A2BE", codeBackground: "#282A2E",
            syntax: ["keyword": "#B294BB", "type": "#F0C674", "string": "#B5BD68", "comment": "#969896",
                     "number": "#DE935F", "attribute": "#8ABEB7", "variable": "#D27878",
                     "inserted": "#B5BD68", "deleted": "#D27878"]),
        .dracula: .init(
            name: "Dracula", background: "#282A36", body: "#F8F8F2", heading: "#BD93F9",
            code: "#F8F8F2", link: "#8BE9FD", codeBackground: "#21222C",
            syntax: ["keyword": "#FF79C6", "type": "#8BE9FD", "string": "#F1FA8C", "comment": "#7B89B3",
                     "number": "#BD93F9", "attribute": "#50FA7B", "variable": "#FFB86C",
                     "inserted": "#50FA7B", "deleted": "#FF5555"]),
        .nord: .init(
            name: "Nord", background: "#2E3440", body: "#D8DEE9", heading: "#88C0D0",
            code: "#D8DEE9", link: "#88C0D0", codeBackground: "#272C36",
            syntax: ["keyword": "#81A1C1", "type": "#8FBCBB", "string": "#A3BE8C", "comment": "#8A94A7",
                     "number": "#B48EAD", "attribute": "#D08770", "variable": "#D8DEE9",
                     "inserted": "#A3BE8C", "deleted": "#CB7F86"])
    ]
}

extension PreviewTheme {
    /// 「システム」のプレビューの背景。macOSの外観に合わせて、GitHub風のライトかダークの背景にする。
    static let systemPreviewBackground = systemPreviewColor(\.background)
    /// 「システム」のプレビューで行内コードに敷く色。背景と同じくGitHub風のコード背景にする。
    static let systemPreviewCodeBackground = systemPreviewColor(\.codeBackground)

    /// プレビューの背景。文字色などは「システム」ではmacOSの色のままにする。
    var previewBackground: NSColor? { self == .system ? Self.systemPreviewBackground : background }

    private static func systemPreviewColor(_ keyPath: KeyPath<DeclarativeExtension.Theme, String> & Sendable) -> NSColor {
        let light = PreviewThemePreset.githubLight.theme.color(keyPath) ?? .textBackgroundColor
        let dark = PreviewThemePreset.githubDark.theme.color(keyPath) ?? .textBackgroundColor
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

extension AppEditorSettings {
    /// 読み込み済みのJSON拡張が持つテーマ。同じ内容のテーマは1つにまとめる。
    var customPreviewThemes: [PreviewTheme] {
        var seen = Set<PreviewTheme>()
        return (extensionPackages ?? []).compactMap { $0.theme.map(PreviewTheme.extensionTheme) }
            .filter { seen.insert($0).inserted }
    }

    /// 配色の設定と、選んでいた拡張のテーマがなくなったときに戻す値。
    /// プレビューの固定の配色は「システム」、ほかは未設定（それぞれの既定）に戻す。
    private static var themeSelections: [(WritableKeyPath<AppEditorSettings, PreviewTheme?>, PreviewTheme?)] {
        ThemeTarget.allCases.flatMap { target in
            ThemeSlot.allCases.map { slot in
                (target.keyPath(for: slot), target == .preview && slot == .fixed ? target.defaultTheme(for: slot) : nil)
            }
        }
    }

    /// 拡張を追加する。同じ `id` の拡張は置き換え、そのテーマを選んでいた配色は新しいテーマに移す。
    /// `target` を指定すると、拡張のテーマをその配色に選ぶ。
    mutating func installExtension(_ package: DeclarativeExtension,
                                   selectingThemeFor target: WritableKeyPath<AppEditorSettings, PreviewTheme?>? = nil) {
        if let previousTheme = extensionPackages?.first(where: { $0.id == package.id })?.theme {
            for (keyPath, fallback) in Self.themeSelections
            where self[keyPath: keyPath] == .extensionTheme(previousTheme) {
                self[keyPath: keyPath] = package.theme.map(PreviewTheme.extensionTheme) ?? fallback
            }
        }
        extensionPackages = (extensionPackages ?? []).filter { $0.id != package.id } + [package]
        if let target, let theme = package.theme { self[keyPath: target] = .extensionTheme(theme) }
    }

    /// 拡張を削除する。そのテーマを選んでいた配色は既定に戻す。
    mutating func removeExtension(_ id: String) {
        for (keyPath, fallback) in Self.themeSelections {
            if case .extensionTheme(let selected) = self[keyPath: keyPath],
               extensionPackages?.contains(where: { $0.id == id && $0.theme == selected }) == true {
                self[keyPath: keyPath] = fallback
            }
        }
        extensionPackages?.removeAll { $0.id == id }
    }
}

/// 配色の選択肢。設定の「配色」（エディタとプレビュー）と表示メニューの「エディタの配色」「プレビューの配色」で共有する。
/// 基本の配色（`ThemeTarget.basicThemes`）、標準装備の配色、読み込んだカスタムテーマの順に区切って並べる。
struct PreviewThemeOptions: View {
    let target: ThemeTarget
    let customThemes: [PreviewTheme]

    static let presetThemes = PreviewThemePreset.allCases.map(PreviewTheme.preset)

    var body: some View {
        ForEach(target.basicThemes, id: \.self) { Text($0.title).tag($0) }
        Divider()
        ForEach(Self.presetThemes, id: \.self) { Text($0.title).tag($0) }
        if !customThemes.isEmpty {
            Divider()
            ForEach(customThemes, id: \.self) { Text($0.title).tag($0) }
        }
    }
}
