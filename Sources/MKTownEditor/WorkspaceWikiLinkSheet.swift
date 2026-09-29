import SwiftUI

struct WorkspaceWikiLinkSheet: View {
    let root: URL
    let nodes: [WorkspaceNode]
    let documentURL: URL
    let source: String
    let selection: NSRange
    let onApply: (MarkdownEdit, String) -> Bool
    let onOpen: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool
    @State private var query = ""

    private var existing: WorkspaceWikiLink? {
        WorkspaceWikiLinks.link(at: selection, in: source)
    }

    private var documents: [URL] {
        WorkspaceQuickOpen.search(nodes: nodes, root: root, query: "", limit: Int.max)
            .map(\.url)
    }

    private var resolved: URL? {
        existing.flatMap { WorkspaceWikiLinks.resolve($0.target,
            from: documentURL, documents: documents) }
    }

    private var matches: [WorkspaceQuickOpenResult] {
        WorkspaceQuickOpen.search(nodes: nodes, root: root, query: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wikiリンク").font(.headline)
            Text("文書名が同じ場合は相対パスで指定します。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("文書名またはパス", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { if let first = matches.first { insert(first.url) } }
            List(matches) { result in
                Button { insert(result.url) } label: {
                    Label(result.relativePath, systemImage: "doc.text")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            .frame(height: 280)
            if matches.isEmpty {
                Text("一致する書類がありません").foregroundStyle(.secondary)
            }
            HStack {
                if let resolved {
                    Button("リンク先を開く") {
                        dismiss()
                        onOpen(resolved)
                    }
                    Button("標準Markdownに変換") {
                        guard let edit = WorkspaceWikiLinks.conversion(in: source,
                            selection: selection, documentURL: documentURL,
                            documents: documents), onApply(edit, source) else { return }
                        dismiss()
                    }
                }
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .frame(width: 540)
        .padding(20)
        .onAppear {
            query = existing?.target ?? ""
            searchFocused = true
        }
    }

    private func insert(_ url: URL) {
        let target = WorkspaceWikiLinks.target(for: url, from: documentURL,
            documents: documents)
        guard let edit = WorkspaceWikiLinks.insertion(in: source,
            selection: selection, target: target), onApply(edit, source) else { return }
        dismiss()
    }
}
