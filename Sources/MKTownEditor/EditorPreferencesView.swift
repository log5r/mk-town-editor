import AppKit
import SwiftUI

struct EditorPreferencesView: View {
    @ObservedObject var settingsStore: EditorSettingsStore
    @State private var extensionError: String?
    /// エディタのフォントの候補。エディタの設定を開いたときと、フォントの追加・削除の通知で読み直す。
    @State private var installedFontFamilies: [EditorFontFamily] = []
    @AppStorage("graphvizRendererPath") private var graphvizPath = ""
    @AppStorage("plantUMLJarPath") private var plantUMLPath = ""

    /// The Settings window follows the macOS convention: a toolbar tab per area and controls
    /// that take effect as soon as they change, with no Save button (#52).
    enum Pane: String, CaseIterable {
        case general, editor, preview, proofing, snippets, extensions, keyboard

        var title: String {
            switch self {
            case .general: String(localized: "一般")
            case .editor: String(localized: "エディタ")
            case .preview: String(localized: "プレビュー")
            case .proofing: String(localized: "校正")
            case .snippets: String(localized: "スニペット")
            case .extensions: String(localized: "拡張")
            case .keyboard: String(localized: "キーボード")
            }
        }

        var symbolName: String {
            switch self {
            case .general: "gearshape"
            case .editor: "square.and.pencil"
            case .preview: "eye"
            case .proofing: "textformat.abc.dottedunderline"
            case .snippets: "text.insert"
            case .extensions: "puzzlepiece.extension"
            case .keyboard: "keyboard"
            }
        }
    }

    @AppStorage("settingsPane") private var selectedPane = Pane.general

    var body: some View {
        TabView(selection: $selectedPane) {
            ForEach(Pane.allCases, id: \.self) { pane in
                paneContent(pane)
                    .tabItem { Label(pane.title, systemImage: pane.symbolName) }
                    .tag(pane)
            }
        }
        .frame(width: 600, height: 520)
        .alert("拡張を読み込めません", isPresented: Binding(get: { extensionError != nil },
            set: { if !$0 { extensionError = nil } })) {
            Button("OK") { extensionError = nil }
        } message: { Text(extensionError ?? "") }
    }

    @ViewBuilder
    private func paneContent(_ pane: Pane) -> some View {
        switch pane {
        case .general: generalPane
        case .editor: editorPane
        case .preview: previewPane
        case .proofing: proofingPane
        case .snippets: snippetsPane
        case .extensions: extensionsPane
        case .keyboard:
            EditorShortcutPreferencesView(settingsStore: settingsStore)
                .padding(20)
        }
    }

