import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum ExternalDocumentFormat: String, CaseIterable, Identifiable, Sendable {
    case docx
    case odt
    case epub

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var pandocWriter: String { self == .epub ? "epub3" : rawValue }
}

enum ExternalConversionError: LocalizedError, Equatable {
    case toolMissing
    case toolNotExecutable
    case conversionFailed(String)
    case emptyOutput
    case destinationChanged
    case cancelled

    var errorDescription: String? {
        switch self {
        case .toolMissing: String(localized: "Pandocが見つかりません。公式サイトから任意で導入し、実行ファイルを指定してください。")
        case .toolNotExecutable: String(localized: "指定したPandocを実行できません。ファイルと実行権限を確認してください。")
        case let .conversionFailed(message): String(localized: "変換に失敗しました: \(message)")
        case .emptyOutput: String(localized: "変換器が空のファイルを返しました。")
        case .destinationChanged: String(localized: "書き出し先が変換中に変更されました。もう一度保存先を選んでください。")
        case .cancelled: String(localized: "変換を中止しました。")
        }
    }
}

struct ExternalDocumentConverter: Sendable {
    static func findPandoc(environment: [String: String] = ProcessInfo.processInfo.environment,
                           fileManager: FileManager = .default) -> URL? {
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = path + ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        for directory in candidates {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("pandoc")
            if isUsableExecutable(url, fileManager: fileManager) { return url }
        }
        return nil
    }

