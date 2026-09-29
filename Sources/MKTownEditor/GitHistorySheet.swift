import SwiftUI

struct GitHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let fileURL: URL
    @State private var snapshot: GitSnapshot?
    @State private var selectedRevision: GitRevision?
    @State private var historicalContent = ""
    @State private var error: String?
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Gitの差分と履歴").font(.title2)
                Spacer()
                Button("更新", systemImage: "arrow.clockwise") {
                    Task { await refresh() }
                }
                .disabled(isLoading)
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if isLoading { ProgressView() }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let snapshot {
                Text(snapshot.rootURL.path).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("保存済みファイルのGit状態を表示しています")
                    .font(.caption).foregroundStyle(.secondary)
                TabView {
                    ScrollView([.vertical, .horizontal]) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("フォルダの変更")
                                .font(.headline)
                            Text(snapshot.status.isEmpty ? "変更なし" : snapshot.status)
                                .padding(.bottom, 12)
                            Text("\(snapshot.relativePath) の差分")
                                .font(.headline)
                            let lines = snapshot.diff.components(separatedBy: "\n")
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                Text(line.isEmpty ? " " : line)
                                    .foregroundStyle(line.hasPrefix("+") && !line.hasPrefix("+++")
                                        ? Color.green : line.hasPrefix("-") && !line.hasPrefix("---")
                                        ? Color.red : Color.primary)
                            }
                        }
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    }
                    .tabItem { Text("差分") }
                    HStack(spacing: 12) {
                        List(snapshot.history) { revision in
                            Button {
                                selectedRevision = revision
                                Task { await loadContent(revision, in: snapshot) }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(revision.subject).lineLimit(2)
                                    Text(revision.shortHash)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(width: 250)
                        ScrollView([.vertical, .horizontal]) {
                            Text(selectedRevision == nil ? "履歴から版を選択" : historicalContent)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(selectedRevision == nil ? .secondary : .primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                    }
                    .tabItem { Text("履歴") }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 780, minHeight: 540)
        .task { await refresh() }
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let url = fileURL
            snapshot = try await Task.detached(priority: .userInitiated) {
                try GitRepository.load(for: url)
            }.value
            error = nil
        } catch {
            snapshot = nil
            self.error = error.localizedDescription
        }
    }

    private func loadContent(_ revision: GitRevision, in snapshot: GitSnapshot) async {
        do {
            let content = try await Task.detached(priority: .userInitiated) {
                try GitRepository.content(of: revision, in: snapshot)
            }.value
            if selectedRevision == revision { historicalContent = content }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
