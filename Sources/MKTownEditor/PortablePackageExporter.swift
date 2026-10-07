import AppKit
import Darwin
import Foundation
import SwiftUI

enum PortablePackageFormat: String, CaseIterable, Identifiable, Sendable {
    case markdown
    case html

    var id: String { rawValue }
    var title: String { self == .markdown ? "Markdown" : "HTML" }
    var fileName: String { self == .markdown ? "index.md" : "index.html" }
}

enum PortablePackageError: LocalizedError, Equatable {
    case unsavedDocument
    case invalidName
    case destinationExists
    case missingResource(String)
    case externalImage(String)
    case resourceTooLarge
    case archiveFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unsavedDocument: String(localized: "画像の相対パスを解決するため、先に書類を保存してください。")
        case .invalidName: String(localized: "パッケージ名にはフォルダ名に使える文字を指定してください。")
        case .destinationExists: String(localized: "同じ名前の出力が既にあります。別の名前を指定してください。")
        case let .missingResource(path): String(localized: "参照ファイルが見つかりません: \(path)")
        case let .externalImage(path): String(localized: "外部画像はパッケージに含められません: \(path)")
        case .resourceTooLarge: String(localized: "参照ファイルの合計が500MBを超えています。")
        case let .archiveFailed(message): String(localized: "ZIPの作成に失敗しました: \(message)")
        case .cancelled: String(localized: "書き出しを中止しました。")
        }
    }
}

struct PortablePackageAsset: Sendable {
    let sourceURL: URL
    let relativePath: String
}

struct PortablePackagePlan: Sendable {
    let markdown: String
    let html: String
    let assets: [PortablePackageAsset]
}

enum PortablePackagePlanner {
    @MainActor
    static func plan(source: String, documentURL: URL,
                     dialect: MarkdownDialect = .extended) throws -> PortablePackagePlan {
        try planPrepared(source: source, documentURL: documentURL, dialect: dialect,
            renderedHTML: MarkdownHTMLExporter.render(source, documentURL: documentURL, dialect: dialect))
    }

    @MainActor
    static func planAsync(source: String, documentURL: URL,
                          dialect: MarkdownDialect = .extended) async throws -> PortablePackagePlan {
        let html = try await MarkdownHTMLExporter.renderAsync(source, documentURL: documentURL, dialect: dialect)
        return try await DocumentWork.perform {
            try planPrepared(source: source, documentURL: documentURL, dialect: dialect, renderedHTML: html)
        }
    }

