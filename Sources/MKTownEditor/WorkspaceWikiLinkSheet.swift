import SwiftUI

struct WorkspaceWikiLinkSheet: View {
    let index: WorkspaceQuickOpenIndex
    let documentURL: URL
    let source: String
    let selection: NSRange
    let onApply: (MarkdownEdit, String) -> Bool
    let onOpen: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var selectedURL: URL?
    @State private var documentIndex = WorkspaceDocumentIndex(documents: [])
    @State private var indexedDocuments: [URL] = []
    @State private var existingCache = DerivedValueCache<ExistingLinkKey, WorkspaceWikiLink?>()

    private struct ExistingLinkKey: Equatable {
        let source: String
        let selection: NSRange
    }

    private var existing: WorkspaceWikiLink? {
        existingCache.value(for: ExistingLinkKey(source: source, selection: selection)) {
            WorkspaceWikiLinks.link(at: $0.selection, in: $0.source)
        }
    }

    private var documents: [URL] { index.rankedDocumentURLs }

    var body: some View {
        let matches = index.search(query)
        let resolved = existing.flatMap { WorkspaceWikiLinks.resolve($0.target,
            from: documentURL, index: documentIndex) }
        VStack(alignment: .leading, spacing: 12) {
            Text("Wikiリンク").font(.headline)
            Text("文書名が同じ場合は相対パスで指定します。")
                .font(.caption).foregroundStyle(.secondary)
            let ids = matches.map(\.url)
            let listSelection = Binding(get: { ListKeyboardSelection.resolved(selectedURL, in: ids) },
                                        set: { selectedURL = $0 })
            TextField("文書名またはパス", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .movesListSelection(listSelection, in: ids)
                .onSubmit { if let url = listSelection.wrappedValue { insert(url) } }
            List(matches, selection: listSelection) { result in
                Label(result.relativePath, systemImage: "doc.text")
                    .activatesOnClick { insert(result.url) }
            }
            .contextMenu(forSelectionType: URL.self) { _ in } primaryAction: { urls in
                if let url = urls.first { insert(url) }
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
        .task(id: documents) {
            // The list follows workspace changes while the sheet is open; so does the index.
            let urls = documents
            let index = await Task.detached(priority: .utility) { WorkspaceDocumentIndex(documents: urls) }.value
            guard !Task.isCancelled else { return }
            documentIndex = index
            indexedDocuments = urls
        }
        .onAppear {
            query = existing?.target ?? ""
            searchFocused = true
        }
    }

    private func insert(_ url: URL) {
        let target = Self.linkTarget(for: url, from: documentURL, documents: documents,
                                     cachedIndex: documentIndex, indexedDocuments: indexedDocuments)
        guard let edit = WorkspaceWikiLinks.insertion(in: source,
            selection: selection, target: target), onApply(edit, source) else { return }
        dismiss()
    }

    /// The link text for `url`, disambiguated against the documents listed now. The cached
    /// background index is used only when it was built from that same list; otherwise a newly
    /// added document with the same title would make the inserted link ambiguous.
    static func linkTarget(for url: URL, from documentURL: URL, documents: [URL],
                           cachedIndex: WorkspaceDocumentIndex, indexedDocuments: [URL]) -> String {
        let index = indexedDocuments == documents ? cachedIndex : WorkspaceDocumentIndex(documents: documents)
        return WorkspaceWikiLinks.target(for: url, from: documentURL, index: index)
    }
}
