import SwiftUI

struct EditorPreferencesView: View {
    @ObservedObject var settingsStore: EditorSettingsStore

    var body: some View {
        Form {
            Picker("フォント", selection: binding(\.fontChoice, default: .monospacedSystem)) {
                ForEach(EditorFontChoice.allCases, id: \.self) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            Stepper(value: binding(\.fontSize), in: 10...32, step: 1) {
                Text("文字サイズ: \(Int(settingsStore.app.fontSize)) pt")
            }
            Stepper(value: binding(\.lineSpacing), in: 0...12, step: 1) {
                Text("行間: \(Int(settingsStore.app.lineSpacing)) pt")
            }
            Stepper(value: binding(\.horizontalMargin, default: 18), in: 8...48, step: 2) {
                Text("左右の余白: \(Int(settingsStore.app.horizontalMargin ?? 18)) pt")
            }
            Stepper(value: binding(\.verticalMargin, default: 18), in: 8...48, step: 2) {
                Text("上下の余白: \(Int(settingsStore.app.verticalMargin ?? 18)) pt")
            }
            Toggle("行を折り返す", isOn: binding(\.wrapsLines))
            Stepper(value: binding(\.tabWidth, default: 4), in: 2...8) {
                Text("タブ幅: \(settingsStore.app.tabWidth ?? 4) 文字")
            }
            Stepper(value: binding(\.listIndentWidth, default: 2), in: 2...8) {
                Text("リストの字下げ: \(settingsStore.app.listIndentWidth ?? 2) 文字")
            }
            Stepper(value: binding(\.codeIndentWidth, default: 4), in: 2...8) {
                Text("コードの字下げ: \(settingsStore.app.codeIndentWidth ?? 4) 文字")
            }
            Toggle("表の最後でTabを押したら行を追加", isOn: binding(\.tableAddsRowOnTab, default: true))
            Section("校正") {
                Picker("スペルチェックの言語", selection: proofingBinding(\.language)) {
                    ForEach(ProofingLanguage.allCases, id: \.self) { language in
                        Text(language.title).tag(language)
                    }
                }
                Toggle("スペルチェック", isOn: proofingBinding(\.checksSpelling))
                Toggle("自動訂正", isOn: proofingBinding(\.correctsSpelling))
                Text("コードとURLでは自動訂正を一時停止します。ユーザー辞書にはmacOSの標準機能を使います。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 430)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppEditorSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settingsStore.app[keyPath: keyPath] },
            set: { value in
                var settings = settingsStore.app
                settings[keyPath: keyPath] = value
                settingsStore.setAppSettings(settings)
            }
        )
    }

    private func binding<Value>(
        _ keyPath: WritableKeyPath<AppEditorSettings, Value?>,
        default defaultValue: Value
    ) -> Binding<Value> {
        Binding(
            get: { settingsStore.app[keyPath: keyPath] ?? defaultValue },
            set: { value in
                var settings = settingsStore.app
                settings[keyPath: keyPath] = value
                settingsStore.setAppSettings(settings)
            }
        )
    }

    private func proofingBinding<Value>(_ keyPath: WritableKeyPath<EditorProofingSettings, Value>) -> Binding<Value> {
        Binding(get: { (settingsStore.app.proofing ?? EditorProofingSettings())[keyPath: keyPath] },
                set: { value in
                    var settings = settingsStore.app
                    var proofing = settings.proofing ?? EditorProofingSettings()
                    proofing[keyPath: keyPath] = value
                    settings.proofing = proofing
                    settingsStore.setAppSettings(settings)
                })
    }
}
