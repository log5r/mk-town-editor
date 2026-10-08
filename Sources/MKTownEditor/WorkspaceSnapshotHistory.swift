import CryptoKit
import Foundation
import SwiftUI

struct WorkspaceSnapshotEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let title: String
}

/// 元の書類が見つからないスナップショットのまとまり。`documentPath` が nil のものは
/// 書類のパスを記録していない以前の形式の索引で、元の書類を特定できない。
struct WorkspaceSnapshotOrphan: Identifiable, Equatable, Sendable {
    let id: String
    let documentPath: String?
    let entries: [WorkspaceSnapshotEntry]
}

/// index.json の内容。以前の形式は項目の配列だけで、書類のパスを持たない。
private struct WorkspaceSnapshotIndex: Codable {
    var documentPath: String?
    var entries: [WorkspaceSnapshotEntry]

    init(documentPath: String? = nil, entries: [WorkspaceSnapshotEntry] = []) {
        self.documentPath = documentPath
        self.entries = entries
    }

    init(from decoder: any Decoder) throws {
        if let legacy = try? decoder.singleValueContainer().decode([WorkspaceSnapshotEntry].self) {
            self.init(entries: legacy)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(documentPath: try container.decodeIfPresent(String.self, forKey: .documentPath),
                  entries: try container.decode([WorkspaceSnapshotEntry].self, forKey: .entries))
    }
}

struct WorkspaceSnapshotStore: Sendable {
    let directory: URL

    /// 保存・削除・付け替えは読み込みから書き込みまでを排他する。ワークスペースのシートと
    /// 書類ウインドウが同じ移動を同時に付け替えると、統合した索引を互いに上書きするため。
    private static let writeLock = NSRecursiveLock()
    /// 書類ウインドウの改名・移動を起きた順に付け替える。
    private static let moveQueue = DispatchQueue(label: "MKTownEditor.WorkspaceSnapshotStore.moves",
                                                 qos: .utility)

    /// 書類があるか、外したボリュームの上にあって有無を判断できない。
    static func documentMayExist(atPath path: String) -> Bool {
        let manager = FileManager.default
        if manager.fileExists(atPath: path) { return true }
        let components = (path as NSString).pathComponents
        guard components.count > 2, components[0] == "/", components[1] == "Volumes" else { return false }
        return !manager.fileExists(atPath: "/Volumes/" + components[2])
    }

    static var appSupport: Self {
        let root = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return Self(directory: root.appendingPathComponent("MKTownEditor/Snapshots",
                                                            isDirectory: true))
    }

    /// 履歴の保存先を決める書類のパス。存在する書類はシンボリックリンクを解決したパスを使う。
    /// 改名・移動後の旧パスのように存在しないパスは、存在する親フォルダまで遡って解決する。
    /// `/private/tmp` のように、存在しないとリンクの解決結果が変わるパスでも同じ保存先にするため。
    static func documentPath(for url: URL) -> String {
        let url = url.standardizedFileURL
        guard !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 else {
            return url.resolvingSymlinksInPath().standardizedFileURL.path
        }
        return (documentPath(for: url.deletingLastPathComponent()) as NSString)
            .appendingPathComponent(url.lastPathComponent)
    }

