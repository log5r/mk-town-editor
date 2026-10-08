import SwiftUI

struct WorkspaceBacklinksSheet: View {
    let root: URL
    let targetURL: URL
    let nodes: [WorkspaceNode]
    let isTruncated: Bool
    let loadOpenBuffers: () throws -> [URL: Data]
    let onOpen: (WorkspaceBacklink) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var index: WorkspaceBacklinkIndex?
    @State private var selectedID: WorkspaceBacklink.ID?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var worker: Task<WorkspaceBacklinkIndex, Error>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("バックリンク").font(.headline)
                Spacer()
                Button("更新", systemImage: "arrow.clockwise") { load() }
                    .disabled(isLoading)
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(targetURL.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
            if isLoading {
                ProgressView("参照元を調査中")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("バックリンクを読み込めませんでした",
                    systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let index, !index.backlinks.isEmpty {
                List(index.backlinks, selection: $selectedID) { backlink in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(backlink.relativePath):\(backlink.line)")
                            .fontWeight(.medium)
                        Text(backlink.excerpt)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(backlink.relativePath)、\(backlink.line)行、\(backlink.excerpt)")
                    .activatesOnClick { onOpen(backlink) }
                }
                .activatesSelectionOnReturn(WorkspaceBacklink.ID.self) { id in
                    if let backlink = index.backlinks.first(where: { $0.id == id }) { onOpen(backlink) }
                }
            } else {
                ContentUnavailableView("参照元は見つかりません", systemImage: "link")
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
        .frame(minWidth: 620, minHeight: 420)
        .padding(20)
        .onAppear(perform: load)
        .onChange(of: root) { _, _ in load() }
        .onChange(of: targetURL) { _, _ in load() }
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
            let target = targetURL
            let nodes = nodes
            let truncated = isTruncated
            isLoading = true
            errorMessage = nil
            let task = Task.detached(priority: .userInitiated) {
                try WorkspaceBacklinkIndex.scan(root: root, targetURL: target,
                    nodes: nodes, openBuffers: buffers, isTruncated: truncated)
            }
            worker = task
            Task {
                do {
                    let result = try await task.value
                    guard !task.isCancelled else { return }
                    index = result
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
