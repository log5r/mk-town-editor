import SwiftUI

struct WorkspaceNoteMergeSheet: View {
    let root: URL
    let index: WorkspaceQuickOpenIndex
    let loadOpenBuffers: () throws -> [URL: Data]
    let onOpen: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: Set<URL> = []
    @State private var fileName = "merged.md"
    @State private var folderPath = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var worker: Task<URL, Error>?

    /// 結合の実行時だけ必要になる、シンボリックリンクを解決した書類一覧。
    private var documents: [URL] {
        index.rankedDocumentURLs.map { $0.resolvingSymlinksInPath().standardizedFileURL }
    }

    private var destinationURL: URL {
        let name = URL(fileURLWithPath: fileName).pathExtension.isEmpty
            ? fileName + ".md" : fileName
        return root.appendingPathComponent(folderPath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(name)
    }

    var body: some View {
        let matches = index.search(query, limit: 200)
        VStack(alignment: .leading, spacing: 12) {
            Text("書類を結合").font(.headline)
            Text("元の書類を残し、新しい書類に内容をまとめます。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("書類を絞り込む", text: $query)
                .textFieldStyle(.roundedBorder)
            List(matches) { item in
                let url = item.url.resolvingSymlinksInPath().standardizedFileURL
                Toggle(item.relativePath, isOn: Binding(
                    get: { selected.contains(url) },
                    set: { included in
                        if included { selected.insert(url) } else { selected.remove(url) }
                    }
                ))
                .disabled(isWorking)
            }
            .frame(height: 220)
            Text("選択中: \(selected.count)書類")
                .font(.caption).foregroundStyle(.secondary)
            TextField("ファイル名", text: $fileName)
                .textFieldStyle(.roundedBorder)
                .disabled(isWorking)
            TextField("ワークスペース内の保存先フォルダ", text: $folderPath)
                .textFieldStyle(.roundedBorder)
                .disabled(isWorking)
            Text(destinationURL.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack {
                if isWorking { ProgressView() }
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("結合") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || selected.count < 2 || fileName.isEmpty)
            }
        }
        .frame(width: 580)
        .padding(20)
        .onDisappear {
            worker?.cancel()
            worker = nil
        }
    }

    private func create() {
        guard selected.count >= 2 else { return }
        guard selected.count <= 10 else {
            errorMessage = WorkspaceNoteOperationError.tooManyDocuments.localizedDescription
            return
        }
        do {
            let buffers = try loadOpenBuffers()
            let root = root
            let destination = destinationURL
            let urls = selected.sorted { $0.path < $1.path }
            let documents = documents
            errorMessage = nil
            isWorking = true
            let task = Task.detached(priority: .userInitiated) {
                var inputs: [WorkspaceMergeInput] = []
                var totalBytes = 0
                for url in urls {
                    try Task.checkCancellation()
                    let data: Data
                    if let open = buffers[url] {
                        data = open
                    } else {
                        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                              size <= 8_000_000,
                              let file = try? Data(contentsOf: url) else {
                            throw WorkspaceNoteOperationError.unreadableDocument(url)
                        }
                        data = file
                    }
                    totalBytes += data.count
                    guard data.count <= 8_000_000, totalBytes <= 24_000_000,
                          let text = try? MarkdownDocument.decode(data) else {
                        throw WorkspaceNoteOperationError.unreadableDocument(url)
                    }
                    inputs.append(WorkspaceMergeInput(url: url, text: text))
                }
                guard let merged = WorkspaceNoteOperations.merge(inputs,
                    destinationURL: destination, workspaceDocuments: documents) else {
                    throw WorkspaceNoteOperationError.tooManyDocuments
                }
                try Task.checkCancellation()
                return try WorkspaceFileOperations.create(name: destination.lastPathComponent,
                    in: destination.deletingLastPathComponent(), root: root,
                    folder: false, contents: merged)
            }
            worker = task
            Task {
                do {
                    let url = try await task.value
                    worker = nil
                    isWorking = false
                    dismiss()
                    onOpen(url)
                } catch is CancellationError {
                    worker = nil
                    isWorking = false
                } catch {
                    worker = nil
                    isWorking = false
                    errorMessage = error.localizedDescription
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
