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
}
