import AppKit
import Foundation

struct WorkspaceNode: Identifiable, Sendable {
    let url: URL
    let name: String
    let children: [WorkspaceNode]?
    let modifiedAt: Date?

    init(url: URL, name: String, children: [WorkspaceNode]?, modifiedAt: Date? = nil) {
        self.url = url
        self.name = name
        self.children = children
        self.modifiedAt = modifiedAt
    }

    var id: URL { url }
    var isDirectory: Bool { children != nil }
    var isEditableDocument: Bool { ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()) }
}

struct WorkspaceScanResult: Sendable {
    let nodes: [WorkspaceNode]
    let isTruncated: Bool
}

private struct WorkspaceOpenBuffer {
    let encodedData: () -> Data
    let updateText: (String) -> Void
}

enum WorkspaceOpenBufferError: LocalizedError {
    case conflictingWindows(URL)

    var errorDescription: String? {
        switch self {
        case let .conflictingWindows(url):
            "複数ウインドウの書類内容が一致しません: \(url.lastPathComponent)"
        }
    }
}

enum WorkspaceFileIndex {
    private static let supportedExtensions: Set<String> = [
        "md", "markdown", "txt", "png", "jpg", "jpeg", "gif", "webp",
        "heic", "tif", "tiff", "bmp", "pdf"
    ]
    private static let maximumEntries = 10_000
    private static let maximumDepth = 16

    static func scan(root: URL) -> WorkspaceScanResult {
        var visited = 0
        var truncated = false
        let manager = FileManager.default

        func descend(_ directory: URL, depth: Int) -> [WorkspaceNode] {
            guard depth < maximumDepth else { truncated = true; return [] }
            guard let urls = try? manager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey,
                                                             .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            var nodes: [WorkspaceNode] = []
            for url in urls {
                guard visited < maximumEntries else { truncated = true; break }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey,
                                                               .contentModificationDateKey])
                if values?.isSymbolicLink == true { continue }
                if values?.isDirectory == true {
                    visited += 1
                    nodes.append(WorkspaceNode(url: url, name: url.lastPathComponent,
                                               children: descend(url, depth: depth + 1),
                                               modifiedAt: values?.contentModificationDate))
                } else if supportedExtensions.contains(url.pathExtension.lowercased()) {
                    visited += 1
                    nodes.append(WorkspaceNode(url: url, name: url.lastPathComponent, children: nil,
                                               modifiedAt: values?.contentModificationDate))
                }
            }
            nodes.sort {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return nodes
        }

