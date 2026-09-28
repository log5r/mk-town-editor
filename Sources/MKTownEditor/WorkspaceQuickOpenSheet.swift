import SwiftUI

struct WorkspaceQuickOpenSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspaceStore: WorkspaceStore
    @FocusState private var searchFocused: Bool
    @State private var query = ""

    let onOpen: (URL) -> Void

    private var matches: [WorkspaceQuickOpenResult] {
        guard let root = workspaceStore.rootURL else { return [] }
        return WorkspaceQuickOpen.search(nodes: workspaceStore.nodes, root: root, query: query)
    }

    var body: some View {
        VStack(spacing: 12) {
            TextField("ファイル名またはパス", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { if let first = matches.first { open(first.url) } }
            List(matches) { result in
                Button {
                    open(result.url)
                } label: {
                    Label(result.relativePath, systemImage: "doc.text")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
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
