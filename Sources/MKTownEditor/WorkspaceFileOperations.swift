import CryptoKit
import Foundation

enum WorkspaceFileOperationError: LocalizedError {
    case outsideWorkspace
    case destinationExists
    case sourceMissing
    case unreadableDocument(URL)
    case documentChanged(URL)
    case rollbackFailed
    case indexTruncated
    case invalidName
    case workspaceChanged

    var errorDescription: String? {
        switch self {
        case .outsideWorkspace: "ワークスペースの外には移動できません。"
        case .destinationExists: "同じ名前のファイルまたはフォルダが既にあります。"
        case .sourceMissing: "元のファイルまたはフォルダが見つかりません。"
        case let .unreadableDocument(url): "リンクを確認するための書類を読めません: \(url.lastPathComponent)"
        case let .documentChanged(url): "確認後に書類が変更されました: \(url.lastPathComponent)"
        case .rollbackFailed: "変更の復元に失敗しました。ファイルを確認してください。"
        case .indexTruncated: "ファイル一覧が上限を超えたため、リンク更新を安全に確認できません。"
        case .invalidName: "ファイル名またはフォルダ名を確認してください。"
        case .workspaceChanged: "確認後にワークスペース内の書類が増減しました。もう一度確認してください。"
        }
    }
}

struct WorkspaceDocumentChange: Sendable {
    let oldURL: URL
    let newURL: URL
    let originalData: Data
    let updatedData: Data
    let linkCount: Int
    let linkChanges: [WorkspaceLinkChange]
}

struct WorkspaceLinkChange: Sendable {
    let range: NSRange
    let before: String
    let after: String
}

struct WorkspaceDocumentSnapshot: Sendable {
    let url: URL
    let digest: Data
}

struct WorkspaceMovePlan: Sendable {
    let rootURL: URL
    let sourceURL: URL
    let destinationURL: URL
    let changes: [WorkspaceDocumentChange]
    let inspectedDocuments: [WorkspaceDocumentSnapshot]

    var changedLinks: Int { changes.reduce(0) { $0 + $1.linkCount } }

    func validateCurrentState() throws {
        let manager = FileManager.default
        let currentIndex = WorkspaceFileIndex.scan(root: rootURL)
        guard !currentIndex.isTruncated else { throw WorkspaceFileOperationError.indexTruncated }
        let currentDocuments = Set(WorkspaceFileOperations.markdownFiles(in: currentIndex.nodes)
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        let plannedDocuments = Set(inspectedDocuments.map {
            $0.url.resolvingSymlinksInPath().standardizedFileURL.path
        })
        guard currentDocuments == plannedDocuments else {
            throw WorkspaceFileOperationError.workspaceChanged
        }
        guard manager.fileExists(atPath: sourceURL.path) else {
            throw WorkspaceFileOperationError.sourceMissing
        }
        guard !manager.fileExists(atPath: destinationURL.path) else {
            throw WorkspaceFileOperationError.destinationExists
        }
        for snapshot in inspectedDocuments {
            guard let current = try? Data(contentsOf: snapshot.url),
                  Data(SHA256.hash(data: current)) == snapshot.digest else {
                throw WorkspaceFileOperationError.documentChanged(snapshot.url)
            }
        }
    }

    func apply() throws {
        let manager = FileManager.default
        try validateCurrentState()
        try manager.moveItem(at: sourceURL, to: destinationURL)
        do {
            for change in changes where change.linkCount > 0 {
                try change.updatedData.write(to: change.newURL, options: .atomic)
            }
        } catch {
            var restored = true
            for change in changes where change.linkCount > 0 {
                do { try change.originalData.write(to: change.newURL, options: .atomic) }
                catch { restored = false }
            }
            do { try manager.moveItem(at: destinationURL, to: sourceURL) }
            catch { restored = false }
            if !restored { throw WorkspaceFileOperationError.rollbackFailed }
            throw error
        }
    }
}

enum WorkspaceFileOperations {
    static func planMove(source: URL, destination: URL, root: URL) throws -> WorkspaceMovePlan {
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        let destination = destination.resolvingSymlinksInPath().standardizedFileURL
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        guard isInside(source, root: root), isInside(destination, root: root),
              !isInside(destination, root: source) else {
            throw WorkspaceFileOperationError.outsideWorkspace
        }
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw WorkspaceFileOperationError.sourceMissing
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw WorkspaceFileOperationError.destinationExists
        }
        let index = WorkspaceFileIndex.scan(root: root)
        guard !index.isTruncated else { throw WorkspaceFileOperationError.indexTruncated }
        let documents = markdownFiles(in: index.nodes)
        var changes: [WorkspaceDocumentChange] = []
        var inspectedDocuments: [WorkspaceDocumentSnapshot] = []
        for document in documents {
            guard let original = try? Data(contentsOf: document),
                  let text = String(data: original, encoding: .utf8) else {
                throw WorkspaceFileOperationError.unreadableDocument(document)
            }
            inspectedDocuments.append(WorkspaceDocumentSnapshot(
                url: document, digest: Data(SHA256.hash(data: original))
            ))
            let newURL = mapped(document, from: source, to: destination)
            let (updated, links) = rewriteLinks(text, documentURL: document,
                                                newDocumentURL: newURL,
                                                source: source, destination: destination)
            if !links.isEmpty || document != newURL {
                changes.append(WorkspaceDocumentChange(oldURL: document, newURL: newURL,
                                                       originalData: original,
                                                       updatedData: Data(updated.utf8),
                                                       linkCount: links.count,
                                                       linkChanges: links))
            }
        }
        return WorkspaceMovePlan(rootURL: root, sourceURL: source,
                                 destinationURL: destination, changes: changes,
                                 inspectedDocuments: inspectedDocuments)
    }

