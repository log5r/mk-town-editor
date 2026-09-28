import AppKit
import SwiftUI

struct WorkspaceAttachmentAuditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspaceStore: WorkspaceStore
    @State private var result: WorkspaceAttachmentAuditResult?
    @State private var errorMessage: String?
    let root: URL
    let onOpenDocument: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("添付ファイルの確認").font(.headline)
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("ワークスペース内のMarkdown書類を調べます。未使用は整理候補で、ファイルは削除しません。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let errorMessage {
                ContentUnavailableView("確認できませんでした", systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage))
            } else if let result {
                List {
                    Section("欠落している添付（\(result.missing.count)）") {
                        ForEach(result.missing) { entry in entryRow(entry) }
                    }
                    Section("未使用の候補（\(result.unused.count)）") {
                        ForEach(result.unused) { entry in entryRow(entry) }
                    }
                    Section("参照されている添付（\(result.used.count)）") {
                        ForEach(result.used) { entry in entryRow(entry) }
                    }
                }
            } else {
                ProgressView("添付ファイルを確認中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
        .frame(minWidth: 650, minHeight: 500)
        .task { await refresh() }
    }

    @ViewBuilder
    private func entryRow(_ entry: WorkspaceAttachmentEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(relativePath(entry.url)).fontWeight(.medium)
                    .textSelection(.enabled)
                Spacer()
                if FileManager.default.fileExists(atPath: entry.url.path) {
                    Button("Finderで表示") {
                        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                    }
                    .buttonStyle(.link)
                }
            }
            if !entry.sources.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("参照元:").foregroundStyle(.secondary)
                    ForEach(entry.sources, id: \.self) { source in
                        Button(relativePath(source)) {
                            dismiss()
                            onOpenDocument(source)
                        }
                            .buttonStyle(.link)
                    }
                }
                .font(.caption)
            }
        }
    }

    private func relativePath(_ url: URL) -> String {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.path
    }

    private func refresh() async {
        do {
            let snapshots = try workspaceStore.openBufferSnapshots(under: root)
            result = try await Task.detached(priority: .userInitiated) {
                try await WorkspaceAttachmentAudit.scan(root: root, openDocuments: snapshots)
            }.value
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