    private var generalPane: some View {
        Form {
            Section("書類") {
                Picker("書類を開いたときの表示", selection: binding(\.documentOpeningMode, default: .default)) {
                    ForEach(DocumentOpeningMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
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
                Toggle("改行コードが混在する書類を開くときに確認", isOn: binding(\.asksAboutMixedNewlines, default: true))
                if settingsStore.hasSuppressedMixedNewlinePrompts {
                    Button("確認を省略した書類でも再び確認する") { settingsStore.resetMixedNewlinePrompts() }
                        .disabled(settingsStore.app.asksAboutMixedNewlines == false)
                }
            }
            Section("文字コードの自動判別") {
                let enabled = settingsStore.encodingCandidates
                let disabled = MarkdownTextEncoding.allCases.filter { !enabled.contains($0) }
                ForEach(enabled + disabled) { encoding in
                    HStack {
                        Toggle(encoding.title, isOn: Binding(
                            get: { enabled.contains(encoding) },
                            set: { settingsStore.setDetectionEnabled($0, for: encoding) }))
                            .toggleStyle(.checkbox)
                        Spacer()
                        if let index = enabled.firstIndex(of: encoding) {
                            Button { settingsStore.moveEncodingCandidate(encoding, by: -1) } label: {
                                Image(systemName: "chevron.up")
                            }
                            .accessibilityLabel("\(encoding.title)の優先順位を上げる")
                            .disabled(index == 0)
                            Button { settingsStore.moveEncodingCandidate(encoding, by: 1) } label: {
                                Image(systemName: "chevron.down")
                            }
                            .accessibilityLabel("\(encoding.title)の優先順位を下げる")
                            .disabled(index == enabled.count - 1)
                        }
                    }
                }
                Text("BOMや文字コードの宣言がない場合に使う候補です。複数の候補で読めるときは上の候補を優先します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("ネットワーク") {
                Toggle("リモート画像を読み込む", isOn: binding(\.loadsRemoteImages, default: false))
                Toggle("外部リンクのホバー時にページ情報を取得", isOn: binding(\.loadsExternalLinkPreviews, default: false))
            }
        }
        .formStyle(.grouped)
    }

    private var editorPane: some View {
        Form {
            Section("文字") {
                fontControls
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
            Section("表示") {
                themeControls(for: .editor)
                Text("既定は紺色です。外観に合わせて切り替えると、macOSのライトとダークの外観でそれぞれ選んだ配色を使います。ほかのテーマはプレビューと共通で、追加したテーマは「拡張」で削除できます。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("行番号を表示", isOn: binding(\.showsLineNumbers, default: true))
                Toggle("行を折り返す", isOn: binding(\.wrapsLines))
                Toggle("空白・タブ・改行を表示", isOn: binding(\.showsInvisibleCharacters, default: false))
                Toggle("インデントガイドを表示", isOn: binding(\.showsIndentGuides, default: false))
                Toggle("ミニマップを表示", isOn: binding(\.showsMinimap, default: false))
                Toggle("編集中以外のMarkdown記号を控えめに表示", isOn: binding(\.usesInlineLivePresentation, default: false))
                Toggle("タイプライターモード", isOn: binding(\.usesTypewriterMode, default: false))
            }
            Section("字下げと表") {
                Picker("字下げに使う文字", selection: binding(\.indentationStyle, default: .spaces)) {
                    ForEach(EditorIndentationStyle.allCases, id: \.self) { style in
                        Text(style.title).tag(style)
                    }
                }
                Toggle("書類の字下げを自動検出", isOn: binding(\.detectsIndentation, default: false))
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
            }
            Section("行末の空白") {
                Toggle("保存時に行末の空白を削除", isOn: binding(\.trimsTrailingWhitespaceOnSave, default: false))
                Toggle("空白だけの行も対象にする", isOn: binding(\.trimsWhitespaceOnlyLines, default: false))
                Text("Markdownの改行とコードブロック内の空白は保持します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var previewPane: some View {
        Form {
            Section("表示") {
                themeControls(for: .preview)
                Text("「システム」は切り替えをオフにしていても、macOSの外観に合わせて明るさが変わります。外観に合わせて切り替えると、ライトとダークの外観でそれぞれ選んだ配色を使います。JSONファイルで配色を追加でき、追加したテーマは「拡張」で削除できます。")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper(value: binding(\.previewBodyWidth, default: 900), in: 560...1200, step: 40) {
                    Text("本文の最大幅: \(settingsStore.app.previewBodyWidth ?? 900) pt")
                }
            }
            Section("Markdownの解釈") {
                Toggle("本文の改行をそのまま表示", isOn: binding(\.preservesSoftLineBreaksInPreview, default: false))
                Text("オンにすると、段落内の改行1つもプレビューで改行します。オフにすると空白として表示します。原文と書き出しには影響しません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("フロントマター") {
                Toggle("プレビューにフロントマターを表示", isOn: binding(\.showsFrontMatterInPreview, default: false))
                Toggle("Obsidianのプロパティを整形して表示", isOn: binding(\.formatsFrontMatterInPreview, default: false))
                    .disabled(!(settingsStore.app.showsFrontMatterInPreview ?? false))
                Text("先頭のYAMLを項目ごとに小さな文字で表示します。オフにするとYAMLをそのまま表示します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("外部の図描画器") {
                HStack {
                    TextField("Graphviz dot の実行ファイル", text: $graphvizPath)
                    Button("選択…") { chooseDiagramTool(for: .graphviz) }
                }
                Text(graphvizStatus)
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("PlantUML の JAR ファイル", text: $plantUMLPath)
                    Button("選択…") { chooseDiagramTool(for: .plantuml) }
                }
                Text(plantUMLStatus)
                    .font(.caption).foregroundStyle(.secondary)
                Text("使用する描画器だけを指定してください。PlantUMLにはJavaが必要です。図の本文は外部サーバーへ送信しません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var proofingPane: some View {
        Form {
            Section("スペルチェック") {
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
            Section("用語辞書") {
                Toggle("コード内を除外", isOn: terminologyOptionBinding(\.excludesCode))
                Toggle("引用内を除外", isOn: terminologyOptionBinding(\.excludesQuotes))
                ForEach(settingsStore.app.terminologyEntries ?? []) { entry in
                    HStack {
                        TextField("避ける表記", text: terminologyBinding(entry.id, \.prohibited))
                        Text("→")
                        TextField("推奨表記", text: terminologyBinding(entry.id, \.preferred))
                        Button { moveTerminology(entry.id, by: -1) } label: {
                            Image(systemName: "arrow.up")
                        }
                        .accessibilityLabel("優先順を上げる")
                        .disabled(terminologyIndex(entry.id) == 0)
                        Button { moveTerminology(entry.id, by: 1) } label: {
                            Image(systemName: "arrow.down")
                        }
                        .accessibilityLabel("優先順を下げる")
                        .disabled(terminologyIndex(entry.id) >=
                                  (settingsStore.app.terminologyEntries?.count ?? 0) - 1)
                        Button(role: .destructive) { removeTerminology(entry.id) } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("用語を削除")
                    }
                }
                Button("用語を追加") {
                    var settings = settingsStore.app
                    settings.terminologyEntries = (settings.terminologyEntries ?? []) +
                        [TerminologyEntry(prohibited: "", preferred: "")]
                    settingsStore.setAppSettings(settings)
                }
                Text("上の項目を優先して照合します。空欄の項目は照合しません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var snippetsPane: some View {
        Form {
            Section {
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
            } footer: {
                Text("${1:文字}、${2:文字}をTabで順に選択し、$0を最後のカーソル位置にします。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var extensionsPane: some View {
        Form {
            Section {
                ForEach(settingsStore.app.extensionPackages ?? []) { package in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(package.name)
                            Text("テーマ \(package.theme == nil ? 0 : 1)・スニペット \(package.snippets.count)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("削除", role: .destructive) { removeExtension(package.id) }
                    }
                }
                Button("JSON拡張を読み込む…") { importExtension() }
            } footer: {
                Text("宣言的なテーマとスニペットのみを読み込みます。コードは実行しません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// エディタのフォント。ほかの設定と同じポップアップボタンで、標準装備・等幅・その他の順に並べる。
    /// フォントパネルを使わない理由は docs/editor-font-selection.md を参照。
    @ViewBuilder
    private var fontControls: some View {
        let selected = settingsStore.app.editorFont
        let options = EditorFontOptions(installed: installedFontFamilies, selected: selected)
        Picker("フォント", selection: binding(\.editorFont)) {
            Section("標準") {
                ForEach(EditorFontChoice.allCases, id: \.self) { choice in
                    Text(choice.title).tag(EditorFont.builtIn(choice))
                }
            }
            if let unlisted = options.unlistedFamily {
                // 保存したフォントが見つからないときも選択中の項目を出し、ポップアップを空欄にしない。
                Group {
                    if options.isMissing {
                        Text("\(unlisted)（見つかりません）")
                    } else {
                        Text(verbatim: selected.title)
                    }
                }
                .tag(EditorFont.family(unlisted))
            }
            if !options.monospaced.isEmpty {
                Section("等幅フォント") {
                    ForEach(options.monospaced, id: \.name) { family in
                        Text(family.displayName).tag(EditorFont.family(family.name))
                    }
                }
            }
            if !options.proportional.isEmpty {
                Section("その他のフォント") {
                    ForEach(options.proportional, id: \.name) { family in
                        Text(family.displayName).tag(EditorFont.family(family.name))
                    }
                }
            }
        }
        .onAppear { reloadInstalledFontFamilies() }
        .onReceive(NotificationCenter.default.publisher(for: NSFont.fontSetChangedNotification)) { _ in
            reloadInstalledFontFamilies()
        }
        if options.isMissing {
            Text("選んだフォントが見つからないため、システム等幅で表示しています。フォントをインストールし直すと元に戻ります。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Text(verbatim: EditorFontOptions.sampleText)
            .font(Font(selected.font(size: 13) as CTFont))
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("フォントの見本"))
            .accessibilityValue(Text(verbatim: selected.title))
    }

    private func reloadInstalledFontFamilies() {
        let families = EditorFontFamily.installed()
        if families != installedFontFamilies { installedFontFamilies = families }
    }

    /// 配色の選択。外観に合わせて切り替えるときはライト用とダーク用の2つ、切り替えないときは1つを出す。
    @ViewBuilder
    private func themeControls(for target: ThemeTarget) -> some View {
        Toggle("macOSの外観に合わせて配色を切り替える", isOn: binding(target.followsAppearanceKeyPath, default: false))
        if settingsStore.app.followsAppearance(for: target) {
            Picker("ライト外観の配色", selection: themeBinding(for: target, slot: .light)) {
                PreviewThemeOptions(target: target, customThemes: settingsStore.app.customPreviewThemes)
            }
            Picker("ダーク外観の配色", selection: themeBinding(for: target, slot: .dark)) {
                PreviewThemeOptions(target: target, customThemes: settingsStore.app.customPreviewThemes)
            }
        } else {
            Picker("配色", selection: themeBinding(for: target, slot: .fixed)) {
                PreviewThemeOptions(target: target, customThemes: settingsStore.app.customPreviewThemes)
            }
        }
        Button("カスタムテーマを読み込む…") { importExtension(selectingThemeFor: target) }
    }

    private func themeBinding(for target: ThemeTarget, slot: ThemeSlot) -> Binding<PreviewTheme> {
        Binding(
            get: { settingsStore.app.theme(for: target, slot: slot) },
            set: { theme in
                var settings = settingsStore.app
                settings[keyPath: target.keyPath(for: slot)] = theme
                settingsStore.setAppSettings(settings)
            }
        )
    }

    /// `target` を指定すると、読み込んだ拡張のテーマをそのままその配色（プレビューか編集画面）に選ぶ。
    /// 外観に合わせて切り替えている場合は、読み込んだときの外観の側に選ぶ。
    private func importExtension(selectingThemeFor target: ThemeTarget? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.beginAttached { response in
            guard response == .OK, let url = panel.url else { return }
            loadExtension(from: url, selectingThemeFor: target)
        }
    }

    private func loadExtension(from url: URL, selectingThemeFor target: ThemeTarget? = nil) {
        do {
            var settings = settingsStore.app
            let keyPath = target.map { $0.keyPath(for: settings.themeSlot(for: $0, appearance: settingsStore.appearance)) }
            try settings.installExtension(DeclarativeExtension.load(from: url), selectingThemeFor: keyPath)
            settingsStore.setAppSettings(settings)
        } catch { extensionError = error.localizedDescription }
    }

    private func removeExtension(_ id: String) {
        var settings = settingsStore.app
        settings.removeExtension(id)
        settingsStore.setAppSettings(settings)
    }

    private func chooseDiagramTool(for kind: ExternalDiagramKind) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginAttached { response in
            guard response == .OK, let path = panel.url?.path else { return }
            if kind == .graphviz { graphvizPath = path }
            else { plantUMLPath = path }
        }
    }

    private var graphvizStatus: String {
        if graphvizPath.isEmpty { return String(localized: "未設定") }
        return FileManager.default.isExecutableFile(atPath: graphvizPath)
            ? String(localized: "利用可能") : String(localized: "実行ファイルが見つかりません。")
    }

    private var plantUMLStatus: String {
        if plantUMLPath.isEmpty { return String(localized: "未設定") }
        return FileManager.default.fileExists(atPath: plantUMLPath)
            ? String(localized: "選択済み") : String(localized: "JARファイルが見つかりません。")
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

    private func terminologyOptionBinding(_ keyPath: WritableKeyPath<TerminologyOptions, Bool>) -> Binding<Bool> {
        Binding(get: { (settingsStore.app.terminologyOptions ?? TerminologyOptions())[keyPath: keyPath] },
                set: { value in
                    var settings = settingsStore.app
                    var options = settings.terminologyOptions ?? TerminologyOptions()
                    options[keyPath: keyPath] = value
                    settings.terminologyOptions = options
                    settingsStore.setAppSettings(settings)
                })
    }

    private func terminologyBinding(_ id: UUID,
                                    _ keyPath: WritableKeyPath<TerminologyEntry, String>) -> Binding<String> {
        Binding(get: {
            (settingsStore.app.terminologyEntries ?? []).first(where: { $0.id == id })?[keyPath: keyPath] ?? ""
        }, set: { value in
            var settings = settingsStore.app
            guard let index = settings.terminologyEntries?.firstIndex(where: { $0.id == id }) else { return }
            settings.terminologyEntries?[index][keyPath: keyPath] = value
            settingsStore.setAppSettings(settings)
        })
    }

    private func terminologyIndex(_ id: UUID) -> Int {
        settingsStore.app.terminologyEntries?.firstIndex(where: { $0.id == id }) ?? 0
    }

    private func moveTerminology(_ id: UUID, by offset: Int) {
        var settings = settingsStore.app
        guard let index = settings.terminologyEntries?.firstIndex(where: { $0.id == id }),
              let count = settings.terminologyEntries?.count,
              (0..<count).contains(index + offset) else { return }
        settings.terminologyEntries?.swapAt(index, index + offset)
        settingsStore.setAppSettings(settings)
    }

    private func removeTerminology(_ id: UUID) {
        var settings = settingsStore.app
        settings.terminologyEntries?.removeAll { $0.id == id }
        settingsStore.setAppSettings(settings)
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
            Picker("字下げに使う文字", selection: optionalBinding(\.indentationStyle)) {
                Text("継承").tag(nil as EditorIndentationStyle?)
                ForEach(EditorIndentationStyle.allCases, id: \.self) { style in
                    Text(style.title).tag(Optional(style))
                }
            }
            booleanRow("書類の字下げを自動検出", keyPath: \.detectsIndentation)
            booleanRow("保存時に行末の空白を削除", keyPath: \.trimsTrailingWhitespaceOnSave)
            booleanRow("空白だけの行も対象にする", keyPath: \.trimsWhitespaceOnlyLines)
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

    private func booleanRow(_ title: LocalizedStringKey,
                            keyPath: WritableKeyPath<FolderEditorSettings, Bool?>) -> some View {
        Picker(title, selection: optionalBinding(keyPath)) {
            Text("継承").tag(nil as Bool?)
            Text("オン").tag(Optional(true))
            Text("オフ").tag(Optional(false))
        }
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
    @State private var selectedID: UUID?
    @State private var didSubmit = false

    private func insert(_ snippet: EditorSnippet) {
        // The sheet closes asynchronously, so a second click could arrive before it is gone.
        guard !didSubmit else { return }
        didSubmit = true
        onSelect(snippet)
        dismiss()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("スニペットを挿入").font(.headline)
            let available = snippets.filter { !$0.template.isEmpty }
            List(available, selection: Binding(
                get: { ListKeyboardSelection.resolved(selectedID, in: available.map(\.id)) },
                set: { selectedID = $0 })) { snippet in
                VStack(alignment: .leading) {
                    Text(snippet.trigger.isEmpty ? "定型文" : snippet.trigger)
                    Text(snippet.template).lineLimit(2).font(.caption)
                        .foregroundStyle(.secondary)
                }
                .activatesOnClick { insert(snippet) }
            }
            .contextMenu(forSelectionType: UUID.self) { _ in } primaryAction: { ids in
                guard ListKeyboardSelection.isKeyboardActivation else { return }
                if let snippet = available.first(where: { ids.contains($0.id) }) { insert(snippet) }
            }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("挿入") {
                    let id = ListKeyboardSelection.resolved(selectedID, in: available.map(\.id))
                    if let snippet = available.first(where: { $0.id == id }) { insert(snippet) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(available.isEmpty)
            }
        }
        .padding()
        .frame(width: 420, height: 320)
    }
}

struct CommandPaletteMatchesKey: PreferenceKey {
    static var defaultValue: [EditorCommand] { [] }
    static func reduce(value: inout [EditorCommand], nextValue: () -> [EditorCommand]) { value = nextValue() }
}

struct CommandPaletteView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settingsStore: EditorSettingsStore
    @ObservedObject var model: MarkdownEditorModel
    @State private var query = ""
    @State private var selectedCommand: EditorCommand?
    @State private var didSubmit = false

    private var matches: [EditorCommand] {
        EditorCommand.paletteMatches(query, in: model,
            shortcutLabel: { settingsStore.shortcut(for: $0)?.label })
    }

    var body: some View {
        let matches = matches
        let selection = Binding(get: { ListKeyboardSelection.resolved(selectedCommand, in: matches) },
                                set: { selectedCommand = $0 })
        VStack(spacing: 10) {
            TextField("コマンド名またはショートカット", text: $query)
                .textFieldStyle(.roundedBorder)
                .movesListSelection(selection, in: matches)
                .onSubmit { if let command = selection.wrappedValue { execute(command) } }
            List(matches, id: \.self, selection: selection) { command in
                HStack {
                    Label(command.title, systemImage: command.symbolName)
                    Spacer()
                    if let shortcut = settingsStore.shortcut(for: command)?.label {
                        Text(shortcut).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .activatesOnClick { execute(command) }
            }
            .contextMenu(forSelectionType: EditorCommand.self) { _ in } primaryAction: { commands in
                guard ListKeyboardSelection.isKeyboardActivation else { return }
                if let command = commands.first { execute(command) }
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
        .preference(key: CommandPaletteMatchesKey.self, value: matches)
    }

    private func execute(_ command: EditorCommand) {
        guard !didSubmit else { return }
        didSubmit = true
        dismiss()
        model.showingCommandPalette = false
        command.perform(on: model)
    }
}