    func entries(for documentURL: URL) throws -> [WorkspaceSnapshotEntry] {
        try index(in: folder(for: documentURL)).entries.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func save(_ text: String, title: String, for documentURL: URL,
              now: Date = Date()) throws -> WorkspaceSnapshotEntry {
        try Self.writeLock.withLock {
            let path = Self.documentPath(for: documentURL)
            let folder = folder(forPath: path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let entry = WorkspaceSnapshotEntry(id: UUID(), createdAt: now,
                                               title: title.trimmingCharacters(in: .whitespacesAndNewlines))
            let content = contentURL(for: entry, in: folder)
            try Data(text.utf8).write(to: content, options: .atomic)
            do {
                var index = try index(in: folder)
                index.documentPath = path
                index.entries.insert(entry, at: 0)
                try write(index, to: folder)
            } catch {
                try? FileManager.default.removeItem(at: content)
                throw error
            }
            return entry
        }
    }

    func text(for entry: WorkspaceSnapshotEntry, documentURL: URL) throws -> String {
        guard try entries(for: documentURL).contains(where: { $0.id == entry.id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: contentURL(for: entry, in: folder(for: documentURL)))
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }

    func delete(_ entry: WorkspaceSnapshotEntry, documentURL: URL) throws {
        try Self.writeLock.withLock {
            let path = Self.documentPath(for: documentURL)
            let folder = folder(forPath: path)
            var index = try index(in: folder)
            guard index.entries.contains(where: { $0.id == entry.id }) else { return }
            index.entries.removeAll { $0.id == entry.id }
            guard !index.entries.isEmpty else {
                // 最後の項目を消したら保存先ごと消し、空の履歴を残さない。
                try FileManager.default.removeItem(at: folder)
                return
            }
            index.documentPath = path
            try write(index, to: folder)
            do {
                try FileManager.default.removeItem(at: contentURL(for: entry, in: folder))
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // 索引から外せていれば、内容ファイルが既にないことは問題にしない。
            }
        }
    }

    /// 以前の形式の索引に書類のパスを書き加える。履歴を開いた書類は、以後の改名・移動と
    /// 書類が見つからない履歴の判定で、記録したパスから辿れるようになる。
    func recordDocumentPath(for documentURL: URL) throws {
        try Self.writeLock.withLock {
            let path = Self.documentPath(for: documentURL)
            let folder = folder(forPath: path)
            guard FileManager.default.fileExists(atPath: indexURL(in: folder).path) else { return }
            var index = try index(in: folder)
            guard index.documentPath != path else { return }
            index.documentPath = path
            try write(index, to: folder)
        }
    }

    /// 改名・移動した書類の履歴を新しいパスへ移す。書類を移動した後に呼ぶ。
    /// フォルダを移動した場合は、配下の書類の履歴もまとめて移す。
    func remap(from source: URL, to destination: URL) throws {
        try Self.writeLock.withLock {
            // 大文字小文字だけの改名では、旧パスも新しい名前に解決されるため、旧い名前のまま組み立てる。
            let oldBase = source.lastPathComponent != destination.lastPathComponent &&
                Self.sameFile(source, destination)
                ? (Self.documentPath(for: source.deletingLastPathComponent()) as NSString)
                    .appendingPathComponent(source.lastPathComponent)
                : Self.documentPath(for: source)
            let newBase = Self.documentPath(for: destination)
            guard oldBase != newBase else { return }
            let manager = FileManager.default
            var oldPaths: Set<String> = [oldBase]
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue {
                // 索引に記録したパスから、移動したフォルダ配下の履歴を探す。
                for folder in historyFolders() {
                    if let path = try? index(in: folder).documentPath, path.hasPrefix(oldBase + "/") {
                        oldPaths.insert(path)
                    }
                }
                // 以前の形式の索引はパスを持たないため、移動後のファイルから移動前のパスを求める。
                if let enumerator = manager.enumerator(atPath: destination.path) {
                    while let relative = enumerator.nextObject() as? String {
                        guard enumerator.fileAttributes?[.type] as? FileAttributeType == .typeRegular else {
                            continue
                        }
                        oldPaths.insert(oldBase + "/" + relative)
                    }
                }
            }
            // 1件の失敗で残りの履歴を置き去りにしないよう、すべて試してから最初の失敗を報告する。
            var failure: (any Error)?
            for oldPath in oldPaths {
                let newPath = newBase + oldPath.dropFirst(oldBase.count)
                do {
                    try moveHistory(from: folder(forPath: oldPath), to: folder(forPath: newPath),
                                    documentPath: newPath)
                } catch {
                    failure = failure ?? error
                }
            }
            if let failure { throw failure }
        }
    }

    /// 書類ウインドウで改名・移動した書類の履歴を背景で移す。旧パスに書類が残る場合
    /// （別名で保存した場合など）は、元の書類の履歴として残す。
    @discardableResult
    func remapMovedDocument(from source: URL, to destination: URL) -> Task<Void, Never> {
        let (finished, continuation) = AsyncStream<Void>.makeStream()
        Self.moveQueue.async {
            defer { continuation.finish() }
            // 大文字小文字を区別しないボリュームでは、大文字小文字だけの改名で旧パスも存在する。
            guard !FileManager.default.fileExists(atPath: source.path) ||
                    Self.sameFile(source, destination) else { return }
            // 移せなかった履歴は、書類が見つからないスナップショットとして整理画面に表示される。
            try? remap(from: source, to: destination)
        }
        return Task { for await _ in finished {} }
    }

    private static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let left = try? lhs.resourceValues(forKeys: key).fileResourceIdentifier,
              let right = try? rhs.resourceValues(forKeys: key).fileResourceIdentifier else { return false }
        return left.isEqual(right)
    }

    /// 元の書類が見つからない履歴を、書類のパス順に返す。パスを記録していない以前の形式の
    /// 履歴は書類の有無を判定できないため、`documentPath` を nil にして末尾に並べる。
    func orphans(documentExists: (String) -> Bool = documentMayExist(atPath:)) -> [WorkspaceSnapshotOrphan] {
        let found = historyFolders().compactMap { folder -> WorkspaceSnapshotOrphan? in
            guard let index = try? index(in: folder) else { return nil }
            if let path = index.documentPath, documentExists(path) { return nil }
            return WorkspaceSnapshotOrphan(id: folder.lastPathComponent, documentPath: index.documentPath,
                                           entries: index.entries.sorted { $0.createdAt > $1.createdAt })
        }
        return found.sorted { lhs, rhs in
            switch (lhs.documentPath, rhs.documentPath) {
            case let (left?, right?): left.localizedStandardCompare(right) == .orderedAscending
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): (lhs.entries.first?.createdAt ?? .distantPast) >
                (rhs.entries.first?.createdAt ?? .distantPast)
            }
        }
    }

    /// 書類が見つからない履歴を削除する。一覧を作った後に書類が戻っていれば削除せず false を返す。
    @discardableResult
    func deleteOrphan(_ orphan: WorkspaceSnapshotOrphan,
                      documentExists: (String) -> Bool = documentMayExist(atPath:)) throws -> Bool {
        try Self.writeLock.withLock {
            guard orphan.id.count == 64, orphan.id.allSatisfy(\.isHexDigit) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let folder = directory.appendingPathComponent(orphan.id, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { return true }
            if let path = try? index(in: folder).documentPath, documentExists(path) { return false }
            try FileManager.default.removeItem(at: folder)
            return true
        }
    }

    private func moveHistory(from old: URL, to new: URL, documentPath: String) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: old.path) else { return }
        guard manager.fileExists(atPath: new.path) else {
            try manager.moveItem(at: old, to: new)
            // 読めない索引はそのまま移し、パスの記録だけを見送る。
            if var index = try? index(in: new) {
                index.documentPath = documentPath
                try write(index, to: new)
            }
            return
        }
        // 移動先のパスにも履歴がある（以前に同じ名前の書類があった）場合は、両方を残して統合する。
        var source = try index(in: old)
        var target = try index(in: new)
        target.documentPath = documentPath
        for entry in source.entries {
            do {
                try manager.moveItem(at: contentURL(for: entry, in: old),
                                     to: contentURL(for: entry, in: new))
                target.entries.append(entry)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // 内容ファイルを失った項目は移さない。
            } catch {
                // 移せた項目だけを移動先に記録し、残りは元の場所に残す。
                try? write(target, to: new)
                try? write(source, to: old)
                throw error
            }
            source.entries.removeAll { $0.id == entry.id }
        }
        try write(target, to: new)
        try manager.removeItem(at: old)
    }

