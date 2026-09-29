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
    case openDocumentChanged(URL)

    var errorDescription: String? {
        switch self {
        case .outsideWorkspace: String(localized: "ワークスペースの外には移動できません。")
        case .destinationExists: String(localized: "同じ名前のファイルまたはフォルダが既にあります。")
        case .sourceMissing: String(localized: "元のファイルまたはフォルダが見つかりません。")
        case let .unreadableDocument(url): String(localized: "リンクを確認するための書類を読めません: \(url.lastPathComponent)")
        case let .documentChanged(url): String(localized: "確認後に書類が変更されました: \(url.lastPathComponent)")
        case .rollbackFailed: String(localized: "変更の復元に失敗しました。ファイルを確認してください。")
        case .indexTruncated: String(localized: "ファイル一覧が上限を超えたため、リンク更新を安全に確認できません。")
        case .invalidName: String(localized: "ファイル名またはフォルダ名を確認してください。")
        case .workspaceChanged: String(localized: "確認後にワークスペース内の書類が増減しました。もう一度確認してください。")
        case let .openDocumentChanged(url): String(localized: "確認後に開いている書類が変更されました: \(url.lastPathComponent)")
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
    let openOriginalData: Data?
    let updatedOpenText: String?
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
    let inspectedOpenDocuments: [URL: Data]

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

    func validateAppliedData() throws {
        for change in changes where change.linkCount > 0 {
            guard let current = try? Data(contentsOf: change.newURL),
                  current == change.updatedData else {
                throw WorkspaceFileOperationError.documentChanged(change.newURL)
            }
        }
    }

    func rollback() throws {
        var restored = true
        for change in changes where change.linkCount > 0 {
            do { try change.originalData.write(to: change.newURL, options: .atomic) }
            catch { restored = false }
        }
        do { try FileManager.default.moveItem(at: destinationURL, to: sourceURL) }
        catch { restored = false }
        if !restored { throw WorkspaceFileOperationError.rollbackFailed }
    }
}

enum WorkspaceFileOperations {
    static func planMove(source: URL, destination: URL, root: URL,
                         openDocuments: [URL: Data] = [:]) throws -> WorkspaceMovePlan {
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
        let openData = openDocuments.reduce(into: [URL: Data]()) { result, item in
            result[item.key.resolvingSymlinksInPath().standardizedFileURL] = item.value
        }
        let workspaceDocumentPaths = Set(documents.map {
            $0.resolvingSymlinksInPath().standardizedFileURL.path
        })
        let inspectedOpenDocuments = openData.filter {
            workspaceDocumentPaths.contains($0.key.path)
        }
        var changes: [WorkspaceDocumentChange] = []
        var inspectedDocuments: [WorkspaceDocumentSnapshot] = []
        for scannedDocument in documents {
            let document = scannedDocument.resolvingSymlinksInPath().standardizedFileURL
            guard let original = try? Data(contentsOf: document),
                  let opened = try? MarkdownDocument(data: openData[document] ?? original) else {
                throw WorkspaceFileOperationError.unreadableDocument(document)
            }
            inspectedDocuments.append(WorkspaceDocumentSnapshot(
                url: document, digest: Data(SHA256.hash(data: original))
            ))
            let newURL = mapped(document, from: source, to: destination)
            let (updated, links) = rewriteLinks(opened.text, documentURL: document,
                                                newDocumentURL: newURL,
                                                source: source, destination: destination,
                                                documents: documents)
            if !links.isEmpty || document != newURL {
                var updatedDocument = opened
                updatedDocument.text = updated
                changes.append(WorkspaceDocumentChange(oldURL: document, newURL: newURL,
                                                       originalData: original,
                                                       updatedData: updatedDocument.encodedData(),
                                                       linkCount: links.count,
                                                       linkChanges: links,
                                                       openOriginalData: openData[document],
                                                       updatedOpenText: openData[document] == nil ? nil : updated))
            }
        }
        return WorkspaceMovePlan(rootURL: root, sourceURL: source,
                                 destinationURL: destination, changes: changes,
                                 inspectedDocuments: inspectedDocuments,
                                 inspectedOpenDocuments: inspectedOpenDocuments)
    }

    static func create(name: String, in directory: URL, root: URL, folder: Bool,
                       contents: String = "") throws -> URL {
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
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: Data(contents.utf8))
                try handle.close()
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
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
                                     source: URL, destination: URL,
                                     documents: [URL]) -> (String, [WorkspaceLinkChange]) {
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
        let movedDocuments = documents.map { mapped($0, from: source, to: destination) }
        for wiki in WorkspaceWikiLinks.links(in: text) {
            guard let target = WorkspaceWikiLinks.resolve(wiki.target, from: documentURL,
                documents: documents) else { continue }
            let movedTarget = mapped(target, from: source, to: destination)
            let rewritten = WorkspaceWikiLinks.target(for: movedTarget,
                from: newDocumentURL, documents: movedDocuments)
            guard rewritten != wiki.target else { continue }
            edits.append(WorkspaceLinkChange(range: wiki.targetRange,
                before: original.substring(with: wiki.targetRange), after: rewritten))
        }
        for embed in WorkspaceDocumentEmbed.links(in: text) {
            guard let target = WorkspaceWikiLinks.resolve(embed.target, from: documentURL,
                documents: documents) else { continue }
            let movedTarget = mapped(target, from: source, to: destination)
            let rewritten = WorkspaceWikiLinks.target(for: movedTarget,
                from: newDocumentURL, documents: movedDocuments)
            guard rewritten != embed.target else { continue }
            edits.append(WorkspaceLinkChange(range: embed.targetRange,
                before: original.substring(with: embed.targetRange), after: rewritten))
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
