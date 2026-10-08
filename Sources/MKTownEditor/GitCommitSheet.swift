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
    @State private var diffTask: Task<Void, Never>?
    @State private var message = ""
    @State private var error: String?
    @State private var busy = false
    @AppStorage("gitCommitRunsHooks") private var runsHooks = true

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
                        // The selected file's diff is shown on the right, so the arrow keys browse them (#60).
                        List(changes, selection: Binding(get: { selectedPath }, set: { path in
                            guard let path, path != selectedPath else { return }
                            selectedPath = path
                            reloadDiff()
                        })) { entry in
                            HStack {
                                Toggle("", isOn: Binding(
                                    get: { selected.contains(entry.path) },
                                    set: { if $0 { selected.insert(entry.path) }
                                           else { selected.remove(entry.path) } }
                                ))
                                .labelsHidden()
                                .accessibilityLabel("\(entry.path)をステージ対象にする")
                                Text(entry.path)
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
                                    reloadDiff()
                                }
                        }
                        GitDiffView(diff: diff,
                                    placeholder: String(localized: "差分なし（未追跡ファイルはステージ後に表示）"))
                            .background(Color.secondary.opacity(0.05))
                    }
                }
                Text("ステージ済み \(staged.count) 件")
                    .font(.headline)
                Text("ステージ済みの変更がすべてコミットされます。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("コミットメッセージ", text: $message)
                    .textFieldStyle(.roundedBorder)
                Toggle("リポジトリのフックを実行する", isOn: $runsHooks)
                    .toggleStyle(.checkbox)
                    .help("オフにすると、pre-commitなどのフックを実行せずにコミットします（git commit --no-verify）。")
                Button("ステージ済みの変更をコミット") {
                    Task { await commit() }
                }
                .disabled(!Self.canCommit(entries: entries, message: message) || busy)
            }
        }
        .padding(20)
        .frame(minWidth: 980, minHeight: 620)
        .task { await refresh() }
        .onDisappear { diffTask?.cancel() }
    }

    /// The commit records the whole index, so the staged list itself is what gets committed.
    static func canCommit(entries: [GitStatusEntry], message: String) -> Bool {
        entries.contains(where: \.isStaged) && !entries.contains(where: \.isConflicted) &&
            !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            }
            error = nil
            // The selected file may have changed on disk, so its diff is read again.
            reloadDiff()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Loads the selected file's diff. A newer request cancels this one, so holding an arrow
    /// key does not start one git process per row, and only the selected file's result is shown.
    private func reloadDiff() {
        diffTask?.cancel()
        diff = ""
        guard let path = selectedPath else { return }
        diffTask = Task { await loadDiff(path: path) }
    }

    private func loadDiff(path: String) async {
        do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
        guard let snapshot else { return }
        let staged = stagedPreview
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try GitRepository.diff(for: path, in: snapshot.rootURL, staged: staged)
            }.value
            guard !Task.isCancelled, selectedPath == path else { return }
            diff = result
            error = nil
        } catch {
            guard !Task.isCancelled, selectedPath == path else { return }
            self.error = error.localizedDescription
        }
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
        let value = message
        let hooks = runsHooks
        await mutate {
            try GitRepository.commit(message: value, in: snapshot.rootURL, runsHooks: hooks)
        }
        if let error, hooks {
            self.error = error + "\n" + String(localized: "フックが原因でコミットできない場合は、「リポジトリのフックを実行する」をオフにしてください。")
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
        } catch {
            busy = false
            self.error = error.localizedDescription
        }
    }
}
