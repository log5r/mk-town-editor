import SwiftUI

struct WorkspaceSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspaceStore: WorkspaceStore
    @FocusState private var queryFocused: Bool
    @State private var query = ""
    @State private var include = "*.md, *.markdown, *.txt"
    @State private var exclude = ""
    @State private var scope: WorkspaceSearchScope = .all
    @State private var results: [WorkspaceSearchResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<[WorkspaceSearchResult], Error>?
    @State private var searchGeneration = 0

    let onOpen: (WorkspaceSearchResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("フォルダ全体を検索").font(.headline)
            Text("検索語（改行も指定できます）").font(.caption)
            TextEditor(text: $query)
                .frame(height: 62)
                .border(Color.secondary.opacity(0.4))
                .focused($queryFocused)
            HStack {
                TextField("対象: *.md, docs/*", text: $include)
                TextField("除外: archive/*", text: $exclude)
            }
            .textFieldStyle(.roundedBorder)
            Picker("構造", selection: $scope) {
                ForEach(WorkspaceSearchScope.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            Text("対象・除外はカンマ区切りのファイルパスパターンです。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            List(results) { result in
                Button {
                    dismiss()
                    onOpen(result)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(result.relativePath):\(result.line)")
                            .font(.subheadline.weight(.semibold))
                        Text(result.excerpt).font(.caption).lineLimit(2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(height: 330)
            if isSearching { ProgressView("検索中…") }
            else { Text("\(results.count)件").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("閉じる") { cancelSearch(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isSearching ? "中止" : "検索") {
                    if isSearching { cancelSearch() }
                    else { search() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(query.isEmpty)
            }
        }
        .frame(width: 650)
        .padding(20)
        .onAppear { queryFocused = true }
        .onDisappear { cancelSearch() }
    }

    private func search() {
        guard !query.isEmpty, let root = workspaceStore.rootURL else { return }
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        results = []
        errorMessage = nil
        isSearching = true
        let options = WorkspaceSearchOptions(query: query,
            includePatterns: patterns(in: include).isEmpty ? ["*"] : patterns(in: include),
            excludePatterns: patterns(in: exclude), scope: scope)
        let worker = Task.detached(priority: .userInitiated) {
            try WorkspaceSearch.search(root: root, options: options)
        }
        searchTask = worker
        Task {
            do {
                let found = try await worker.value
                guard generation == searchGeneration else { return }
                results = found
            } catch is CancellationError {
                // The user cancelled this search.
            } catch {
                if generation == searchGeneration { errorMessage = error.localizedDescription }
            }
            if generation == searchGeneration { isSearching = false }
        }
    }

    private func cancelSearch() {
        searchGeneration += 1
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    private func patterns(in input: String) -> [String] {
        input.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
