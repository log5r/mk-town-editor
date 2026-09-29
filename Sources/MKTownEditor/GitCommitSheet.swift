import SwiftUI

struct GitCommitSheet: View {
    @Environment(\.dismiss) private var dismiss
    let fileURL: URL
    let openFile: (URL) -> Void
    @State private var snapshot: GitSnapshot?
    @State private var entries: [GitStatusEntry] = []
    @State private var selected: Set<String> = []
    @State private var selectedPath: String?
    @State private var stagedPreview = false
    @State private var diff = ""
    @State private var message = ""
    @State private var error: String?
    @State private var busy = false

    private var conflicts: [GitStatusEntry] { entries.filter(\.isConflicted) }
    private var changes: [GitStatusEntry] { entries.filter { !$0.isConflicted } }
    private var staged: [GitStatusEntry] { changes.filter(\.isStaged) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Gitのステージとコミット").font(.title2)
                Spacer()
                Button("更新", systemImage: "arrow.clockwise") {
                    Task { await refresh() }
                }
                .disabled(busy)
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("保存済みファイルの変更を操作します。通信操作は行いません。")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if busy { ProgressView() }
            if let snapshot {
                Text(snapshot.rootURL.path).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("変更ファイル").font(.headline)
                        List(changes) { entry in
                            HStack {
                                Toggle("", isOn: Binding(
                                    get: { selected.contains(entry.path) },
                                    set: { if $0 { selected.insert(entry.path) }
                                           else { selected.remove(entry.path) } }
                                ))
                                .labelsHidden()
                                Button(entry.path) {
                                    selectedPath = entry.path
                                    Task { await loadDiff(path: entry.path) }
                                }
                                .buttonStyle(.plain)
                                Spacer()
                                if entry.isStaged {
                                    Text("ステージ済み").font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        HStack {
                            Button("選択をステージ") { Task { await stageSelected() } }
                                .disabled(selected.isEmpty || busy)
                            Button("選択を戻す") { Task { await unstageSelected() } }
                                .disabled(selected.isEmpty || busy)
                        }
                        if !conflicts.isEmpty {
                            Divider()
                            Text("競合ファイル").font(.headline)
                            Text("編集して保存した後、別の操作で解消済みとしてステージします。")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(conflicts) { entry in
                                HStack {
                                    Text(entry.path).lineLimit(1)
                                    Spacer()
                                    Button("編集") {
                                        openFile(snapshot.rootURL.appendingPathComponent(entry.path))
                                    }
                                    Button("解消済みとしてステージ") {
                                        Task { await stageResolved(entry.path) }
                                    }
                                    .disabled(busy)
                                }
                            }
                        }
                    }
                    .frame(width: 350)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(selectedPath ?? "差分を選択").font(.headline).lineLimit(1)
                            Spacer()
                            Toggle("ステージ済みの差分", isOn: $stagedPreview)
                                .toggleStyle(.checkbox)
                                .onChange(of: stagedPreview) { _, _ in
                                    if let selectedPath { Task { await loadDiff(path: selectedPath) } }
                                }
                        }
                        ScrollView([.vertical, .horizontal]) {
                            Text(diff.isEmpty ? "差分なし（未追跡ファイルはステージ後に表示）" : diff)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .background(Color.secondary.opacity(0.05))
                    }
                }
                Text("ステージ済み \(staged.count) 件")
                    .font(.headline)
                Text("コミット対象のステージ済みファイルをすべて選択してください。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("コミットメッセージ", text: $message)
                    .textFieldStyle(.roundedBorder)
                Button("ステージ済みの変更をコミット") {
                    Task { await commit() }
                }
                .disabled(staged.isEmpty || !conflicts.isEmpty ||
                          selected != Set(staged.map(\.path)) ||
                          message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
            }
        }
        .padding(20)
        .frame(minWidth: 980, minHeight: 620)
        .task { await refresh() }
    }

    private func refresh() async {
        busy = true
        defer { busy = false }
        do {
            let url = fileURL
            let loaded = try await Task.detached(priority: .userInitiated) {
                let snapshot = try GitRepository.load(for: url)
                return (snapshot, try GitRepository.statusEntries(in: snapshot.rootURL))
            }.value
            snapshot = loaded.0
            entries = loaded.1
            selected.formIntersection(Set(entries.map(\.path)))
            if let selectedPath, !entries.contains(where: { $0.path == selectedPath }) {
                self.selectedPath = nil
                diff = ""
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadDiff(path: String) async {
        guard let snapshot else { return }
        do {
            let staged = stagedPreview
            let result = try await Task.detached(priority: .userInitiated) {
                try GitRepository.diff(for: path, in: snapshot.rootURL, staged: staged)
            }.value
            if selectedPath == path { diff = result }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func stageSelected() async {
        guard let snapshot else { return }
        let paths = Array(selected)
        await mutate {
            try GitRepository.stage(paths, in: snapshot.rootURL)
        }
    }

    private func unstageSelected() async {
        guard let snapshot else { return }
        let paths = Array(selected)
        await mutate {
            try GitRepository.unstage(paths, in: snapshot.rootURL)
        }
    }

    private func stageResolved(_ path: String) async {
        guard let snapshot else { return }
        await mutate {
            try GitRepository.stageResolvedConflict(path, in: snapshot.rootURL)
        }
    }

    private func commit() async {
        guard let snapshot else { return }
        guard selected == Set(staged.map(\.path)) else {
            error = GitRepositoryError.invalidSelection.localizedDescription
            return
        }
        let value = message
        await mutate {
            try GitRepository.commit(message: value, in: snapshot.rootURL)
        }
        if error == nil { message = "" }
    }

    private func mutate(_ operation: @escaping @Sendable () throws -> Void) async {
        busy = true
        do {
            try await Task.detached(priority: .userInitiated, operation: operation).value
            busy = false
            selected.removeAll()
            await refresh()
            if let selectedPath { await loadDiff(path: selectedPath) }
        } catch {
            busy = false
            self.error = error.localizedDescription
        }
    }
}
