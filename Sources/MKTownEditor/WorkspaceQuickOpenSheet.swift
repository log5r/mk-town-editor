import SwiftUI

struct WorkspaceQuickOpenSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspaceStore: WorkspaceStore
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var selectedURL: URL?

    let onOpen: (URL) -> Void

    var body: some View {
        // 正規化済みの索引をストアで共有し、検索結果は body ごとに一度だけ求める。
        let matches = workspaceStore.quickOpenIndex.search(query)
        let ids = matches.map(\.url)
        let selection = Binding(get: { ListKeyboardSelection.resolved(selectedURL, in: ids) },
                                set: { selectedURL = $0 })
        VStack(spacing: 12) {
            TextField("ファイル名またはパス", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .movesListSelection(selection, in: ids)
                .onSubmit { if let url = selection.wrappedValue { open(url) } }
            List(matches, selection: selection) { result in
                Label(result.relativePath, systemImage: "doc.text")
                    .activatesOnClick { open(result.url) }
            }
            .contextMenu(forSelectionType: URL.self) { _ in } primaryAction: { urls in
                if let url = urls.first { open(url) }
            }
            .frame(height: 300)
            if matches.isEmpty {
                Text("一致する書類がありません")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(width: 500)
        .padding(20)
        .onAppear {
            workspaceStore.refresh()
            searchFocused = true
        }
    }

    private func open(_ url: URL) {
        dismiss()
        onOpen(url)
    }
}