    private func historyFolders() -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return folders.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private func index(in folder: URL) throws -> WorkspaceSnapshotIndex {
        let url = indexURL(in: folder)
        guard FileManager.default.fileExists(atPath: url.path) else { return WorkspaceSnapshotIndex() }
        return try JSONDecoder().decode(WorkspaceSnapshotIndex.self, from: Data(contentsOf: url))
    }

    private func write(_ index: WorkspaceSnapshotIndex, to folder: URL) throws {
        try JSONEncoder().encode(index).write(to: indexURL(in: folder), options: .atomic)
    }

    private func indexURL(in folder: URL) -> URL {
        folder.appendingPathComponent("index.json")
    }

    private func folder(for documentURL: URL) -> URL {
        folder(forPath: Self.documentPath(for: documentURL))
    }

    private func folder(forPath path: String) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest, isDirectory: true)
    }

    private func contentURL(for entry: WorkspaceSnapshotEntry, in folder: URL) -> URL {
        folder.appendingPathComponent(entry.id.uuidString + ".md")
    }
}

struct WorkspaceSnapshotHunk: Equatable, Sendable {
    let snapshotRange: Range<Int>
    let currentRange: Range<Int>

    var firstCurrentLine: Int { currentRange.lowerBound + 1 }
}

/// 差分の1区間と、表示用の抜粋。抜粋は比較と同じ背景処理で一度だけ作る。
struct WorkspaceSnapshotHunkRow: Equatable, Sendable {
    let hunk: WorkspaceSnapshotHunk
    let currentExcerpt: String
    let snapshotExcerpt: String
}

