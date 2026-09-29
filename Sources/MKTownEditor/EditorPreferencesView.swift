import SwiftUI

struct EditorPreferencesView: View {
    @ObservedObject var settingsStore: EditorSettingsStore
    @State private var showingShortcuts = false

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
            Toggle("空白・タブ・改行を表示", isOn: binding(\.showsInvisibleCharacters, default: false))
            Toggle("インデントガイドを表示", isOn: binding(\.showsIndentGuides, default: false))
            Toggle("ミニマップを表示", isOn: binding(\.showsMinimap, default: false))
            Toggle("編集中以外のMarkdown記号を控えめに表示", isOn: binding(\.usesInlineLivePresentation, default: false))
            Toggle("タイプライターモード", isOn: binding(\.usesTypewriterMode, default: false))
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
            Toggle("プレビューにフロントマターを表示", isOn: binding(\.showsFrontMatterInPreview, default: false))
            Toggle("リモート画像を読み込む", isOn: binding(\.loadsRemoteImages, default: false))
            Toggle("外部リンクのホバー時にページ情報を取得", isOn: binding(\.loadsExternalLinkPreviews, default: false))
            Section("プレビュー") {
                Picker("配色", selection: binding(\.previewTheme, default: .system)) {
                    ForEach(PreviewTheme.allCases, id: \.self) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                Stepper(value: binding(\.previewBodyWidth, default: 900), in: 560...1200, step: 40) {
                    Text("本文の最大幅: \(settingsStore.app.previewBodyWidth ?? 900) pt")
                }
            }
            Picker("添付ファイルの保存先", selection: binding(\.attachmentDirectory, default: .assets)) {
                ForEach(AttachmentDirectory.allCases, id: \.self) { directory in
                    Text(directory.title).tag(directory)
                }
            }
            Picker("Markdown構文", selection: binding(\.markdownDialect, default: .extended)) {
                ForEach(MarkdownDialect.allCases, id: \.self) { dialect in
                    Text(dialect.title).tag(dialect)
                }
            }
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
            Section("キーボード") {
                Button("ショートカット一覧と設定…") { showingShortcuts = true }
            }
            Section("スニペット") {
                ForEach(settingsStore.app.snippets ?? []) { snippet in
                    VStack(alignment: .leading) {
                        HStack {
                            TextField("短縮語", text: snippetBinding(snippet.id, \.trigger))
                            Button("削除", role: .destructive) { removeSnippet(snippet.id) }
                        }
                        TextEditor(text: snippetBinding(snippet.id, \.template))
                            .frame(height: 64)
                            .accessibilityLabel("\(snippet.trigger) のテンプレート")
                    }
                }
                Button("スニペットを追加") {
                    var settings = settingsStore.app
                    settings.snippets = (settings.snippets ?? []) +
                        [EditorSnippet(trigger: "", template: "${1:入力}$0")]
                    settingsStore.setAppSettings(settings)
                }
                Text("${1:文字}、${2:文字}をTabで順に選択し、$0を最後のカーソル位置にします。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 430)
        .sheet(isPresented: $showingShortcuts) {
            EditorShortcutPreferencesView(settingsStore: settingsStore)
        }
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

    private func snippetBinding(_ id: UUID, _ keyPath: WritableKeyPath<EditorSnippet, String>) -> Binding<String> {
        Binding(get: {
            (settingsStore.app.snippets ?? []).first(where: { $0.id == id })?[keyPath: keyPath] ?? ""
        }, set: { value in
            var settings = settingsStore.app
            guard let index = settings.snippets?.firstIndex(where: { $0.id == id }) else { return }
            settings.snippets?[index][keyPath: keyPath] = value
            settingsStore.setAppSettings(settings)
        })
    }

    private func removeSnippet(_ id: UUID) {
        var settings = settingsStore.app
        settings.snippets?.removeAll { $0.id == id }
        settingsStore.setAppSettings(settings)
    }
}

struct FolderEditorSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settingsStore: EditorSettingsStore
    let folderURL: URL

    private var folder: FolderEditorSettings { settingsStore.folderSettings(for: folderURL) }

    var body: some View {
        Form {
            Text(folderURL.path).font(.caption).textSelection(.enabled)
            Text("フォルダの設定はアプリ設定より優先されます。未指定の項目は親フォルダ、次にアプリ設定を使います。")
                .font(.caption).foregroundStyle(.secondary)
            widthRow(String(localized: "タブ幅"), keyPath: \.tabWidth,
                     inherited: settingsStore.textStyle(for: folderURL.appendingPathComponent("sample.md")).tabWidth)
            widthRow(String(localized: "リストの字下げ"), keyPath: \.listIndentWidth,
                     inherited: settingsStore.layoutOptions(for: folderURL.appendingPathComponent("sample.md")).listIndentWidth)
            widthRow(String(localized: "コードの字下げ"), keyPath: \.codeIndentWidth,
                     inherited: settingsStore.layoutOptions(for: folderURL.appendingPathComponent("sample.md")).codeIndentWidth)
            Picker("添付ファイルの保存先", selection: optionalBinding(\.attachmentDirectory)) {
                Text("継承").tag(nil as AttachmentDirectory?)
                ForEach(AttachmentDirectory.allCases, id: \.self) { directory in
                    Text(directory.title).tag(Optional(directory))
                }
            }
            Picker("Markdown構文", selection: optionalBinding(\.markdownDialect)) {
                Text("継承").tag(nil as MarkdownDialect?)
                ForEach(MarkdownDialect.allCases, id: \.self) { dialect in
                    Text(dialect.title).tag(Optional(dialect))
                }
            }
            Text("現在の文書に適用: 保存先 \(settingsStore.attachmentDirectory(for: folderURL.appendingPathComponent("sample.md")).title)、構文 \(settingsStore.markdownDialect(for: folderURL.appendingPathComponent("sample.md")).title)")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .formStyle(.grouped)
        .frame(width: 500)
    }

    private func widthRow(_ title: String,
                          keyPath: WritableKeyPath<FolderEditorSettings, Int?>,
                          inherited: Int) -> some View {
        HStack {
            Stepper(value: Binding(
                get: { folder[keyPath: keyPath] ?? inherited },
                set: { value in update { $0[keyPath: keyPath] = value } }
            ), in: 2...8) {
                Text("\(title): \(folder[keyPath: keyPath] ?? inherited) 文字")
            }
            Button("継承") { update { $0[keyPath: keyPath] = nil } }
                .disabled(folder[keyPath: keyPath] == nil)
        }
    }

    private func optionalBinding<Value>(
        _ keyPath: WritableKeyPath<FolderEditorSettings, Value?>
    ) -> Binding<Value?> {
        Binding(get: { folder[keyPath: keyPath] },
                set: { value in update { $0[keyPath: keyPath] = value } })
    }

    private func update(_ change: (inout FolderEditorSettings) -> Void) {
        var value = folder
        change(&value)
        settingsStore.setFolderSettings(value, for: folderURL)
    }
}

struct SnippetPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let snippets: [EditorSnippet]
    let onSelect: (EditorSnippet) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("スニペットを挿入").font(.headline)
            List(snippets) { snippet in
                Button {
                    onSelect(snippet)
                    dismiss()
                } label: {
                    VStack(alignment: .leading) {
                        Text(snippet.trigger.isEmpty ? "定型文" : snippet.trigger)
                        Text(snippet.template).lineLimit(2).font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(snippet.template.isEmpty)
            }
            Button("キャンセル") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
        .frame(width: 420, height: 320)
    }
}

struct CommandPaletteView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settingsStore: EditorSettingsStore
    @ObservedObject var model: MarkdownEditorModel
    @State private var query = ""

    private var matches: [EditorCommand] {
        EditorCommand.paletteMatches(query, in: model,
            shortcutLabel: { settingsStore.shortcut(for: $0)?.label })
    }

    var body: some View {
        VStack(spacing: 10) {
            TextField("コマンド名またはショートカット", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if let first = matches.first { execute(first) } }
            List(matches, id: \.self) { command in
                Button { execute(command) } label: {
                    HStack {
                        Label(command.title, systemImage: command.symbolName)
                        Spacer()
                        if let shortcut = settingsStore.shortcut(for: command)?.label {
                            Text(shortcut).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if matches.isEmpty {
                ContentUnavailableView.search(text: query)
            }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 500, height: 420)
    }

    private func execute(_ command: EditorCommand) {
        dismiss()
        model.showingCommandPalette = false
        command.perform(on: model)
    }
}