        return WorkspaceScanResult(nodes: descend(root, depth: 0), isTruncated: truncated)
    }
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var rootURL: URL?
    @Published private(set) var nodes: [WorkspaceNode] = []
    @Published private(set) var isTruncated = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var viewSettings = WorkspaceViewSettings()
    @Published private(set) var lockedDocumentPaths: Set<String> = []

    private let defaults: UserDefaults
    private let bookmarkKey = "workspaceFolderBookmark"
    private var hasSecurityScope = false
    private var generation = 0
    private var isRefreshing = false
    private var lastRefresh = Date.distantPast
    private var openDocuments: [URL: Int] = [:]
    private var openBuffers: [URL: [UUID: WorkspaceOpenBuffer]] = [:]
    private var documentLocks: [UUID: Set<String>] = [:]

    var openDocumentURLs: [URL] { Array(openDocuments.keys) }

    func registerOpenBuffer(id: UUID, url: URL, encodedData: @escaping () -> Data,
                            updateText: @escaping (String) -> Void) {
        let key = url.resolvingSymlinksInPath().standardizedFileURL
        openBuffers[key, default: [:]][id] = WorkspaceOpenBuffer(encodedData: encodedData,
                                                                  updateText: updateText)
    }

    func unregisterOpenBuffer(id: UUID, url: URL) {
        let key = url.resolvingSymlinksInPath().standardizedFileURL
        openBuffers[key]?.removeValue(forKey: id)
        if openBuffers[key]?.isEmpty == true { openBuffers.removeValue(forKey: key) }
    }

    func openBufferSnapshots(under root: URL? = nil) throws -> [URL: Data] {
        var result: [URL: Data] = [:]
        let rootPath = root?.resolvingSymlinksInPath().standardizedFileURL.path
        for (url, buffers) in openBuffers {
            if let rootPath {
                let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
                guard url.path.hasPrefix(prefix) else { continue }
            }
            let values = buffers.values.map { $0.encodedData() }
            guard let first = values.first else { continue }
            guard values.allSatisfy({ $0 == first }) else {
                throw WorkspaceOpenBufferError.conflictingWindows(url)
            }
            result[url] = first
        }
        return result
    }

    func validateOpenBuffers(in plan: WorkspaceMovePlan, allowAppliedData: Bool = false) throws {
        let rootPath = plan.rootURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let currentKeys = Set(openBuffers.keys.filter {
            $0.path.hasPrefix(rootPrefix)
        })
        guard currentKeys == Set(plan.inspectedOpenDocuments.keys) else {
            throw WorkspaceFileOperationError.workspaceChanged
        }
        for (url, expected) in plan.inspectedOpenDocuments {
            let updated = plan.changes.first { $0.oldURL == url && $0.linkCount > 0 }?.updatedData
            guard let buffers = openBuffers[url], !buffers.isEmpty,
                  buffers.values.allSatisfy({ buffer in
                      let data = buffer.encodedData()
                      return data == expected || (allowAppliedData && data == updated)
                  }) else {
                throw WorkspaceFileOperationError.openDocumentChanged(url)
            }
        }
    }

    func applyOpenBufferChanges(in plan: WorkspaceMovePlan) throws {
        try validateOpenBuffers(in: plan, allowAppliedData: true)
        for change in plan.changes {
            guard let updated = change.updatedOpenText, change.linkCount > 0,
                  let buffers = openBuffers[change.oldURL] else { continue }
            for buffer in buffers.values {
                buffer.updateText(updated)
            }
        }
    }

    func lockOpenDocuments(in plan: WorkspaceMovePlan) -> UUID {
        let id = UUID()
        documentLocks[id] = Set(plan.inspectedOpenDocuments.keys.map(\.path))
        lockedDocumentPaths = documentLocks.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        return id
    }

    func unlockOpenDocuments(_ id: UUID) {
        documentLocks.removeValue(forKey: id)
        lockedDocumentPaths = documentLocks.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    }

    func isDocumentLocked(_ url: URL?) -> Bool {
        guard let url else { return false }
        return lockedDocumentPaths.contains(url.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    func registerOpenDocument(_ url: URL) {
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        openDocuments[url, default: 0] += 1
    }

    func unregisterOpenDocument(_ url: URL) {
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        guard let count = openDocuments[url] else { return }
        if count <= 1 { openDocuments.removeValue(forKey: url) }
        else { openDocuments[url] = count - 1 }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: bookmarkKey) else { return }
        var stale = false
        let url = (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                            relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: data, options: [],
                         relativeTo: nil, bookmarkDataIsStale: &stale))
        if let url, !stale {
            setRoot(url)
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "開く"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.setRoot(url)
            do {
                let data = try? url.bookmarkData(options: [.withSecurityScope],
                                                 includingResourceValuesForKeys: nil,
                                                 relativeTo: nil)
                let bookmark = try data ?? url.bookmarkData(options: [],
                                                            includingResourceValuesForKeys: nil,
                                                            relativeTo: nil)
                self?.defaults.set(bookmark, forKey: self?.bookmarkKey ?? "workspaceFolderBookmark")
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func setRoot(_ url: URL) {
        if hasSecurityScope { rootURL?.stopAccessingSecurityScopedResource() }
        hasSecurityScope = url.startAccessingSecurityScopedResource()
        rootURL = url
        if let data = defaults.data(forKey: settingsKey(for: url)),
           let saved = try? JSONDecoder().decode(WorkspaceViewSettings.self, from: data) {
            viewSettings = saved
        } else {
            viewSettings = WorkspaceViewSettings()
        }
        nodes = []
        generation += 1
        isRefreshing = false
        lastRefresh = .distantPast
        refresh()
    }

    func clearError() { errorMessage = nil }

    var visibleNodes: [WorkspaceNode] {
        guard let rootURL else { return [] }
        return viewSettings.display(nodes, root: rootURL)
    }

    var availableExtensions: [String] {
        WorkspaceViewSettings.availableExtensions(in: nodes)
    }

    func togglePin(_ url: URL) {
        guard let rootURL else { return }
        viewSettings.togglePin(url, root: rootURL)
        saveViewSettings()
    }

    func remapPins(from source: URL, to destination: URL) {
        guard let rootURL else { return }
        viewSettings.remapPins(from: source, to: destination, root: rootURL)
        saveViewSettings()
    }

    func removePins(under source: URL) {
        guard let rootURL else { return }
        viewSettings.removePins(under: source, root: rootURL)
        saveViewSettings()
    }

    func setSortOrder(_ value: WorkspaceViewSettings.SortOrder) {
        viewSettings.sortOrder = value
        saveViewSettings()
    }

    func setFileFilter(_ value: WorkspaceViewSettings.FileFilter) {
        viewSettings.filter = value
        saveViewSettings()
    }

    func setExtensionFilter(_ value: String?) {
        viewSettings.fileExtension = value
        saveViewSettings()
    }

    private func saveViewSettings() {
        guard let rootURL, let data = try? JSONEncoder().encode(viewSettings) else { return }
        defaults.set(data, forKey: settingsKey(for: rootURL))
    }

    private func settingsKey(for root: URL) -> String {
        "workspaceViewSettings.\(root.resolvingSymlinksInPath().standardizedFileURL.path)"
    }

    func refresh(force: Bool = false) {
        guard let rootURL, !isRefreshing,
              force || Date().timeIntervalSince(lastRefresh) >= 2 else { return }
        isRefreshing = true
        lastRefresh = Date()
        let currentGeneration = generation
        Task {
            let result = await Task.detached(priority: .utility) {
                WorkspaceFileIndex.scan(root: rootURL)
            }.value
            guard currentGeneration == generation else { return }
            nodes = result.nodes
            isTruncated = result.isTruncated
            isRefreshing = false
        }
    }
}
