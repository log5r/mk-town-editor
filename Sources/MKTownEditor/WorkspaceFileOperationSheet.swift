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
    @State private var name: String
    @State private var destinationPath: String
    @State private var template: WorkspaceDocumentTemplate = .blank
    @State private var plan: WorkspaceMovePlan?
    @State private var isWorking = false
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
        case .createDocument: initialName = "新規書類.md"
        case .createFolder: initialName = "新規フォルダ"
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
                    .onChange(of: name) { _, _ in plan = nil }
            case .move:
                TextField("ワークスペース内の移動先", text: $destinationPath)
                    .textFieldStyle(.roundedBorder)
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
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if needsPlan && plan == nil {
                    Button("変更を確認") { preparePlan() }
                        .disabled(isWorking || inputIsEmpty)
                } else {
                    Button(actionIsTrash ? "ゴミ箱へ移動" : "適用") { apply() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isWorking || inputIsEmpty || (actionIsTrash && plan == nil))
                }
            }
        }
        .frame(width: 500)
        .padding(20)
        .onAppear {
            if actionIsTrash { preparePlan() }
        }
    }

    private var title: String {
        switch action {
        case .createDocument: "Markdown書類を作成"
        case .createFolder: "フォルダを作成"
        case .rename: "名前を変更"
        case .move: "ファイルを移動"
        case .trash: "ゴミ箱へ移動"
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

    private func preparePlan() {
        guard let source = action.sourceURL else { return }
        let destination = destinationURL ?? source.deletingLastPathComponent()
            .appendingPathComponent(".trash-preview-\(UUID().uuidString)")
        isWorking = true
        errorMessage = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try WorkspaceFileOperations.planMove(source: source, destination: destination,
                                                         root: rootURL)
                }.value
                if actionIsTrash || destinationURL?.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() {
                    plan = result
                }
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
        isWorking = true
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
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
                        guard let movePlan else { throw WorkspaceFileOperationError.workspaceChanged }
                        try movePlan.validateCurrentState()
                        _ = try WorkspaceFileOperations.moveToTrash(source, root: root)
                    }
                }.value
                switch action {
                case let .rename(source), let .move(source):
                    if let movePlan { workspaceStore.remapPins(from: source, to: movePlan.destinationURL) }
                case let .trash(source): workspaceStore.removePins(under: source)
                case .createDocument, .createFolder: break
                }
                dismiss()
                onComplete()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func checkOpenDocuments(in plan: WorkspaceMovePlan) throws {
        let affected = [plan.sourceURL] + plan.changes.map(\.oldURL)
        for url in affected { try checkOpenDocuments(for: url) }
    }

    private func checkOpenDocuments(for url: URL) throws {
        let openURLs = NSDocumentController.shared.documents.compactMap(\.fileURL) +
            [currentDocumentURL].compactMap { $0 } + workspaceStore.openDocumentURLs
        let path = url.resolvingSymlinksInPath().path
        if openURLs.contains(where: {
            let openPath = $0.resolvingSymlinksInPath().path
            return openPath == path || openPath.hasPrefix(path + "/")
        }) {
            throw WorkspaceOpenDocumentError()
        }
    }
}

private struct WorkspaceOpenDocumentError: LocalizedError {
    var errorDescription: String? { "対象の書類が開いています。保存して閉じてから操作してください。" }
}
