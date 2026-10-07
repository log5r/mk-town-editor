import AppKit
import Foundation
import CoreServices

struct WorkspaceNode: Identifiable, Sendable, Equatable {
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
            String(localized: "複数ウインドウの書類内容が一致しません: \(url.lastPathComponent)")
        }
    }
}

enum WorkspaceFileIndex {
    private static let supportedExtensions: Set<String> = [
        "md", "markdown", "txt", "png", "jpg", "jpeg", "gif", "webp",
        "heic", "tif", "tiff", "bmp", "pdf"
    ]
    private static let maximumEntries = 50_000
    private static let maximumDepth = 16

    static func scan(root: URL, maximumEntries: Int = maximumEntries) -> WorkspaceScanResult {
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

/// One recursive event stream per workspace; no periodic tree scans.
final class WorkspaceDirectoryMonitor: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let changed: @MainActor @Sendable () -> Void

    init(root: URL, changed: @escaping @MainActor @Sendable () -> Void) {
        self.changed = changed
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<WorkspaceDirectoryMonitor>.fromOpaque(info).takeUnretainedValue()
            let changed = monitor.changed
            Task { @MainActor in changed() }
        }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var rootURL: URL?
    @Published private(set) var nodes: [WorkspaceNode] = [] {
        didSet { updateVisibleNodes() }
    }
    @Published private(set) var visibleNodes: [WorkspaceNode] = []
    @Published private(set) var documentURLs: [URL] = []
    @Published private(set) var documentIndex = WorkspaceDocumentIndex(documents: [])
    @Published private(set) var fileSystemRevision = 0
    @Published private(set) var openBufferRevisions: [URL: Int] = [:]

    func openBufferDidChange(for url: URL) {
        // Registration resolves aliases once; typing must not perform filesystem I/O.
        guard let key = openBufferKeys[url.standardizedFileURL] else { return }
        openBufferRevisions[key, default: 0] &+= 1
    }
    @Published private(set) var isTruncated = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var viewSettings = WorkspaceViewSettings() {
        didSet { if viewSettings != oldValue { updateVisibleNodes() } }
    }
    private var displayGeneration = 0
    private var displayTask: Task<Void, Never>?
    @Published private(set) var lockedDocumentPaths: Set<String> = []

    private let defaults: UserDefaults
    private let bookmarkKey = "workspaceFolderBookmark"
    private var hasSecurityScope = false
    private var generation = 0
    private var isRefreshing = false
    private var refreshPending = false
    private var directoryMonitor: WorkspaceDirectoryMonitor?
    private var lastRefresh = Date.distantPast
    private var openDocuments: [URL: Int] = [:]
    private var openBuffers: [URL: [UUID: WorkspaceOpenBuffer]] = [:]
    private var openBufferKeys: [URL: URL] = [:]
    private var documentLocks: [UUID: Set<String>] = [:]

    var openDocumentURLs: [URL] { Array(openDocuments.keys) }

    func registerOpenBuffer(id: UUID, url: URL, encodedData: @escaping () -> Data,
                            updateText: @escaping (String) -> Void) {
        let key = url.resolvingSymlinksInPath().standardizedFileURL
        openBufferKeys[url.standardizedFileURL] = key
        openBuffers[key, default: [:]][id] = WorkspaceOpenBuffer(encodedData: encodedData,
                                                                  updateText: updateText)
        openBufferDidChange(for: url)
    }

    func unregisterOpenBuffer(id: UUID, url: URL) {
        let key = openBufferKeys[url.standardizedFileURL] ?? url.resolvingSymlinksInPath().standardizedFileURL
        guard openBuffers[key]?.removeValue(forKey: id) != nil else { return }
        openBufferDidChange(for: url)
        if openBuffers[key]?.isEmpty == true {
            openBuffers.removeValue(forKey: key)
            openBufferKeys = openBufferKeys.filter { $0.value != key }
        }
    }

    func openBufferSnapshots(under root: URL? = nil, including requested: Set<URL>? = nil) throws -> [URL: Data] {
        var result: [URL: Data] = [:]
        let rootPath = root?.resolvingSymlinksInPath().standardizedFileURL.path
        for (url, buffers) in openBuffers {
            guard requested?.contains(url) != false else { continue }
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
        panel.prompt = String(localized: "開く")
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
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        directoryMonitor?.stop()
        directoryMonitor = nil
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
        // Published caches belong to the previous root until their worker finishes.
        // Clear them synchronously so the new workspace cannot expose old files.
        visibleNodes = []
        documentIndex = WorkspaceDocumentIndex(documents: [])
        documentURLs = []
        generation += 1
        isRefreshing = false
        lastRefresh = .distantPast
        refreshPending = false
        fileSystemRevision &+= 1
        directoryMonitor = WorkspaceDirectoryMonitor(root: url) { [weak self] in
            self?.fileSystemRevision &+= 1
            self?.refresh(force: true)
        }
        refresh()
    }

    func clearError() { errorMessage = nil }

    private func updateVisibleNodes() {
        func documents(in nodes: [WorkspaceNode]) -> [URL] {
            nodes.flatMap { node in
                node.children.map { documents(in: $0) } ?? (node.isEditableDocument ? [node.url] : [])
            }
        }
        let urls = documents(in: nodes)
        displayGeneration += 1
        let requested = displayGeneration
        displayTask?.cancel()
        guard let rootURL else { return }
        let nodes = nodes
        let settings = viewSettings
        let existingIndex = documentURLs == urls ? documentIndex : nil
        displayTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                (settings.display(nodes, root: rootURL), existingIndex ?? WorkspaceDocumentIndex(documents: urls))
            }.value
            guard let self, !Task.isCancelled, self.displayGeneration == requested else { return }
            if self.documentURLs != urls {
                self.documentIndex = result.1
                self.documentURLs = urls
            }
            if self.visibleNodes != result.0 { self.visibleNodes = result.0 }
        }
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
        guard let rootURL else { return }
        if isRefreshing {
            if force { refreshPending = true }
            return
        }
        guard force || Date().timeIntervalSince(lastRefresh) >= 2 else { return }
        isRefreshing = true
        lastRefresh = Date()
        let currentGeneration = generation
        Task {
            let result = await Task.detached(priority: .utility) {
                WorkspaceFileIndex.scan(root: rootURL)
            }.value
            guard currentGeneration == generation else { return }
            if nodes != result.nodes { nodes = result.nodes }
            if isTruncated != result.isTruncated { isTruncated = result.isTruncated }
            isRefreshing = false
            if refreshPending {
                refreshPending = false
                refresh(force: true)
            }
        }
    }
}