enum WorkspaceSnapshotDiff {
    static func hunks(snapshot: String, current: String) -> [WorkspaceSnapshotHunk] {
        hunks(oldLines: snapshot.components(separatedBy: "\n"),
              newLines: current.components(separatedBy: "\n"))
    }

    /// 行の配列を一度だけ作り、差分の区間と各区間の抜粋をまとめて求める。
    /// 取り消された比較は、各段階の間で処理を打ち切って空の結果を返す。
    /// 標準ライブラリの差分計算そのものは途中で止められないため、その前後で確認する。
    static func rows(snapshot: String, current: String) -> [WorkspaceSnapshotHunkRow] {
        let oldLines = snapshot.components(separatedBy: "\n")
        guard !Task.isCancelled else { return [] }
        let newLines = current.components(separatedBy: "\n")
        guard !Task.isCancelled else { return [] }
        let found = hunks(oldLines: oldLines, newLines: newLines)
        var rows: [WorkspaceSnapshotHunkRow] = []
        rows.reserveCapacity(found.count)
        for hunk in found {
            guard !Task.isCancelled else { return [] }
            rows.append(WorkspaceSnapshotHunkRow(hunk: hunk,
                                                 currentExcerpt: excerpt(newLines, lines: hunk.currentRange),
                                                 snapshotExcerpt: excerpt(oldLines, lines: hunk.snapshotRange)))
        }
        return rows
    }

    static func excerpt(_ lines: [String], lines range: Range<Int>) -> String {
        let value = lines[range].prefix(3).joined(separator: " ⏎ ")
        return value.isEmpty ? String(localized: "（なし）") : String(value.prefix(180))
    }

