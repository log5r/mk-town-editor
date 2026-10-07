import AppKit
import Foundation
import SwiftUI

enum BatchExportFormat: String, CaseIterable, Identifiable, Sendable {
    case markdown, html, pdf, plainText

    var id: String { rawValue }
    var title: String {
        switch self {
        case .markdown: "Markdown"
        case .html: "HTML"
        case .pdf: "PDF"
        case .plainText: String(localized: "プレーンテキスト")
        }
    }
    var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .html: "html"
        case .pdf: "pdf"
        case .plainText: "txt"
        }
    }
}

struct BatchExportDocument: Sendable {
    let sourceURL: URL
    let relativePath: String
}

struct BatchExportFailure: Identifiable, Sendable {
    let source: String
    let reason: String
    var id: String { source + "\0" + reason }
}

struct BatchExportReport: Sendable {
    let total: Int
    var exported = 0
    var failures: [BatchExportFailure] = []
    var cancelled = false
}

enum BatchExportError: LocalizedError {
    case invalidSource
    case invalidDestination
    case tooManyFiles
    case destinationExists

    var errorDescription: String? {
        switch self {
        case .invalidSource: String(localized: "対象フォルダを読み取れません。")
        case .invalidDestination: String(localized: "保存先フォルダを使用できません。")
        case .tooManyFiles: String(localized: "対象書類が10,000件を超えています。範囲を狭めてください。")
        case .destinationExists: String(localized: "同名の出力が既にあります。上書きせずにスキップしました。")
        }
    }
}

enum WorkspaceBatchExporter {
    static func documents(in source: URL, excluding destination: URL? = nil) throws -> [BatchExportDocument] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BatchExportError.invalidSource
        }
        let root = source.resolvingSymlinksInPath().standardizedFileURL
        let excluded = destination?.resolvingSymlinksInPath().standardizedFileURL.path
        var result: [BatchExportDocument] = []
        func scan(_ folder: URL, relative: String, depth: Int) throws {
            guard depth <= 16 else { throw BatchExportError.tooManyFiles }
            let entries = try manager.contentsOfDirectory(at: folder,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for entry in entries {
                try Task.checkCancellation()
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { continue }
                if excluded == entry.resolvingSymlinksInPath().standardizedFileURL.path { continue }
                let path = relative.isEmpty ? entry.lastPathComponent : relative + "/" + entry.lastPathComponent
                if values.isDirectory == true {
                    try scan(entry, relative: path, depth: depth + 1)
                } else if ["md", "markdown", "txt"].contains(entry.pathExtension.lowercased()) {
                    result.append(BatchExportDocument(sourceURL: entry, relativePath: path))
                    if result.count > 10_000 { throw BatchExportError.tooManyFiles }
                }
            }
        }
        try scan(root, relative: "", depth: 0)
        return result
    }

    @MainActor
    static func export(documents: [BatchExportDocument], to destination: URL,
                       format: BatchExportFormat, openBuffers: [URL: Data] = [:],
                       dialect: (URL) -> MarkdownDialect = { _ in .extended },
                       progress: (Int, Int) -> Void = { _, _ in }) async throws -> BatchExportReport {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw BatchExportError.invalidDestination }
        var report = BatchExportReport(total: documents.count)
        let manager = FileManager.default
        for document in documents {
            if Task<Never, Never>.isCancelled { report.cancelled = true; break }
            do {
                let relative = (document.relativePath as NSString).deletingPathExtension
                    + "." + format.fileExtension
                let output = destination.appendingPathComponent(relative)
                guard !manager.fileExists(atPath: output.path) else {
                    throw BatchExportError.destinationExists
                }
                let directory = output.deletingLastPathComponent()
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
                let key = document.sourceURL.resolvingSymlinksInPath().standardizedFileURL
                let buffer = openBuffers[key]
                let (data, source) = try await DocumentWork.perform {
                    let data = try buffer ?? Data(contentsOf: document.sourceURL)
                    return (data, try MarkdownDocument.decode(data))
                }
                let temporary = directory.appendingPathComponent(".mktown-batch-\(UUID().uuidString).\(format.fileExtension)")
                defer { try? manager.removeItem(at: temporary) }
                switch format {
                case .markdown:
                    try await DocumentWork.perform { try data.write(to: temporary, options: .atomic) }
                case .html:
                    let rendered = try await MarkdownHTMLExporter.renderAsync(source, documentURL: document.sourceURL,
                                                                dialect: dialect(document.sourceURL))
                    try await DocumentWork.perform { try Data(rendered.utf8).write(to: temporary, options: .atomic) }
                case .plainText:
                    let rendered = try await DocumentWork.perform {
                        MarkdownPlainTextExporter.render(source, options: MarkdownPlainTextOptions())
                    }
                    try await DocumentWork.perform { try Data(rendered.utf8).write(to: temporary, options: .atomic) }
                case .pdf:
                    try await MarkdownPDFExporter.exportAsync(source, documentURL: document.sourceURL,
                                                   to: temporary, dialect: dialect(document.sourceURL))
                }
                if Task<Never, Never>.isCancelled { report.cancelled = true; break }
                guard !manager.fileExists(atPath: output.path) else {
                    throw BatchExportError.destinationExists
                }
                try manager.moveItem(at: temporary, to: output)
                report.exported += 1
            } catch is CancellationError {
                report.cancelled = true; break
            } catch {
                report.failures.append(BatchExportFailure(source: document.relativePath,
                                                          reason: error.localizedDescription))
            }
            progress(report.exported + report.failures.count, report.total)
            await Task.yield()
        }
        return report
    }
}