    static func isUsableExecutable(_ url: URL,
                                   fileManager: FileManager = .default) -> Bool {
        fileManager.isExecutableFile(atPath: url.path) &&
            (try? url.resolvingSymlinksInPath()
                .resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    static func arguments(input: URL, output: URL, format: ExternalDocumentFormat,
                          resourceDirectory: URL?, dialect: MarkdownDialect) -> [String] {
        var values = ["-f", dialect == .basic ? "commonmark" : "markdown",
                      "-t", format.pandocWriter, "--standalone",
                      "-o", output.path]
        if let resourceDirectory {
            values += ["--resource-path", resourceDirectory.path]
        }
        values.append(input.path)
        return values
    }

    static func convert(_ markdown: String, documentURL: URL?, destination: URL,
                        format: ExternalDocumentFormat, dialect: MarkdownDialect,
                        executable: URL) throws {
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw ExternalConversionError.toolMissing
        }
        guard isUsableExecutable(executable) else {
            throw ExternalConversionError.toolNotExecutable
        }
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("mktown-convert-\(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let input = work.appendingPathComponent("input.md")
        try Data(markdown.utf8).write(to: input, options: .atomic)
        let output = destination.deletingLastPathComponent()
            .appendingPathComponent(".mktown-output-\(UUID().uuidString).\(format.rawValue)")
        defer { try? manager.removeItem(at: output) }
        let original = try fingerprint(destination)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(input: input, output: output, format: format,
            resourceDirectory: documentURL?.deletingLastPathComponent(), dialect: dialect)
        let errorLog = work.appendingPathComponent("stderr.txt")
        try Data().write(to: errorLog)
        let errorHandle = try FileHandle(forWritingTo: errorLog)
        defer { try? errorHandle.close() }
        process.standardError = errorHandle
        process.standardOutput = FileHandle.nullDevice
        if Task<Never, Never>.isCancelled { throw ExternalConversionError.cancelled }
        do { try process.run() }
        catch { throw ExternalConversionError.toolNotExecutable }
        while process.isRunning {
            if Task<Never, Never>.isCancelled {
                process.terminate()
                process.waitUntilExit()
                throw ExternalConversionError.cancelled
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        if Task<Never, Never>.isCancelled { throw ExternalConversionError.cancelled }
        let readHandle = try FileHandle(forReadingFrom: errorLog)
        let errorData = (try? readHandle.read(upToCount: 2000)) ?? Data()
        try? readHandle.close()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData.prefix(2000), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ExternalConversionError.conversionFailed(
                message.isEmpty ? String(localized: "終了コード \(process.terminationStatus)") : message)
        }
        guard manager.fileExists(atPath: output.path),
              let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0 else { throw ExternalConversionError.emptyOutput }
        guard try fingerprint(destination) == original else {
            throw ExternalConversionError.destinationChanged
        }
        if Task<Never, Never>.isCancelled { throw ExternalConversionError.cancelled }
        if original == nil {
            try manager.moveItem(at: output, to: destination)
        } else {
            _ = try manager.replaceItemAt(destination, withItemAt: output)
        }
    }

    private static func fingerprint(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(values.fileSize ?? -1):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }
}

struct ExternalConversionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var format: ExternalDocumentFormat = .docx
    @AppStorage("MKTownEditor.pandocPath") private var executablePath = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var completedURL: URL?
    @State private var conversionTask: Task<Void, Error>?

    let markdown: String
    let documentURL: URL?
    let dialect: MarkdownDialect

    private var isExecutable: Bool {
        !executablePath.isEmpty && ExternalDocumentConverter.isUsableExecutable(
            URL(fileURLWithPath: executablePath))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("外部変換器で書き出し").font(.headline)
            Text("DOCX・ODT・EPUB には任意導入の Pandoc を使います。画像は書類のフォルダから解決します。Pandocの構文解釈により、独自の画像幅指定などは変わる場合があります。")
                .font(.caption).foregroundStyle(.secondary)
            Picker("形式", selection: $format) {
                ForEach(ExternalDocumentFormat.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            HStack {
                TextField("Pandoc の実行ファイル", text: $executablePath)
                Button("選択…") { chooseExecutable() }
            }
            if executablePath.isEmpty {
                Link("Pandocが見つかりません。公式サイトから任意で導入できます。",
                     destination: URL(string: "https://pandoc.org/installing.html")!)
                    .font(.caption)
            } else if !isExecutable {
                Text("指定した実行ファイルが見つからないか、実行権限がありません。")
                    .font(.caption).foregroundStyle(.red)
            }
            Text("入力構文: \(dialect == .basic ? "CommonMark" : "Pandoc Markdown")。画像幅など一部の拡張は変換先で再現できない場合があります。")
                .font(.caption).foregroundStyle(.secondary)
            if isWorking { ProgressView("変換中") }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            if let completedURL { Text("保存しました: \(completedURL.path)").textSelection(.enabled) }
            HStack {
                Spacer()
                if isWorking {
                    Button("中止") { conversionTask?.cancel() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                Button("書き出し…") { chooseDestination() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || !isExecutable)
            }
        }
        .padding(20)
        .frame(width: 600)
        .interactiveDismissDisabled(isWorking)
        .onAppear {
            if executablePath.isEmpty {
                executablePath = ExternalDocumentConverter.findPandoc()?.path ?? ""
            }
        }
        .onDisappear { conversionTask?.cancel() }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.begin { response in
            if response == .OK, let url = panel.url { executablePath = url.path }
        }
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: format.rawValue) {
            panel.allowedContentTypes = [type]
        }
        panel.nameFieldStringValue = (documentURL?.deletingPathExtension().lastPathComponent ?? "document")
            + ".\(format.rawValue)"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            convert(to: destination)
        }
    }

    private func convert(to destination: URL) {
        let source = markdown
        let sourceURL = documentURL
        let selectedFormat = format
        let selectedDialect = dialect
        let executable = URL(fileURLWithPath: executablePath)
        isWorking = true
        errorMessage = nil
        completedURL = nil
        let worker = Task.detached(priority: .userInitiated) {
            try ExternalDocumentConverter.convert(source, documentURL: sourceURL,
                destination: destination, format: selectedFormat,
                dialect: selectedDialect, executable: executable)
        }
        conversionTask = worker
        Task {
            do {
                try await worker.value
                completedURL = destination
            } catch { errorMessage = error.localizedDescription }
            isWorking = false
            conversionTask = nil
        }
    }
}