    static func create(name: String, in directory: URL, root: URL, folder: Bool) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..",
              !trimmed.contains("/"), !trimmed.contains(":"), !trimmed.hasPrefix(".") else {
            throw WorkspaceFileOperationError.invalidName
        }
        let filename = !folder && URL(fileURLWithPath: trimmed).pathExtension.isEmpty
            ? trimmed + ".md" : trimmed
        let destination = directory.appendingPathComponent(filename).resolvingSymlinksInPath()
        guard isInside(destination, root: root) else {
            throw WorkspaceFileOperationError.outsideWorkspace
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw WorkspaceFileOperationError.destinationExists
        }
        if folder {
            try FileManager.default.createDirectory(at: destination,
                                                     withIntermediateDirectories: false)
        } else {
            guard ["md", "markdown"].contains(destination.pathExtension.lowercased()) else {
                throw WorkspaceFileOperationError.invalidName
            }
            let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            close(descriptor)
        }
        return destination
    }

    @discardableResult
    static func moveToTrash(_ url: URL, root: URL) throws -> URL? {
        guard isInside(url, root: root), url.resolvingSymlinksInPath() != root.resolvingSymlinksInPath() else {
            throw WorkspaceFileOperationError.outsideWorkspace
        }
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    }

    fileprivate static func markdownFiles(in nodes: [WorkspaceNode]) -> [URL] {
        nodes.flatMap { node -> [URL] in
            if let children = node.children { return markdownFiles(in: children) }
            return node.isEditableDocument ? [node.url] : []
        }
    }

    private static func rewriteLinks(_ text: String, documentURL: URL, newDocumentURL: URL,
                                     source: URL, destination: URL) -> (String, [WorkspaceLinkChange]) {
        let analysis = MarkdownAnalysis(text)
        let excluded = analysis.blocks.filter { $0.kind == .codeBlock }.map(\.sourceRange) +
            MarkdownInlineSyntax.codeSpanRanges(in: text)
        let context = DocumentContext(fileURL: documentURL)
        var edits: [WorkspaceLinkChange] = []
        let original = text as NSString
        for link in MarkdownLinkSyntax.inlineLinks(in: text) {
            if excluded.contains(where: { NSLocationInRange(link.range.location, $0) }) { continue }
            guard let newDestination = rebased(link.destination, context: context,
                                               newDocumentURL: newDocumentURL,
                                               source: source, destination: destination),
                  newDestination != link.destination else { continue }
            edits.append(WorkspaceLinkChange(
                range: link.destinationRange,
                before: original.substring(with: link.destinationRange),
                after: MarkdownLinkSyntax.escapeDestination(newDestination)
            ))
        }
        for reference in analysis.references.values {
            let range = reference.sourceRange
            if excluded.contains(where: { NSLocationInRange(range.location, $0) }) { continue }
            guard let newDestination = rebased(reference.destination, context: context,
                                               newDocumentURL: newDocumentURL,
                                               source: source, destination: destination),
                  newDestination != reference.destination else { continue }
            let line = original.substring(with: range)
            guard let separator = line.range(of: "]:"),
                  let target = line[separator.upperBound...].range(of: reference.destination) else { continue }
            let localRange = NSRange(target, in: line)
            edits.append(WorkspaceLinkChange(
                range: NSRange(location: range.location + localRange.location,
                               length: localRange.length),
                before: original.substring(with: NSRange(location: range.location + localRange.location,
                                                         length: localRange.length)),
                after: MarkdownLinkSyntax.escapeDestination(newDestination)
            ))
        }
        let result = NSMutableString(string: text)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: edit.range, with: edit.after)
        }
        return (result as String, edits.sorted { $0.range.location < $1.range.location })
    }

    private static func rebased(_ value: String, context: DocumentContext, newDocumentURL: URL,
                                source: URL, destination: URL) -> String? {
        let pieces = value.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(pieces[0])
        guard let target = context.resolveLocalResource(path) else { return nil }
        let newTarget = mapped(target, from: source, to: destination)
        guard newTarget != target || newDocumentURL != context.fileURL else { return nil }
        let relative = relativePath(from: newDocumentURL.deletingLastPathComponent(), to: newTarget)
        let fragment = pieces.count > 1 ? "#" + pieces[1] : ""
        let escapedPath = relative.replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "#", with: "%23")
            .replacingOccurrences(of: "?", with: "%3F")
        return escapedPath + fragment
    }

    private static func mapped(_ url: URL, from source: URL, to destination: URL) -> URL {
        let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
        let canonicalSource = source.resolvingSymlinksInPath().standardizedFileURL
        guard isInside(canonicalURL, root: canonicalSource) else { return canonicalURL }
        let remaining = canonicalURL.pathComponents.dropFirst(canonicalSource.pathComponents.count)
        return remaining.reduce(destination) { $0.appendingPathComponent($1) }
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        let components = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let rootComponents = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return components.starts(with: rootComponents)
    }

    private static func relativePath(from directory: URL, to target: URL) -> String {
        let base = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let dest = target.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let common = zip(base, dest).prefix(while: { $0.0 == $0.1 }).count
        return (Array(repeating: "..", count: base.count - common) + dest.dropFirst(common))
            .joined(separator: "/")
    }
}
