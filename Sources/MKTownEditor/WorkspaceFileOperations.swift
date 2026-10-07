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

/// File identity used to skip re-reading unchanged documents.
///
/// Size and modification date alone are not a content identity: timestamps are coarse on some
/// volumes, and tools can rewrite a file with same-length content while preserving its date. On
/// APFS and HFS+ the file system's generation identifier changes whenever the data is rewritten,
/// so equal metadata that includes it proves unchanged contents. Volumes without it (exFAT, some
/// network file systems) report nil, and callers must then compare contents instead.
struct WorkspaceFileMetadata: Sendable, Equatable {
    typealias Reader = @Sendable (URL) throws -> WorkspaceFileMetadata

    let modified: Date?
    let size: Int?
    let generation: Data?

    init(url: URL) throws {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let values = try fresh.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey,
                                                        .generationIdentifierKey])
        self.init(modified: values.contentModificationDate, size: values.fileSize,
                  generation: (values.generationIdentifier as? NSData).map { Data(referencing: $0) })
    }

    init(modified: Date?, size: Int?, generation: Data?) {
        self.modified = modified
        self.size = size
        self.generation = generation
    }

    /// Whether equal metadata implies equal contents.
    var identifiesContent: Bool { generation != nil }

    /// True when both describe the same contents without reading the file.
    func matchesContent(of other: WorkspaceFileMetadata) -> Bool {
        self == other && identifiesContent
    }

    static let read: Reader = { try WorkspaceFileMetadata(url: $0) }
}

final class WorkspaceLinkAnalysisCache: @unchecked Sendable {
    static let shared = WorkspaceLinkAnalysisCache()
    struct Entry {
        let metadata: WorkspaceFileMetadata
        let original: Data
        let digest: Data
        let openData: Data?
        let document: MarkdownDocument?
        let analysis: MarkdownAnalysis?
    }
    private let lock = NSLock()
    private final class CachedEntry: NSObject {
        let value: Entry
        init(_ value: Entry) { self.value = value }
    }
    private let entries = NSCache<NSURL, CachedEntry>()
    let readMetadata: WorkspaceFileMetadata.Reader

    init(readMetadata: @escaping WorkspaceFileMetadata.Reader = WorkspaceFileMetadata.read) {
        self.readMetadata = readMetadata
        entries.totalCostLimit = 64_000_000
        entries.countLimit = 50_000
    }
    private var builds = 0
    var analysisBuildCount: Int { lock.lock(); defer { lock.unlock() }; return builds }

    func load(_ url: URL, openData: Data?) throws -> Entry {
        try Task.checkCancellation()
        let metadata = try readMetadata(url)
        let previous = entries.object(forKey: url as NSURL)?.value
        if let previous, previous.metadata.matchesContent(of: metadata), previous.openData == openData {
            return previous
        }
        let data: Data
        let digest: Data
        if let previous, previous.metadata.matchesContent(of: metadata) {
            data = previous.original
            digest = previous.digest
        } else {
            // Without a generation identifier, equal size and date are confirmed by content.
            data = try Data(contentsOf: url)
            digest = Data(SHA256.hash(data: data))
        }
        try Task.checkCancellation()
        let entry: Entry
        if let previous, previous.digest == digest, previous.openData == openData {
            entry = Entry(metadata: metadata, original: data, digest: digest, openData: openData,
                          document: previous.document, analysis: previous.analysis)
        } else {
            let document = try? MarkdownDocument(data: openData ?? data)
            let analysis = document.map { MarkdownAnalysis($0.text) }
            try Task.checkCancellation()
            entry = Entry(metadata: metadata, original: data, digest: digest, openData: openData,
                          document: document, analysis: analysis)
            lock.lock()
            if analysis != nil { builds += 1 }
            lock.unlock()
        }
        entries.setObject(CachedEntry(entry), forKey: url as NSURL, cost: data.count * 4)
        return entry
    }
}

struct WorkspaceDocumentSnapshot: Sendable {
    let url: URL
    let digest: Data
    let metadata: WorkspaceFileMetadata
}

struct WorkspaceMovePlan: Sendable {
    let rootURL: URL
    let sourceURL: URL
    let destinationURL: URL
    let changes: [WorkspaceDocumentChange]
    let inspectedDocuments: [WorkspaceDocumentSnapshot]
    let inspectedOpenDocuments: [URL: Data]
    var skippedDocuments: [URL] = []
    var isTruncated = false
    var readMetadata: WorkspaceFileMetadata.Reader = WorkspaceFileMetadata.read

    var changedLinks: Int { changes.reduce(0) { $0 + $1.linkCount } }

