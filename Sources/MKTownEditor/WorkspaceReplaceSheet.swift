import AppKit
import SwiftUI

struct WorkspaceReplaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspaceStore: WorkspaceStore
    @State private var query = ""
    @State private var replacement = ""
    @State private var include = "*.md, *.markdown, *.txt"
    @State private var exclude = ""
    @State private var plan: WorkspaceReplacePlan?
    @State private var selectedURLs: Set<URL> = []
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var isApplying = false
    @State private var planTask: Task<WorkspaceReplacePlan, Error>?
    @State private var planGeneration = 0

    let currentDocumentURL: URL?
    let onComplete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("複数ファイルの一括置換").font(.headline)
            HStack {
                VStack(alignment: .leading) {
                    Text("検索語").font(.caption)
                    TextEditor(text: $query).frame(height: 54)
                        .border(Color.secondary.opacity(0.4))
                }
                VStack(alignment: .leading) {
                    Text("置換後").font(.caption)
                    TextEditor(text: $replacement).frame(height: 54)
                        .border(Color.secondary.opacity(0.4))
                }
            }
            HStack {
                TextField("対象: *.md, docs/*", text: $include)
                TextField("除外: archive/*", text: $exclude)
            }
            .textFieldStyle(.roundedBorder)
            Text("対象・除外はカンマ区切りのパスパターンです。開いている書類は置換できません。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let plan {
                Text("\(plan.changes.count)ファイル / \(plan.matchCount)箇所。変更するファイルを選んでください。")
                List(plan.changes, id: \.url) { change in
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("\(change.relativePath)（\(change.matches.count)箇所）", isOn: Binding(
                            get: { selectedURLs.contains(change.url) },
                            set: { selected in
                                if selected { selectedURLs.insert(change.url) }
                                else { selectedURLs.remove(change.url) }
                            }
                        ))
                        .font(.subheadline.weight(.semibold))
                        ForEach(change.previews.indices, id: \.self) { index in
                            let preview = change.previews[index]
                            VStack(alignment: .leading, spacing: 2) {
                                Text("行\(preview.line)  − \(preview.before)")
                                    .foregroundStyle(.secondary)
                                Text("      + \(preview.after)")
                                    .foregroundStyle(.primary)
                            }
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        }
                    }
                }
                .frame(height: 330)
            }
            if isWorking { ProgressView(isApplying ? "置換中…" : "差分を確認中…") }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("閉じる") { invalidatePlan(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isApplying)
                if plan == nil {
                    Button("差分を確認") { preparePlan() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(query.isEmpty || isWorking)
                } else {
                    Button("選択したファイルを置換") { applyPlan() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedURLs.isEmpty || isWorking)
                }
            }
        }
        .frame(width: 720)
        .padding(20)
        .interactiveDismissDisabled(isApplying)
        .onChange(of: query) { _, _ in invalidatePlan() }
        .onChange(of: replacement) { _, _ in invalidatePlan() }
        .onChange(of: include) { _, _ in invalidatePlan() }
        .onChange(of: exclude) { _, _ in invalidatePlan() }
        .onDisappear { planTask?.cancel() }
    }

    private func preparePlan() {
        guard let root = workspaceStore.rootURL else { return }
        planTask?.cancel()
        planGeneration += 1
        let generation = planGeneration
        isWorking = true
        errorMessage = nil
        let options = WorkspaceSearchOptions(query: query,
            includePatterns: patterns(in: include).isEmpty ? ["*"] : patterns(in: include),
            excludePatterns: patterns(in: exclude))
        let replacement = replacement
        let worker = Task.detached(priority: .userInitiated) {
            try WorkspaceReplace.plan(root: root, options: options, replacement: replacement)
        }
        planTask = worker
        Task {
            do {
                let result = try await worker.value
                guard generation == planGeneration, !worker.isCancelled else { return }
                plan = result
                selectedURLs = Set(result.changes.map(\.url))
            } catch is CancellationError {
                // The preview was cancelled.
            } catch {
                if generation == planGeneration, !worker.isCancelled {
                    errorMessage = error.localizedDescription
                }
            }
            if generation == planGeneration { isWorking = false }
        }
    }

    private func applyPlan() {
        guard let plan else { return }
        let openURLs = NSDocumentController.shared.documents.compactMap(\.fileURL) +
            [currentDocumentURL].compactMap { $0 } + workspaceStore.openDocumentURLs
        let selection = selectedURLs
        isWorking = true
        isApplying = true
        errorMessage = nil
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try plan.apply(selectedURLs: selection, openDocuments: openURLs)
                }.value
                workspaceStore.refresh(force: true)
                dismiss()
                onComplete()
            } catch {
                errorMessage = error.localizedDescription
                self.plan = nil
            }
            isWorking = false
            isApplying = false
        }
    }

    private func invalidatePlan() {
        planGeneration += 1
        planTask?.cancel()
        plan = nil
        selectedURLs = []
        isWorking = false
    }

    private func patterns(in input: String) -> [String] {
        input.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
