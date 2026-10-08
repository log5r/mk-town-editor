import AppKit
import SwiftUI

enum WorkspaceFileAction: Identifiable, Sendable {
    case createDocument(URL)
    case createFolder(URL)
    case rename(URL)
    case move(URL)
    case trash(URL)

    var id: String {
        switch self {
        case let .createDocument(url): "document:\(url.path)"
        case let .createFolder(url): "folder:\(url.path)"
        case let .rename(url): "rename:\(url.path)"
        case let .move(url): "move:\(url.path)"
        case let .trash(url): "trash:\(url.path)"
        }
    }

    var sourceURL: URL? {
        switch self {
        case .createDocument, .createFolder: nil
        case let .rename(url), let .move(url), let .trash(url): url
        }
    }
}

struct WorkspaceFileOperationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspaceStore: WorkspaceStore
    @EnvironmentObject private var settingsStore: EditorSettingsStore
    @State private var name: String
    @State private var destinationPath: String
    @State private var template: WorkspaceDocumentTemplate = .blank
    @State private var plan: WorkspaceMovePlan?
    @State private var isWorking = false
    @State private var operationTask: Task<Void, Never>?
    @State private var errorMessage: String?

    let action: WorkspaceFileAction
    let rootURL: URL
    let currentDocumentURL: URL?
    let onComplete: () -> Void

    init(action: WorkspaceFileAction, rootURL: URL, currentDocumentURL: URL?,
         onComplete: @escaping () -> Void) {
        self.action = action
        self.rootURL = rootURL
        self.currentDocumentURL = currentDocumentURL
        self.onComplete = onComplete
        let initialName: String
        switch action {
        case .createDocument: initialName = String(localized: "新規書類.md")
        case .createFolder: initialName = String(localized: "新規フォルダ")
        default: initialName = action.sourceURL?.lastPathComponent ?? ""
        }
        _name = State(initialValue: initialName)
        _destinationPath = State(initialValue: action.sourceURL.map {
            String($0.path.dropFirst(rootURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            switch action {
            case .createDocument, .createFolder, .rename:
                TextField("名前", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isWorking)
                    .onChange(of: name) { _, _ in plan = nil }
            case .move:
                TextField("ワークスペース内の移動先", text: $destinationPath)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isWorking)
                    .onChange(of: destinationPath) { _, _ in plan = nil }
            case .trash:
                Text("ファイルをゴミ箱へ移動します。このファイルを指すリンクは更新されません。")
                    .foregroundStyle(.secondary)
            }
            if case let .createDocument(directory) = action {
                Text("保存先: \(directory.path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Picker("テンプレート", selection: $template) {
                    ForEach(WorkspaceDocumentTemplate.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                Text(template.text.isEmpty ? "本文なし" : template.text)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            if let plan {
                if !plan.skippedDocuments.isEmpty {
                    Text("リンク確認から除外: \(plan.skippedDocuments.count)件")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if plan.isTruncated { Text("ファイル一覧が上限を超えたため、確認結果は一部のみです。") }
                if plan.changes.contains(where: { $0.openOriginalData != nil && $0.linkCount > 0 }) {
                    Text("開いている参照元書類の未保存内容も、リンク更新と一緒に保存されます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(actionIsTrash ? "影響を受けるリンク" : "更新するリンク"): \(plan.changedLinks)件 / 書類: \(plan.changes.filter { $0.linkCount > 0 }.count)件")
                List(plan.changes.filter { $0.linkCount > 0 }, id: \.oldURL) { change in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(change.oldURL.lastPathComponent): \(change.linkCount)件")
                            .font(.subheadline.weight(.semibold))
                        ForEach(change.linkChanges.indices, id: \.self) { index in
                            let link = change.linkChanges[index]
                            Text(actionIsTrash ? link.before : "\(link.before) → \(link.after)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: min(180, CGFloat(max(1, plan.changes.count)) * 54))
            }
            if isWorking { ProgressView("リンクを確認中…") }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(isWorking ? "中止" : "キャンセル") {
                    operationTask?.cancel()
                    if !isWorking { dismiss() }
                }
                    .keyboardShortcut(.cancelAction)
                // Renaming and moving confirm the link check only when there is something to
                // review; otherwise the first Return applies the change (#29).
                Button(actionIsTrash ? "ゴミ箱へ移動" : "適用") {
                    if needsPlan && plan == nil { preparePlan(thenApply: true) } else { apply() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || inputIsEmpty || plan?.isTruncated == true)
            }
        }
        .frame(width: 500)
        .padding(20)
        .interactiveDismissDisabled(isWorking)
        .onDisappear { operationTask?.cancel() }
        .onAppear {
            if actionIsTrash { preparePlan() }
        }
    }

    private var title: String {
        switch action {
        case .createDocument: String(localized: "Markdown書類を作成")
        case .createFolder: String(localized: "フォルダを作成")
        case .rename: String(localized: "名前を変更")
        case .move: String(localized: "ファイルを移動")
        case .trash: String(localized: "ゴミ箱へ移動")
        }
    }

    private var needsPlan: Bool {
        switch action {
        case .rename, .move: true
        default: false
        }
    }

    private var actionIsTrash: Bool {
        if case .trash = action { return true }
        return false
    }

    private var inputIsEmpty: Bool {
        switch action {
        case .createDocument, .createFolder, .rename: name.isEmpty
        case .move: destinationPath.isEmpty
        case .trash: false
        }
    }

    private var destinationURL: URL? {
        switch action {
        case let .rename(source): source.deletingLastPathComponent().appendingPathComponent(name)
        case .move: rootURL.appendingPathComponent(destinationPath)
        default: nil
        }
    }

    /// A plan with nothing to review is applied without a second confirmation.
    static func appliesWithoutReview(_ plan: WorkspaceMovePlan) -> Bool {
        plan.changedLinks == 0 && plan.skippedDocuments.isEmpty && !plan.isTruncated &&
            !plan.changes.contains { $0.openOriginalData != nil && $0.linkCount > 0 }
    }

    private func preparePlan(thenApply: Bool = false) {
        guard let source = action.sourceURL else { return }
        let destination = destinationURL ?? source.deletingLastPathComponent()
            .appendingPathComponent(".trash-preview-\(UUID().uuidString)")
        isWorking = true
        errorMessage = nil
        let openSnapshots: [URL: Data]
        do { openSnapshots = needsPlan ? try workspaceStore.openBufferSnapshots(under: rootURL) : [:] }
        catch {
            errorMessage = error.localizedDescription
            isWorking = false
            return
        }
        operationTask = Task {
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try WorkspaceFileOperations.planMove(source: source, destination: destination,
                                                         root: rootURL,
                                                         openDocuments: openSnapshots)
                }
                let result = try await withTaskCancellationHandler { try await worker.value }
                    onCancel: { worker.cancel() }
                try Task.checkCancellation()
                if actionIsTrash || destinationURL?.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() {
                    plan = result
                    if thenApply && Self.appliesWithoutReview(result) {
                        isWorking = false
                        apply()
                        return
                    }
                }
            } catch is CancellationError {
                // Stop planning without publishing a partial plan.
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func apply() {
        do {
            switch action {
            case .rename, .move:
                guard let plan else { return }
                guard plan.destinationURL == destinationURL?.resolvingSymlinksInPath() else { return }
                try checkOpenDocuments(in: plan)
                try workspaceStore.validateOpenBuffers(in: plan)
            case let .trash(source):
                try checkOpenDocuments(for: source)
            case .createDocument, .createFolder: break
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let action = action
        let root = rootURL
        let enteredName = name
        let selectedText = template.text
        let movePlan = plan
        let lockID = movePlan.flatMap { needsPlan ? workspaceStore.lockOpenDocuments(in: $0) : nil }
        isWorking = true
        operationTask = Task {
            var appliedMove = false
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    switch action {
                    case let .createDocument(directory):
                        _ = try WorkspaceFileOperations.create(name: enteredName, in: directory,
                                                               root: root, folder: false,
                                                               contents: selectedText)
                    case let .createFolder(directory):
                        _ = try WorkspaceFileOperations.create(name: enteredName, in: directory,
                                                               root: root, folder: true)
                    case .rename, .move:
                        guard let movePlan else { throw WorkspaceFileOperationError.workspaceChanged }
                        try movePlan.apply()
                    case let .trash(source):
                        _ = try WorkspaceFileOperations.moveToTrash(source, root: root)
                    }
                }
                try await withTaskCancellationHandler { try await worker.value }
                    onCancel: { worker.cancel() }
                if let movePlan, needsPlan {
                    appliedMove = true
                    try Task.checkCancellation()
                    try movePlan.validateAppliedData()
                    try workspaceStore.applyOpenBufferChanges(in: movePlan)
                }
                switch action {
                case let .rename(source), let .move(source):
                    if let movePlan { workspaceStore.remapPins(from: source, to: movePlan.destinationURL) }
                    if let movePlan { settingsStore.moveBookmarks(under: source, to: movePlan.destinationURL) }
                    if let movePlan {
                        WorkspaceNamedLayoutStore().remapDocuments(from: source,
                            to: movePlan.destinationURL, root: root)
                        // 移動は完了しているので、履歴を移せなくても操作は失敗扱いにしない。
                        // 移せなかった履歴は、書類が見つからないスナップショットとして整理できる。
                        try? await Task.detached(priority: .userInitiated) {
                            try WorkspaceSnapshotStore.appSupport.remap(from: movePlan.sourceURL,
                                                                        to: movePlan.destinationURL)
                        }.value
                    }
                case let .trash(source): workspaceStore.removePins(under: source)
                case .createDocument, .createFolder: break
                }
                dismiss()
                onComplete()
            } catch {
                // A stop requested by the user is not an error to display. Restored
                // documents carry new metadata, so the plan is confirmed again before reuse.
                let cancelled = error is CancellationError
                if appliedMove, let movePlan {
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            try movePlan.rollback()
                        }.value
                        errorMessage = cancelled ? nil : error.localizedDescription
                    } catch {
                        errorMessage = WorkspaceFileOperationError.rollbackFailed.localizedDescription
                    }
                    plan = nil
                } else {
                    if !cancelled { errorMessage = error.localizedDescription }
                    // apply() restores documents it already rewrote before rethrowing, which
                    // gives them new metadata; validation also fails for a changed workspace.
                    // Either way this plan can no longer pass, so ask for a new one.
                    if movePlan != nil, needsPlan { plan = nil }
                }
            }
            if let lockID { workspaceStore.unlockOpenDocuments(lockID) }
            isWorking = false
        }
    }

    private func checkOpenDocuments(in plan: WorkspaceMovePlan) throws {
        try checkOpenDocuments(for: plan.sourceURL)
        let known = Set(plan.changes.compactMap { change in
            change.openOriginalData == nil ? nil : change.oldURL.resolvingSymlinksInPath().path
        })
        let changed = Set(plan.changes.filter { $0.linkCount > 0 }.map {
            $0.oldURL.resolvingSymlinksInPath().path
        })
        for url in allOpenDocumentURLs() {
            let path = url.resolvingSymlinksInPath().path
            if changed.contains(path) && !known.contains(path) { throw WorkspaceOpenDocumentError() }
        }
    }

    private func checkOpenDocuments(for url: URL) throws {
        let openURLs = allOpenDocumentURLs()
        let path = url.resolvingSymlinksInPath().path
        if openURLs.contains(where: {
            let openPath = $0.resolvingSymlinksInPath().path
            return openPath == path || openPath.hasPrefix(path + "/")
        }) {
            throw WorkspaceOpenDocumentError()
        }
    }

    private func allOpenDocumentURLs() -> [URL] {
        NSDocumentController.shared.documents.compactMap(\.fileURL) +
            [currentDocumentURL].compactMap { $0 } + workspaceStore.openDocumentURLs
    }
}

private struct WorkspaceOpenDocumentError: LocalizedError {
    var errorDescription: String? { String(localized: "対象の書類が開いています。保存して閉じてから操作してください。") }
}
