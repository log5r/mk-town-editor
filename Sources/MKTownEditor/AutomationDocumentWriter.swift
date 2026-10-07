import AppKit
import AppIntents
import Darwin
import Foundation

/// File creation shared by Services and Shortcuts. A destination must already be authorized by the caller.
enum AutomationDocumentWriter {
    enum WriterError: LocalizedError, Equatable {
        case emptyText
        case invalidName
        case invalidFolder
        case destinationExists
        case invalidSource

        var errorDescription: String? {
            switch self {
            case .emptyText: String(localized: "保存するテキストがありません。")
            case .invalidName: String(localized: "ファイル名を確認してください。")
            case .invalidFolder: String(localized: "保存先フォルダが見つかりません。")
            case .destinationExists: String(localized: "同名のファイルが既にあります。")
            case .invalidSource: String(localized: "Markdown書類を読み取れません。")
            }
        }
    }

    static func destination(folderPath: String, fileName: String, extension ext: String) throws -> URL {
        guard !folderPath.isEmpty else { throw WriterError.invalidFolder }
        let folder = URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath,
                         isDirectory: true).standardizedFileURL
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &directory),
              directory.boolValue else { throw WriterError.invalidFolder }
        guard !fileName.isEmpty, fileName != ".", fileName != "..",
              !fileName.contains("/"), !fileName.contains(":") else { throw WriterError.invalidName }
        let stem = fileName.lowercased().hasSuffix(".\(ext)")
            ? String(fileName.dropLast(ext.count + 1)) : fileName
        guard !stem.isEmpty, stem != ".", stem != ".." else { throw WriterError.invalidName }
        return folder.appendingPathComponent(stem).appendingPathExtension(ext)
    }

    static func save(_ text: String, at destination: URL) throws {
        guard !text.isEmpty else { throw WriterError.emptyText }
        guard destination.isFileURL else { throw WriterError.invalidName }
        let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else {
            if errno == EEXIST { throw WriterError.destinationExists }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    @MainActor
    static func exportHTMLAsync(source: URL, to destination: URL) async throws {
        guard source.isFileURL, ["md", "markdown", "mdown", "mkd", "txt"]
            .contains(source.pathExtension.lowercased()) else { throw WriterError.invalidSource }
        let text = try await DocumentWork.perform {
            let data = try Data(contentsOf: source)
            guard let document = try? MarkdownDocument(data: data) else { throw WriterError.invalidSource }
            return document.text
        }
        let html = try await MarkdownHTMLExporter.renderAsync(text, documentURL: source)
        try await DocumentWork.commit { try save(html, at: destination) }
    }

    @MainActor
    static func exportHTML(source: URL, to destination: URL) throws {
        guard source.isFileURL, ["md", "markdown", "mdown", "mkd", "txt"]
            .contains(source.pathExtension.lowercased()) else { throw WriterError.invalidSource }
        let data = try Data(contentsOf: source)
        guard let document = try? MarkdownDocument(data: data) else { throw WriterError.invalidSource }
        let html = MarkdownHTMLExporter.render(document.text, documentURL: source)
        try save(html, at: destination)
    }
}

struct SaveMarkdownAutomationIntent: AppIntent {
    static let title: LocalizedStringResource = "Markdown書類を保存"
    static let description = IntentDescription("テキストを指定したフォルダにMarkdown書類として保存します。")

    @Parameter(title: "本文") var text: String
    @Parameter(title: "保存先フォルダのパス") var folderPath: String
    @Parameter(title: "ファイル名") var fileName: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let url = try AutomationDocumentWriter.destination(folderPath: folderPath,
            fileName: fileName, extension: "md")
        try AutomationDocumentWriter.save(text, at: url)
        return .result(value: url.path)
    }
}

struct ExportMarkdownHTMLAutomationIntent: AppIntent {
    static let title: LocalizedStringResource = "MarkdownをHTMLに書き出す"
    static let description = IntentDescription("保存済みMarkdown書類を指定したフォルダにHTMLとして書き出します。")

    @Parameter(title: "元のMarkdown書類のパス") var sourcePath: String
    @Parameter(title: "保存先フォルダのパス") var folderPath: String
    @Parameter(title: "ファイル名") var fileName: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let source = URL(fileURLWithPath: (sourcePath as NSString).expandingTildeInPath)
        let url = try AutomationDocumentWriter.destination(folderPath: folderPath,
            fileName: fileName, extension: "html")
        try await AutomationDocumentWriter.exportHTMLAsync(source: source, to: url)
        return .result(value: url.path)
    }
}

@MainActor
final class MarkdownSelectionService: NSObject {
    @objc func saveSelectionAsMarkdown(_ pasteboard: NSPasteboard, userData: String?,
                                       error serviceError: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            serviceError.pointee = String(localized: "選択テキストがありません。") as NSString
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = String(localized: "選択テキスト.md")
        panel.allowedContentTypes = [MarkdownDocument.markdownType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try AutomationDocumentWriter.save(text, at: url)
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, openError in
                if let openError { NSApp.presentError(openError) }
            }
        } catch {
            serviceError.pointee = error.localizedDescription as NSString
        }
    }
}