    private static func hunks(oldLines: [String], newLines: [String]) -> [WorkspaceSnapshotHunk] {
        let difference = newLines.difference(from: oldLines)
        guard !Task.isCancelled else { return [] }
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        var oldIndex = 0
        var newIndex = 0
        var result: [WorkspaceSnapshotHunk] = []
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if (oldIndex + newIndex) % 4_096 == 0, Task.isCancelled { return [] }
            let oldChanged = removed.contains(oldIndex)
            let newChanged = inserted.contains(newIndex)
            if oldChanged || newChanged {
                let oldStart = oldIndex
                let newStart = newIndex
                while removed.contains(oldIndex) || inserted.contains(newIndex) {
                    if removed.contains(oldIndex) { oldIndex += 1 }
                    if inserted.contains(newIndex) { newIndex += 1 }
                }
                result.append(WorkspaceSnapshotHunk(snapshotRange: oldStart..<oldIndex,
                                                     currentRange: newStart..<newIndex))
            } else {
                oldIndex += 1
                newIndex += 1
            }
        }
        return result
    }

    static func restoring(_ hunk: WorkspaceSnapshotHunk, snapshot: String,
                          current: String) -> String {
        let oldLines = snapshot.components(separatedBy: "\n")
        var newLines = current.components(separatedBy: "\n")
        newLines.replaceSubrange(hunk.currentRange, with: oldLines[hunk.snapshotRange])
        return newLines.joined(separator: "\n")
    }
}

