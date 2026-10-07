import CryptoKit
import Foundation
import SwiftUI

struct WorkspaceSnapshotEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let title: String
}

struct WorkspaceSnapshotStore: Sendable {
    let directory: URL

    static var appSupport: Self {
        let root = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return Self(directory: root.appendingPathComponent("MKTownEditor/Snapshots",
                                                            isDirectory: true))
    }

    func entries(for documentURL: URL) throws -> [WorkspaceSnapshotEntry] {
        let index = folder(for: documentURL).appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: index.path) else { return [] }
        return try JSONDecoder().decode([WorkspaceSnapshotEntry].self, from: Data(contentsOf: index))
            .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func save(_ text: String, title: String, for documentURL: URL,
              now: Date = Date()) throws -> WorkspaceSnapshotEntry {
        let folder = folder(for: documentURL)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let entry = WorkspaceSnapshotEntry(id: UUID(), createdAt: now,
                                           title: title.trimmingCharacters(in: .whitespacesAndNewlines))
        let content = contentURL(for: entry, documentURL: documentURL)
        try Data(text.utf8).write(to: content, options: .atomic)
        do {
            var index = try entries(for: documentURL)
            index.insert(entry, at: 0)
            try JSONEncoder().encode(index).write(
                to: folder.appendingPathComponent("index.json"), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: content)
            throw error
        }
        return entry
    }

    func text(for entry: WorkspaceSnapshotEntry, documentURL: URL) throws -> String {
        guard try entries(for: documentURL).contains(where: { $0.id == entry.id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: contentURL(for: entry, documentURL: documentURL))
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }

    func delete(_ entry: WorkspaceSnapshotEntry, documentURL: URL) throws {
        var index = try entries(for: documentURL)
        guard index.contains(where: { $0.id == entry.id }) else { return }
        index.removeAll { $0.id == entry.id }
        try JSONEncoder().encode(index).write(
            to: folder(for: documentURL).appendingPathComponent("index.json"), options: .atomic)
        try FileManager.default.removeItem(at: contentURL(for: entry, documentURL: documentURL))
    }

    private func folder(for documentURL: URL) -> URL {
        let path = documentURL.resolvingSymlinksInPath().standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest, isDirectory: true)
    }

    private func contentURL(for entry: WorkspaceSnapshotEntry, documentURL: URL) -> URL {
        folder(for: documentURL).appendingPathComponent(entry.id.uuidString + ".md")
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
    static func rows(snapshot: String, current: String) -> [WorkspaceSnapshotHunkRow] {
        let oldLines = snapshot.components(separatedBy: "\n")
        let newLines = current.components(separatedBy: "\n")
        return hunks(oldLines: oldLines, newLines: newLines).map { hunk in
            WorkspaceSnapshotHunkRow(hunk: hunk,
                                     currentExcerpt: excerpt(newLines, lines: hunk.currentRange),
                                     snapshotExcerpt: excerpt(oldLines, lines: hunk.snapshotRange))
        }
    }

    static func excerpt(_ lines: [String], lines range: Range<Int>) -> String {
        let value = lines[range].prefix(3).joined(separator: " ⏎ ")
        return value.isEmpty ? String(localized: "（なし）") : String(value.prefix(180))
    }

    private static func hunks(oldLines: [String], newLines: [String]) -> [WorkspaceSnapshotHunk] {
        let difference = newLines.difference(from: oldLines)
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
                List(entries) { entry in
                    Button {
                        select(entry)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(entry.title).fontWeight(selected?.id == entry.id ? .semibold : .regular)
                            Text(entry.createdAt, format: .dateTime.year().month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("削除", role: .destructive) { delete(entry) }
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
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .frame(width: 820, height: 540)
        .padding(18)
        .task { loadEntries() }
        .onChange(of: currentText) { _, _ in compare() }
        .onChange(of: selectedText) { _, _ in compare() }
        .onDisappear { comparisonTask?.cancel() }
    }

    private func loadEntries() {
        do { entries = try store.entries(for: documentURL) }
        catch { errorMessage = error.localizedDescription }
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
        do {
            try store.delete(entry, documentURL: documentURL)
            entries.removeAll { $0.id == entry.id }
            if selected?.id == entry.id { selected = nil; selectedText = nil }
        } catch { errorMessage = error.localizedDescription }
    }

    private func apply(_ restored: String) {
        errorMessage = onApply(restored, currentText)
            ? nil : String(localized: "本文が変更されたか編集中のため、復元できませんでした。")
    }
}