    private static func planPrepared(source: String, documentURL: URL,
                                     dialect: MarkdownDialect, renderedHTML: String) throws -> PortablePackagePlan {
        let context = DocumentContext(fileURL: documentURL, markdownDialect: dialect)
        guard context.directoryURL != nil else { throw PortablePackageError.unsavedDocument }
        let analysis = MarkdownAnalysis(source, dialect: dialect)
        let masked = NSMutableString(string: source)
        for block in analysis.blocks.filter({ $0.kind == .codeBlock })
            .sorted(by: { $0.sourceRange.location > $1.sourceRange.location }) {
            masked.replaceCharacters(in: block.sourceRange,
                with: String(repeating: " ", count: block.sourceRange.length))
        }
        for range in MarkdownInlineSyntax.codeSpanRanges(in: masked as String)
            .sorted(by: { $0.location > $1.location }) {
            masked.replaceCharacters(in: range,
                with: String(repeating: " ", count: range.length))
        }
        let visible = masked as String
        var changes: [Int: (range: NSRange, replacement: String)] = [:]
        var destinations: [URL: String] = [:]
        var names = Set<String>()
        var assets: [PortablePackageAsset] = []

        func localPathAndSuffix(_ destination: String) -> (String, String) {
            let split = destination.firstIndex(where: { $0 == "#" || $0 == "?" })
            guard let split else { return (destination, "") }
            return (String(destination[..<split]), String(destination[split...]))
        }

        func packagedPath(for destination: String, image: Bool) throws -> String? {
            try Task.checkCancellation()
            let (path, suffix) = localPathAndSuffix(destination)
            guard let url = context.resolveLocalResource(path) else {
                if image { throw PortablePackageError.externalImage(destination) }
                return nil
            }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { throw PortablePackageError.missingResource(destination) }
            if let existing = destinations[resolved] { return existing + suffix }
            let stem = resolved.deletingPathExtension().lastPathComponent
            let ext = resolved.pathExtension
            var name = resolved.lastPathComponent
            var index = 2
            while names.contains(name.lowercased()) {
                name = "\(stem)-\(index)" + (ext.isEmpty ? "" : ".\(ext)")
                index += 1
            }
            names.insert(name.lowercased())
            let relative = "assets/\(name)"
            destinations[resolved] = relative
            assets.append(PortablePackageAsset(sourceURL: resolved, relativePath: relative))
            return relative + suffix
        }

        func shouldPackage(_ destination: String, image: Bool) -> Bool {
            if image { return true }
            guard !destination.hasPrefix("#"), URL(string: destination)?.scheme == nil else { return false }
            let (path, _) = localPathAndSuffix(destination)
            return !["md", "markdown"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
        }

        for link in MarkdownLinkSyntax.inlineLinks(in: visible)
            where shouldPackage(link.destination, image: link.isImage) {
            guard let relative = try packagedPath(for: link.destination, image: link.isImage)
            else { continue }
            changes[link.destinationRange.location] = (link.destinationRange,
                MarkdownLinkSyntax.escapeDestination(relative))
        }

        let referencePattern = try! NSRegularExpression(
            pattern: #"(!?)\[([^\]]+)\](?:\[([^\]]*)\])?"#)
        let matches = referencePattern.matches(in: visible,
            range: NSRange(location: 0, length: (visible as NSString).length))
        let original = source as NSString
        for match in matches {
            let end = NSMaxRange(match.range)
            if end < original.length,
               [40, 58].contains(original.character(at: end)) { continue }
            let isImage = match.range(at: 1).length > 0
            let label = original.substring(with: match.range(at: 2))
            let explicit = match.range(at: 3)
            let key = explicit.location == NSNotFound || explicit.length == 0
                ? label : original.substring(with: explicit)
            guard let reference = analysis.references[MarkdownAnalysis.normalizedReferenceLabel(key)]
            else { continue }
            guard shouldPackage(reference.destination, image: isImage),
                  let relative = try packagedPath(for: reference.destination, image: isImage)
            else { continue }
            let definition = original.substring(with: reference.sourceRange)
            let destinationPattern = try! NSRegularExpression(
                pattern: #"^\s{0,3}\[[^\]]+\]:\s*(?:<([^>]+)>|(\S+))"#)
            guard let parsed = destinationPattern.firstMatch(in: definition,
                range: NSRange(location: 0, length: (definition as NSString).length)) else { continue }
            let capture = parsed.range(at: 1).location == NSNotFound
                ? parsed.range(at: 2) : parsed.range(at: 1)
            let range = NSRange(location: reference.sourceRange.location + capture.location,
                                length: capture.length)
            changes[range.location] = (range, MarkdownLinkSyntax.escapeDestination(relative))
        }

        let rewritten = NSMutableString(string: source)
        for edit in changes.values.sorted(by: { $0.range.location > $1.range.location }) {
            rewritten.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        let html = rewriteHTMLAttachmentLinks(renderedHTML, context: context,
                                              destinations: destinations)
        return PortablePackagePlan(markdown: rewritten as String, html: html, assets: assets)
    }

    private static func rewriteHTMLAttachmentLinks(_ html: String, context: DocumentContext,
                                                    destinations: [URL: String]) -> String {
        let pattern = try! NSRegularExpression(pattern: #"<a href="([^"]+)""#)
        let original = html as NSString
        let output = NSMutableString(string: html)
        for match in pattern.matches(in: html, range: NSRange(location: 0, length: original.length)).reversed() {
            let range = match.range(at: 1)
            let escaped = original.substring(with: range)
            let destination = escaped.replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&#39;", with: "'")
            let split = destination.firstIndex(where: { $0 == "#" || $0 == "?" })
            let path = split.map { String(destination[..<$0]) } ?? destination
            guard let url = context.resolveLocalResource(path),
                  let relative = destinations[url.resolvingSymlinksInPath().standardizedFileURL]
            else { continue }
            let suffix = split.map { String(destination[$0...]) } ?? ""
            let replacement = (relative + suffix).replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
            output.replaceCharacters(in: range, with: replacement)
        }
        return output as String
    }
}

enum PortablePackageExporter {
    static func export(_ plan: PortablePackagePlan, to parent: URL, name: String,
                       format: PortablePackageFormat, zip: Bool,
                       archiveExecutable: URL = URL(fileURLWithPath: "/usr/bin/ditto")) throws -> URL {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName != ".", cleanName != "..",
              !cleanName.contains("/"), !cleanName.contains(":") else {
            throw PortablePackageError.invalidName
        }
        let manager = FileManager.default
        let destination = parent.appendingPathComponent(cleanName + (zip ? ".zip" : ""),
                                                        isDirectory: !zip)
        guard !manager.fileExists(atPath: destination.path) else {
            throw PortablePackageError.destinationExists
        }
        let staging = parent.appendingPathComponent(".mktown-package-\(UUID().uuidString)",
                                                    isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let resources = staging.appendingPathComponent("assets", isDirectory: true)
        try manager.createDirectory(at: resources, withIntermediateDirectories: false)
        var totalSize = 0
        for asset in plan.assets {
            if Task<Never, Never>.isCancelled { throw PortablePackageError.cancelled }
            let values = try asset.sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else {
                throw PortablePackageError.missingResource(asset.sourceURL.path)
            }
            totalSize += values.fileSize ?? 0
            guard totalSize <= 500_000_000 else { throw PortablePackageError.resourceTooLarge }
            let target = staging.appendingPathComponent(asset.relativePath)
            try manager.copyItem(at: asset.sourceURL, to: target)
        }
        let document = format == .markdown ? plan.markdown : plan.html
        try Data(document.utf8).write(to: staging.appendingPathComponent(format.fileName),
                                      options: .atomic)
        if Task<Never, Never>.isCancelled { throw PortablePackageError.cancelled }
        if zip {
            let temporaryZip = parent.appendingPathComponent(".mktown-package-\(UUID().uuidString).zip")
            defer { try? manager.removeItem(at: temporaryZip) }
            try createArchive(from: staging, to: temporaryZip, executable: archiveExecutable)
            if Task<Never, Never>.isCancelled { throw PortablePackageError.cancelled }
            try manager.moveItem(at: temporaryZip, to: destination)
        } else {
            try manager.moveItem(at: staging, to: destination)
        }
        return destination
    }

    private static func createArchive(from staging: URL, to output: URL, executable: URL) throws {
        let errorLog = output.deletingLastPathComponent().appendingPathComponent(".mktown-archive-errors-\(UUID().uuidString)")
        try Data().write(to: errorLog)
        defer { try? FileManager.default.removeItem(at: errorLog) }
        let errors = try FileHandle(forWritingTo: errorLog)
        defer { try? errors.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-c", "-k", staging.path, output.path]
        // A pipe read would wait for compression to finish before cancellation
        // could be checked. A file lets the worker monitor the child instead.
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        if Task<Never, Never>.isCancelled { throw PortablePackageError.cancelled }
        try process.run()
        while process.isRunning {
            if Task<Never, Never>.isCancelled {
                process.terminate()
                let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
                while process.isRunning && ContinuousClock.now < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw PortablePackageError.cancelled
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        if Task<Never, Never>.isCancelled { throw PortablePackageError.cancelled }
        guard process.terminationStatus == 0 else {
            let reader = try FileHandle(forReadingFrom: errorLog)
            defer { try? reader.close() }
            let data = try reader.read(upToCount: 2_000) ?? Data()
            throw PortablePackageError.archiveFailed(String(decoding: data, as: UTF8.self))
        }
    }
}

struct PortablePackageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = "package"
    @State private var format: PortablePackageFormat = .markdown
    @State private var zip = false
    @State private var isWorking = false
    @State private var operationTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var completedURL: URL?

    let source: String
    let documentURL: URL?
    let dialect: MarkdownDialect

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("持ち出し用パッケージ").font(.headline)
            Text("書類と参照ファイルを1つのフォルダまたはZIPにまとめます。欠落ファイルがあれば出力を中止します。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("パッケージ名", text: $name)
            Picker("本文形式", selection: $format) {
                ForEach(PortablePackageFormat.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            Toggle("ZIPで保存", isOn: $zip)
            if isWorking { ProgressView("書き出し中") }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            if let completedURL { Text("保存しました: \(completedURL.path)").textSelection(.enabled) }
            HStack {
                Spacer()
                Button(isWorking ? "中止" : "閉じる") {
                    if isWorking { operationTask?.cancel() } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
                Button("保存先を選ぶ…") { chooseParent() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || documentURL == nil)
            }
        }
        .padding(20)
        .frame(width: 540)
        .interactiveDismissDisabled(isWorking)
        .onDisappear { operationTask?.cancel() }
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let parent = panel.url, let documentURL else { return }
            isWorking = true
            errorMessage = nil
            completedURL = nil
            let selectedName = name
            let selectedFormat = format
            let selectedZip = zip
            operationTask = Task {
                do {
                    let plan = try await PortablePackagePlanner.planAsync(source: source,
                        documentURL: documentURL, dialect: dialect)
                    let result = try await DocumentWork.commit {
                        try PortablePackageExporter.export(plan, to: parent, name: selectedName,
                            format: selectedFormat, zip: selectedZip)
                    }
                    completedURL = result
                } catch is CancellationError {
                } catch PortablePackageError.cancelled {
                } catch { errorMessage = error.localizedDescription }
                isWorking = false
                operationTask = nil
            }
        }
    }
}