struct WorkspaceSnapshotHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var entries: [WorkspaceSnapshotEntry] = []
    @State private var selected: WorkspaceSnapshotEntry?
    @State private var selectedText: String?
    @State private var comparedText: String?
    @State private var comparedSnapshot: String?
    @State private var comparedRows: [WorkspaceSnapshotHunkRow] = []
    @State private var comparisonGeneration = 0
    @State private var comparisonTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var showingCleanup = false
    @State private var pendingDeletion: WorkspaceSnapshotEntry?

    let documentURL: URL
    @Binding var currentText: String
    let onApply: (String, String) -> Bool
    private let store = WorkspaceSnapshotStore.appSupport

    private var rows: [WorkspaceSnapshotHunkRow] {
        comparedText == currentText && comparedSnapshot == selectedText ? comparedRows : []
    }

    private var isComparing: Bool {
        selectedText != nil && (comparedText != currentText || comparedSnapshot != selectedText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("明示スナップショット").font(.headline)
            Text("macOSの「バージョンを戻す」とは別に、名前を付けた時点を保存します。復元は現在の書類に対する編集としてUndoできます。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("スナップショット名", text: $title)
                Button("現在の本文を保存") { save() }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
            }
            HStack(alignment: .top, spacing: 16) {
                // The selected snapshot is shown on the right, so the arrow keys browse them (#60).
                List(entries, selection: Binding(get: { selected?.id }, set: { id in
                    if let entry = entries.first(where: { $0.id == id }), entry.id != selected?.id { select(entry) }
                })) { entry in
                    VStack(alignment: .leading) {
                        Text(entry.title)
                        Text(entry.createdAt, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                .contextMenu(forSelectionType: WorkspaceSnapshotEntry.ID.self) { ids in
                    if let entry = entries.first(where: { ids.contains($0.id) }) {
                        Button("削除", role: .destructive) { pendingDeletion = entry }
                            .disabled(isWorking)
                    }
                }
                .frame(width: 245)
                VStack(alignment: .leading, spacing: 8) {
                    if let selected, let selectedText {
                        HStack {
                            Text(selected.title).font(.subheadline.weight(.semibold))
                            Spacer()
                            Button("本文全体を復元") { apply(selectedText) }
                                .disabled(selectedText == currentText || isWorking)
                        }
                        if isComparing {
                            ProgressView("差分を比較中")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if rows.isEmpty {
                            ContentUnavailableView("差分はありません", systemImage: "checkmark.circle")
                        } else {
                            List(Array(rows.enumerated()), id: \.offset) { _, row in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("現在の \(row.hunk.firstCurrentLine) 行付近")
                                        .font(.caption.weight(.semibold))
                                    Text("現在: \(row.currentExcerpt)")
                                        .foregroundStyle(.red)
                                    Text("保存時: \(row.snapshotExcerpt)")
                                        .foregroundStyle(.green)
                                    Button("この変更を復元") {
                                        apply(WorkspaceSnapshotDiff.restoring(row.hunk,
                                            snapshot: selectedText, current: currentText))
                                    }
                                    .disabled(isWorking)
                                }
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            }
                        }
                    } else {
                        ContentUnavailableView("履歴を選択", systemImage: "clock.arrow.circlepath")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            if isWorking { ProgressView() }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack {
                Button("書類が見つからないスナップショットを整理…") { showingCleanup = true }
                    .disabled(isWorking)
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .frame(width: 820, height: 540)
        .padding(18)
        .task { await loadEntries() }
        .sheet(isPresented: $showingCleanup, onDismiss: { Task { await loadEntries() } }) {
            WorkspaceSnapshotCleanupSheet(store: store)
        }
        .confirmationDialog(Text("“\(pendingDeletion?.title ?? "")”を削除しますか？"),
                            isPresented: Binding(get: { pendingDeletion != nil },
                                                 set: { if !$0 { pendingDeletion = nil } }),
                            presenting: pendingDeletion) { entry in
            Button("削除", role: .destructive) { delete(entry) }
        } message: { _ in
            Text("このスナップショットの内容は完全に削除されます。この操作は取り消せません。")
        }
        .onChange(of: currentText) { _, _ in compare() }
        .onChange(of: selectedText) { _, _ in compare() }
        .onDisappear { comparisonTask?.cancel() }
    }

    private func loadEntries() async {
        do {
            entries = try await Task.detached(priority: .userInitiated) {
                // 以前の形式の索引に書類のパスを記録し、改名・移動と整理で辿れるようにする。
                try? store.recordDocumentPath(for: documentURL)
                return try store.entries(for: documentURL)
            }.value
            if let selected, !entries.contains(where: { $0.id == selected.id }) {
                self.selected = nil
                selectedText = nil
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func save() {
        isWorking = true
        errorMessage = nil
        let source = currentText
        let name = title
        Task {
            do {
                let entry = try await Task.detached(priority: .userInitiated) {
                    try store.save(source, title: name, for: documentURL)
                }.value
                entries.insert(entry, at: 0)
                selected = entry
                selectedText = source
                title = ""
            } catch { errorMessage = error.localizedDescription }
            isWorking = false
        }
    }

    private func select(_ entry: WorkspaceSnapshotEntry) {
        selected = entry
        selectedText = nil
        errorMessage = nil
        Task {
            do {
                let text = try await Task.detached(priority: .userInitiated) {
                    try store.text(for: entry, documentURL: documentURL)
                }.value
                if selected?.id == entry.id { selectedText = text }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func compare() {
        comparisonGeneration += 1
        let generation = comparisonGeneration
        comparisonTask?.cancel()
        comparisonTask = nil
        comparedText = nil
        comparedSnapshot = nil
        guard let selectedText else { comparedRows = []; return }
        let current = currentText
        comparisonTask = Task {
            // 入力が続く間は比較を始めず、置き換えられた比較は背景処理の前に取り消す。
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            let worker = Task.detached(priority: .userInitiated) {
                WorkspaceSnapshotDiff.rows(snapshot: selectedText, current: current)
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, generation == comparisonGeneration,
                  currentText == current, self.selectedText == selectedText else { return }
            comparedRows = result
            comparedText = current
            comparedSnapshot = selectedText
        }
    }

    private func delete(_ entry: WorkspaceSnapshotEntry) {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try store.delete(entry, documentURL: documentURL)
                }.value
                entries.removeAll { $0.id == entry.id }
                if selected?.id == entry.id { selected = nil; selectedText = nil }
            } catch { errorMessage = error.localizedDescription }
            isWorking = false
        }
    }

    private func apply(_ restored: String) {
        errorMessage = onApply(restored, currentText)
            ? nil : String(localized: "本文が変更されたか編集中のため、復元できませんでした。")
    }
}

/// 改名・移動・削除で元の書類が見つからなくなったスナップショットを一覧し、削除する。
struct WorkspaceSnapshotCleanupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var orphans: [WorkspaceSnapshotOrphan] = []
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var pendingDeletion: [WorkspaceSnapshotOrphan] = []
    @State private var confirmingDeletion = false

    let store: WorkspaceSnapshotStore

    private var missing: [WorkspaceSnapshotOrphan] { orphans.filter { $0.documentPath != nil } }
    private var unknown: [WorkspaceSnapshotOrphan] { orphans.filter { $0.documentPath == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("書類が見つからないスナップショット").font(.headline)
            Text("元の書類を改名・移動・削除したため、どの書類の履歴にも表示されないスナップショットです。書類を元の場所に戻すと、再びその書類の履歴に表示されます。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if orphans.isEmpty {
                ContentUnavailableView("整理するスナップショットはありません",
                                       systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !missing.isEmpty {
                        Section("元の書類が見つからない") {
                            ForEach(missing) { row($0) }
                        }
                    }
                    if !unknown.isEmpty {
                        Section {
                            ForEach(unknown) { row($0) }
                        } header: {
                            Text("元の書類が不明")
                        } footer: {
                            Text("以前のバージョンで保存し、その後に履歴を開いていない書類のスナップショットです。書類が残っている場合は、その書類の履歴を開くとこの一覧に表示されなくなります。")
                        }
                    }
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack {
                // 書類の有無を判定できない以前の形式の履歴は、まとめて削除する対象に含めない。
                Button("元の書類が見つからないものをすべて削除", role: .destructive) {
                    confirmDeletion(of: missing)
                }
                .disabled(missing.isEmpty || isWorking)
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .frame(width: 560, height: 440)
        .padding(18)
        .task { await load() }
        .confirmationDialog(deletionTitle, isPresented: $confirmingDeletion,
                            presenting: pendingDeletion) { targets in
            Button("削除", role: .destructive) { delete(targets) }
        } message: { targets in
            Text("\(targets.reduce(0) { $0 + $1.entries.count })件のスナップショットを削除します。この操作は取り消せません。")
        }
    }

    private var deletionTitle: String {
        if pendingDeletion.count == 1, let orphan = pendingDeletion.first {
            return String(localized: "“\(displayName(orphan))”のスナップショットを削除しますか？")
        }
        return String(localized: "\(pendingDeletion.count)件の書類のスナップショットを削除しますか？")
    }

    private func row(_ orphan: WorkspaceSnapshotOrphan) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName(orphan)).fontWeight(.medium)
                if let path = orphan.documentPath {
                    Text(path)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(path)
                }
                if let latest = orphan.entries.first {
                    Text("\(orphan.entries.count)件・最新 \(latest.createdAt.formatted(.dateTime.year().month().day().hour().minute()))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("削除", systemImage: "trash", role: .destructive) { confirmDeletion(of: [orphan]) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(isWorking)
                .help("このスナップショットを削除")
        }
    }

    /// 書類名を示せない以前の形式の履歴は、スナップショット名で見分けられるようにする。
    private func displayName(_ orphan: WorkspaceSnapshotOrphan) -> String {
        if let path = orphan.documentPath { return URL(fileURLWithPath: path).lastPathComponent }
        let titles = orphan.entries.prefix(3).map(\.title).joined(separator: "、")
        return titles.isEmpty ? String(localized: "元の書類が不明") : titles
    }

    private func load() async {
        let store = store
        orphans = await Task.detached(priority: .userInitiated) { store.orphans() }.value
        isLoading = false
    }

    private func confirmDeletion(of targets: [WorkspaceSnapshotOrphan]) {
        guard !targets.isEmpty else { return }
        pendingDeletion = targets
        confirmingDeletion = true
    }

    private func delete(_ targets: [WorkspaceSnapshotOrphan]) {
        isWorking = true
        errorMessage = nil
        let store = store
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    for orphan in targets { try store.deleteOrphan(orphan) }
                }.value
            } catch { errorMessage = error.localizedDescription }
            // 一覧を作った後に書類が戻った履歴は削除しないため、結果は読み直して反映する。
            await load()
            isWorking = false
        }
    }
}
