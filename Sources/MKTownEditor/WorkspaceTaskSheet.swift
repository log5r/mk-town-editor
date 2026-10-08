import SwiftUI

struct WorkspaceTaskSheet: View {
    let root: URL
    let nodes: [WorkspaceNode]
    let isTruncated: Bool
    let loadOpenBuffers: () throws -> [URL: Data]
    let onToggle: (WorkspaceTaskItem) -> Void
    let onOpen: (WorkspaceTaskItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var index: WorkspaceTaskIndex?
    @State private var selectedID: WorkspaceTaskItem.ID?
    @State private var didSubmit = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var worker: Task<WorkspaceTaskIndex, Error>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("未完了のタスク").font(.headline)
                Spacer()
                Button("更新", systemImage: "arrow.clockwise") { load() }
                    .disabled(isLoading)
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if isLoading {
                ProgressView("タスクを検索中")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("タスクを読み込めませんでした",
                    systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let index, !index.tasks.isEmpty {
                List(index.tasks, selection: $selectedID) { task in
                    HStack(spacing: 12) {
                        Button("完了にする", systemImage: "circle") {
                            submit { onToggle(task) }
                        }
                        .labelStyle(.iconOnly)
                        .help("完了にする")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(task.title.isEmpty ? "無題のタスク" : task.title)
                                .fontWeight(.medium)
                            Text("\(task.relativePath):\(task.line)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .activatesOnClick { submit { onOpen(task) } }
                    }
                }
                .activatesSelectionOnReturn(WorkspaceTaskItem.ID.self) { id in
                    guard let task = index.tasks.first(where: { $0.id == id }) else { return }
                    submit { onOpen(task) }
                }
            } else {
                ContentUnavailableView("未完了のタスクはありません",
                    systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let index, !isLoading, errorMessage == nil {
                if index.isTruncated {
                    Text("ファイル一覧が上限に達したため、一部の書類は索引に含まれていません。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if index.skippedDocuments > 0 {
                    Text("読み込めなかった書類: \(index.skippedDocuments)件")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 420)
        .padding(20)
        .onAppear(perform: load)
        .onDisappear {
            worker?.cancel()
            worker = nil
        }
    }

    /// A second click or Return can reach the sheet while it closes, so only the first acts.
    private func submit(_ action: () -> Void) {
        guard !didSubmit else { return }
        didSubmit = true
        dismiss()
        action()
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
                try WorkspaceTaskIndex.scan(root: root, nodes: nodes,
                    openBuffers: buffers, isTruncated: truncated)
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