struct WorkspaceBatchExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspaceStore: WorkspaceStore
    @EnvironmentObject private var settingsStore: EditorSettingsStore
    @State private var source: URL?
    @State private var destination: URL?
    @State private var format: BatchExportFormat = .html
    @State private var completed = 0
    @State private var total = 0
    @State private var running = false
    @State private var result: BatchExportReport?
    @State private var errorMessage: String?
    @State private var exportTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("複数文書を一括書き出し").font(.headline)
            Text("対象フォルダ内の Markdown・テキスト書類を、フォルダ構成を保って書き出します。同名の出力は上書きしません。")
                .font(.caption).foregroundStyle(.secondary)
            folderRow(String(localized: "対象フォルダ"), url: source) { chooseFolder(sourceFolder: true) }
            folderRow(String(localized: "保存先"), url: destination) { chooseFolder(sourceFolder: false) }
            Picker("形式", selection: $format) {
                ForEach(BatchExportFormat.allCases) { value in Text(value.title).tag(value) }
            }
            if running { ProgressView(value: Double(completed), total: Double(max(total, 1))) }
            if running || result != nil { Text("\(completed) / \(total) 件を確認") }
            if let result {
                Text("成功 \(result.exported)件・失敗 \(result.failures.count)件" +
                     (result.cancelled ? String(localized: "・中止しました") : ""))
                if !result.failures.isEmpty {
                    List(result.failures) { failure in
                        VStack(alignment: .leading) {
                            Text(failure.source).fontWeight(.medium)
                            Text(failure.reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(height: 180)
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("閉じる") { dismiss() }.disabled(running).keyboardShortcut(.cancelAction)
                Button(running ? "中止" : "書き出す") {
                    if running { exportTask?.cancel() }
                    else { startExport() }
                }
                .disabled(!running && (source == nil || destination == nil))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 620)
        .onAppear { if source == nil { source = workspaceStore.rootURL } }
        .onDisappear { exportTask?.cancel() }
    }

    private func folderRow(_ title: String, url: URL?, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            Text(url?.path ?? "未選択").lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("選ぶ…", action: action).disabled(running)
        }
    }

    private func chooseFolder(sourceFolder: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if sourceFolder { source = url } else { destination = url }
        }
    }

    private func startExport() {
        guard let source, let destination else { return }
        result = nil
        errorMessage = nil
        completed = 0
        total = 0
        running = true
        let selectedFormat = format
        exportTask = Task {
            do {
                let documents = try await DocumentWork.perform {
                    try WorkspaceBatchExporter.documents(in: source, excluding: destination)
                }
                let buffers = try workspaceStore.openBufferSnapshots(under: source)
                total = documents.count
                result = try await WorkspaceBatchExporter.export(documents: documents,
                    to: destination, format: selectedFormat, openBuffers: buffers,
                    dialect: { settingsStore.markdownDialect(for: $0) },
                    progress: { done, _ in completed = done })
            } catch is CancellationError {
                errorMessage = String(localized: "書き出しを中止しました。")
            } catch {
                errorMessage = error.localizedDescription
            }
            running = false
            exportTask = nil
        }
    }
}
