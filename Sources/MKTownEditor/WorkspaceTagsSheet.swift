import SwiftUI

struct WorkspaceTagsSheet: View {
    let root: URL
    let nodes: [WorkspaceNode]
    let isTruncated: Bool
    let loadOpenBuffers: () throws -> [URL: Data]
    let onOpen: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var index: WorkspaceTagIndex?
    @State private var selectedTag: String?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var worker: Task<WorkspaceTagIndex, Error>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("タグ一覧").font(.headline)
                Spacer()
                Button("更新", systemImage: "arrow.clockwise") { load() }
                    .disabled(isLoading)
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if isLoading {
                ProgressView("タグを調査中")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("タグを読み込めませんでした", systemImage: "exclamationmark.triangle",
                                       description: Text(errorMessage))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let index, !index.tags.isEmpty {
                HStack(spacing: 0) {
                    List(index.tags, id: \.self, selection: $selectedTag) { tag in
                        HStack {
                            Text("#\(tag)")
                            Spacer()
                            Text("\(index.documents(for: tag).count)")
                                .foregroundStyle(.secondary)
                        }
                        .tag(tag)
                    }
                    .frame(width: 230)
                    Divider()
                    List(index.documents(for: selectedTag ?? "")) { document in
                        Button(document.relativePath) { onOpen(document.url) }
                            .buttonStyle(.plain)
                    }
                }
            } else {
                ContentUnavailableView("タグが見つかりません", systemImage: "number")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let index, !isLoading, errorMessage == nil {
                if index.isTruncated {
                    Text("ファイル一覧が上限に達したため、一部の書類は索引に含まれていません。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if index.skippedDocuments > 0 {
                    Text("読み込めなかった書類: \(index.skippedDocuments)件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .padding(20)
        .onAppear(perform: load)
        .onDisappear {
            worker?.cancel()
            worker = nil
        }
    }

    private func load() {
        worker?.cancel()
        do {
            let buffers = try loadOpenBuffers()
            let root = root
            let nodes = nodes
            let truncated = isTruncated
            isLoading = true
            errorMessage = nil
            let task = Task.detached(priority: .userInitiated) {
                try WorkspaceTagIndex.scan(root: root, nodes: nodes, openBuffers: buffers,
                                           isTruncated: truncated)
            }
            worker = task
            Task {
                do {
                    let result = try await task.value
                    guard !task.isCancelled else { return }
                    index = result
                    if !result.tags.contains(selectedTag ?? "") {
                        selectedTag = result.tags.first
                    }
                    isLoading = false
                    worker = nil
                } catch is CancellationError {
                    return
                } catch {
                    guard !task.isCancelled else { return }
                    errorMessage = error.localizedDescription
                    isLoading = false
                    worker = nil
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            worker = nil
        }
    }
}
