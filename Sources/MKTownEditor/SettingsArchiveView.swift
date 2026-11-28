import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsArchiveSection: View {
    @ObservedObject var settingsStore: EditorSettingsStore
    @State private var selection: Selection?
    @State private var pendingExport: Data?
    @State private var importBaseline: SettingsArchive.Snapshot?
    @State private var notice: Notice?
    @State private var isHandlingFile = false

    private enum Selection: Identifiable {
        case export
        case importReview(SettingsArchive, name: String, differences: [SettingsArchive.Category: [String]])

        var id: String {
            switch self {
            case .export: "export"
            case .importReview: "import"
            }
        }
    }

    private struct Notice {
        let title: String
        let message: String
    }

    var body: some View {
        Section("設定の移行") {
            Button("設定を書き出す…") { selection = .export }
                .disabled(isHandlingFile)
                .sheet(item: $selection, onDismiss: finishSelection) { selection in
                    selectionSheet(selection)
                }
                .alert(notice?.title ?? "", isPresented: Binding(get: { notice != nil }, set: { isPresented in
                    if !isPresented { notice = nil }
                }), presenting: notice) { _ in
                    Button("OK") { notice = nil }
                } message: { notice in
                    Text(notice.message)
                }
            Button("設定を読み込む…") { openArchive() }
                .disabled(isHandlingFile)
            if isHandlingFile {
                ProgressView("設定ファイルを処理中…")
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func selectionSheet(_ stage: Selection) -> some View {
        switch stage {
        case .export:
            SettingsArchiveSelectionSheet(
                title: "書き出す項目を選ぶ", actionTitle: "次へ…",
                categories: Set(SettingsArchive.Category.allCases)
            ) { categories in
                pendingExport = try settingsStore.exportSettings(categories: categories)
                selection = nil
            }
        case .importReview(let archive, let name, let differences):
            SettingsArchiveSelectionSheet(
                title: "読み込む項目を確認", actionTitle: "設定を適用",
                categories: archive.categories, fileName: name, differences: differences,
                refreshDifferences: { refreshReview(of: archive, categories: $0) }
            ) { categories in
                try settingsStore.importSettings(archive, categories: categories)
                selection = nil
            }
        }
    }

    private func refreshReview(of archive: SettingsArchive, categories: Set<SettingsArchive.Category>)
        -> [SettingsArchive.Category: [String]]? {
        let current = settingsStore.settingsArchiveSnapshot
        if let importBaseline, archive.affectedSettingsMatch(importBaseline, current, categories: categories) {
            return nil
        }
        importBaseline = current
        return archive.differences(from: current)
    }

    private func finishSelection() {
        importBaseline = nil
        guard let data = pendingExport else { return }
        pendingExport = nil
        isHandlingFile = true
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MKTownEditor-settings.json"
        panel.canCreateDirectories = true
        panel.beginAttached { response in
            panel.orderOut(nil)
            guard response == .OK, let url = panel.url else {
                isHandlingFile = false
                return
            }
            Task {
                defer { isHandlingFile = false }
                do {
                    try await DocumentWork.commit {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        try data.write(to: url, options: .atomic)
                    }
                } catch {
                    notice = Notice(title: String(localized: "設定を書き出せません"), message: error.localizedDescription)
                }
            }
        }
    }

    private func openArchive() {
        guard !isHandlingFile else { return }
        isHandlingFile = true
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "確認")
        panel.beginAttached { response in
            panel.orderOut(nil)
            guard response == .OK, let url = panel.url else {
                isHandlingFile = false
                return
            }
            Task {
                defer { isHandlingFile = false }
                do {
                    let data = try await DocumentWork.perform {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        return try Data(contentsOf: url)
                    }
                    let archive = try SettingsArchive(data: data)
                    let current = settingsStore.settingsArchiveSnapshot
                    importBaseline = current
                    let differences = archive.differences(from: current)
                    selection = .importReview(archive, name: url.lastPathComponent, differences: differences)
                } catch {
                    notice = Notice(title: String(localized: "設定を読み込めません"), message: error.localizedDescription)
                }
            }
        }
    }
}

private struct SettingsArchiveSelectionSheet: View {
    private typealias Category = SettingsArchive.Category

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<Category>
    @State private var differences: [Category: [String]]?
    @State private var errorMessage: String?
    @State private var reviewChanged = false
    @State private var didSubmit = false

    private let title: LocalizedStringKey
    private let actionTitle: LocalizedStringKey
    private let categories: Set<Category>
    private let fileName: String?
    private let refreshDifferences: ((Set<Category>) -> [Category: [String]]?)?
    private let onApply: (Set<Category>) throws -> Void

    private var selectable: Set<Category> {
        Self.selectableCategories(categories, differences: differences)
    }

    init(title: LocalizedStringKey, actionTitle: LocalizedStringKey, categories: Set<SettingsArchive.Category>,
         fileName: String? = nil, differences: [SettingsArchive.Category: [String]]? = nil,
         refreshDifferences: ((Set<SettingsArchive.Category>) -> [SettingsArchive.Category: [String]]?)? = nil,
         onApply: @escaping (Set<SettingsArchive.Category>) throws -> Void) {
        self.title = title
        self.actionTitle = actionTitle
        self.categories = categories
        self.fileName = fileName
        self.refreshDifferences = refreshDifferences
        self.onApply = onApply
        _differences = State(initialValue: differences)
        _selected = State(initialValue: Self.selectableCategories(categories, differences: differences))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            if let fileName {
                Text(verbatim: fileName)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(fileName)
                if selectable.isEmpty {
                    Text("現在の設定と同じ内容です。")
                } else {
                    Text("選んだ項目をファイルの内容で置き換えます。")
                }
            }
            categoryList
            if reviewChanged {
                Text("現在の設定が変わりました。更新した差分を確認してください。")
                    .font(.callout)
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                if selectable.isEmpty {
                    Button("閉じる") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("キャンセル") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(actionTitle) { apply() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selected.isEmpty || didSubmit)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var categoryList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !selectable.isEmpty {
                HStack {
                    Button("すべて選択") { selected = selectable }
                        .disabled(selected == selectable)
                    Button("選択を解除") { selected = [] }
                        .disabled(selected.isEmpty)
                }
                .controlSize(.small)
            }
            GroupBox {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Category.allCases.filter { categories.contains($0) }) { category in
                            categoryRow(category)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
                .frame(height: differences == nil ? 220 : 260)
            }
        }
    }

    private func categoryRow(_ category: Category) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(category.title, isOn: Binding(get: { selected.contains(category) }, set: { isSelected in
                if isSelected { selected.insert(category) } else { selected.remove(category) }
            }))
            .toggleStyle(.checkbox)
            .disabled(!selectable.contains(category))
            if let changes = differences?[category] {
                VStack(alignment: .leading, spacing: 2) {
                    if changes.isEmpty {
                        Text("変更なし")
                    } else {
                        ForEach(changes.indices, id: \.self) { index in
                            Text(verbatim: changes[index])
                        }
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 20)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func apply() {
        guard !didSubmit, !selected.isEmpty else { return }
        if let current = refreshDifferences?(selected) {
            differences = current
            selected.formIntersection(selectable)
            errorMessage = nil
            reviewChanged = true
            return
        }
        do {
            try onApply(selected)
            didSubmit = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func selectableCategories(_ categories: Set<Category>, differences: [Category: [String]]?) -> Set<Category> {
        guard let differences else { return categories }
        return categories.filter { differences[$0]?.isEmpty == false }
    }
}

private extension SettingsArchive.Category {
    var title: String {
        switch self {
        case .general: String(localized: "一般")
        case .editor: String(localized: "エディタ")
        case .preview: String(localized: "プレビュー")
        case .themes: String(localized: "配色")
        case .snippets: String(localized: "スニペット")
        case .terminology: String(localized: "用語辞書")
        case .shortcuts: String(localized: "ショートカット")
        case .exportPresets: String(localized: "書き出しプリセット")
        case .extensions: String(localized: "拡張")
        }
    }
}