    func validateCurrentState() throws {
        let manager = FileManager.default
        let currentIndex = WorkspaceFileIndex.scan(root: rootURL)
        let currentDocuments = Set(WorkspaceFileOperations.markdownFiles(in: currentIndex.nodes)
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        let plannedDocuments = Set((inspectedDocuments.map(\.url) + skippedDocuments).map {
            $0.resolvingSymlinksInPath().standardizedFileURL.path
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
        // A document that could not be read while planning (offline cloud file, permissions)
        // may now hold links to the moved item. Its links were never examined, so stop and
        // ask for a new plan once it becomes readable.
        let inspectedPaths = Set(inspectedDocuments.map(\.url.path))
        for skipped in skippedDocuments where !inspectedPaths.contains(skipped.path) {
            try Task.checkCancellation()
            if (try? Data(contentsOf: skipped)) != nil {
                throw WorkspaceFileOperationError.documentChanged(skipped)
            }
        }
        let affected = Set(changes.map(\.oldURL))
        for snapshot in inspectedDocuments {
            try Task.checkCancellation()
            guard let metadata = try? readMetadata(snapshot.url), metadata == snapshot.metadata else {
                throw WorkspaceFileOperationError.documentChanged(snapshot.url)
            }
            // Rewritten documents, documents under the moved folder, and documents on volumes
            // without a generation identifier are confirmed by content before committing.
            let confirmByContent = affected.contains(snapshot.url)
                || snapshot.url.path.hasPrefix(sourceURL.path + "/")
                || !metadata.identifiesContent
            guard confirmByContent else { continue }
            guard let current = try? Data(contentsOf: snapshot.url),
                  Data(SHA256.hash(data: current)) == snapshot.digest else {
                throw WorkspaceFileOperationError.documentChanged(snapshot.url)
            }
        }
    }

    func apply() throws {
        let manager = FileManager.default
        try validateCurrentState()
        try Task.checkCancellation()
        try manager.moveItem(at: sourceURL, to: destinationURL)
        var written: [WorkspaceDocumentChange] = []
        do {
            for change in changes where change.linkCount > 0 {
                try Task.checkCancellation()
                written.append(change)
                try change.updatedData.write(to: change.newURL, options: .atomic)
            }
        } catch {
            // Documents not yet written keep their bytes and metadata, so a later plan
            // can still trust them; only the ones already rewritten are restored.
            var restored = true
            for change in written.reversed() {
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
                         openDocuments: [URL: Data] = [:],
                         cache: WorkspaceLinkAnalysisCache = .shared) throws -> WorkspaceMovePlan {
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        let destination = destination.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(destination.lastPathComponent)
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
        let documents = markdownFiles(in: index.nodes)
        let documentIndex = WorkspaceDocumentIndex(documents: documents)
        let movedIndex = WorkspaceDocumentIndex(documents: documents.map { mapped($0, from: source, to: destination) })
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
        var skippedDocuments: [URL] = []
        for scannedDocument in documents {
            let document = scannedDocument.resolvingSymlinksInPath().standardizedFileURL
            try Task.checkCancellation()
            guard let entry = try? cache.load(document, openData: openData[document]) else {
                try Task.checkCancellation()
                skippedDocuments.append(document)
                continue
            }
            let original = entry.original
            inspectedDocuments.append(WorkspaceDocumentSnapshot(url: document, digest: entry.digest,
                metadata: entry.metadata))
            guard let opened = entry.document, let analysis = entry.analysis else {
                skippedDocuments.append(document)
                continue
            }
            let newURL = mapped(document, from: source, to: destination)
            let (updated, links) = rewriteLinks(opened.text, documentURL: document,
                                                newDocumentURL: newURL,
                                                source: source, destination: destination,
                                                documentIndex: documentIndex, movedIndex: movedIndex, analysis: analysis)
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
                                 inspectedOpenDocuments: inspectedOpenDocuments,
                                 skippedDocuments: skippedDocuments, isTruncated: index.isTruncated,
                                 readMetadata: cache.readMetadata)
    }

    static func create(name: String, in directory: URL, root: URL, folder: Bool,
                       contents: String = "") throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..",
              !trimmed.contains("/"), !trimmed.contains(":"), !trimmed.hasPrefix(".") else {
            throw WorkspaceFileOperationError.invalidName
        }
        let directory = directory.resolvingSymlinksInPath().standardizedFileURL
        guard isInside(directory, root: root),
              (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw WorkspaceFileOperationError.outsideWorkspace
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
                                     documentIndex: WorkspaceDocumentIndex, movedIndex: WorkspaceDocumentIndex, analysis: MarkdownAnalysis) -> (String, [WorkspaceLinkChange]) {
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
        for wiki in WorkspaceWikiLinks.links(in: text, analysis: analysis) {
            guard let target = WorkspaceWikiLinks.resolve(wiki.target, from: documentURL,
                index: documentIndex) else { continue }
            let movedTarget = mapped(target, from: source, to: destination)
            let rewritten = WorkspaceWikiLinks.target(for: movedTarget,
                from: newDocumentURL, index: movedIndex)
            guard rewritten != wiki.target else { continue }
            edits.append(WorkspaceLinkChange(range: wiki.targetRange,
                before: original.substring(with: wiki.targetRange), after: rewritten))
        }
        for embed in WorkspaceDocumentEmbed.links(in: text, analysis: analysis) {
            guard let target = WorkspaceWikiLinks.resolve(embed.target, from: documentURL,
                index: documentIndex) else { continue }
            let movedTarget = mapped(target, from: source, to: destination)
            let rewritten = WorkspaceWikiLinks.target(for: movedTarget,
                from: newDocumentURL, index: movedIndex)
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
