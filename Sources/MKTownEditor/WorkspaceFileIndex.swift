import AppKit
import Foundation
import CoreServices

struct WorkspaceNode: Identifiable, Sendable, Equatable {
    /// The node for `url` anywhere under `nodes`, matched by standardized file path.
    static func first(at url: URL, in nodes: [WorkspaceNode]) -> WorkspaceNode? {
        let path = url.standardizedFileURL.path
        var pending = nodes[...]
        var stack: [WorkspaceNode] = []
        while let node = pending.popFirst() ?? stack.popLast() {
            if node.url.standardizedFileURL.path == path { return node }
            stack.append(contentsOf: node.children ?? [])
        }
        return nil
    }

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
    /// 列挙できなかったサブフォルダの数。これらは空のフォルダとして一覧に残る。
    let skippedDirectories: Int
}

/// ワークスペースのルート自体を列挙できなかったときのエラー。
/// 空の一覧と区別するため、サブフォルダの失敗とは分けて `scan` から投げる。
struct WorkspaceRootUnavailableError: LocalizedError, Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case missing
        case permissionDenied
        case notDirectory
        case other(String)
    }

    let rootURL: URL
    let reason: Reason

    init(rootURL: URL, reason: Reason) {
        self.rootURL = rootURL
        self.reason = reason
    }

    init(rootURL: URL, underlying error: Error) {
        let error = error as NSError
        let posix = (error.userInfo[NSUnderlyingErrorKey] as? NSError)
            .flatMap { $0.domain == NSPOSIXErrorDomain ? $0.code : nil }
        let reason: Reason
        if error.domain == NSCocoaErrorDomain, error.code == CocoaError.fileReadNoSuchFile.rawValue
            || error.code == CocoaError.fileNoSuchFile.rawValue {
            reason = .missing
        } else if error.domain == NSCocoaErrorDomain, error.code == CocoaError.fileReadNoPermission.rawValue {
            reason = .permissionDenied
        } else if posix == Int(ENOTDIR) {
            reason = .notDirectory
        } else {
            reason = .other(error.localizedDescription)
        }
        self.init(rootURL: rootURL, reason: reason)
    }

    var errorDescription: String? {
        switch reason {
        case .missing:
            String(localized: "フォルダが見つかりません。削除または移動されたか、フォルダのあるディスクが取り外された可能性があります。")
        case .permissionDenied:
            String(localized: "このフォルダを読み込む権限がありません。フォルダを選び直してアクセスを許可してください。")
        case .notDirectory:
            String(localized: "この場所はフォルダではありません。")
        case let .other(message):
            message
        }
    }
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
    static let maximumEntries = 50_000
    private static let maximumDepth = 16

    /// ルートを列挙できないときは `WorkspaceRootUnavailableError` を投げる。
    /// 読めないサブフォルダは空として扱い、`skippedDirectories` に数える。
    static func scan(root: URL, maximumEntries: Int = maximumEntries)
        throws(WorkspaceRootUnavailableError) -> WorkspaceScanResult {
        var visited = 0
        var truncated = false
        var skipped = 0
        let manager = FileManager.default

        func contents(of directory: URL) throws -> [URL] {
            try manager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey,
                                                             .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        }

        func descend(_ directory: URL, depth: Int) -> [WorkspaceNode] {
            guard depth < maximumDepth else { truncated = true; return [] }
            guard let urls = try? contents(of: directory) else { skipped += 1; return [] }
            return nodes(for: urls, depth: depth)
        }

        func nodes(for urls: [URL], depth: Int) -> [WorkspaceNode] {
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

        let rootContents: [URL]
        do { rootContents = try contents(of: root) }
        catch { throw WorkspaceRootUnavailableError(rootURL: root, underlying: error) }
        return WorkspaceScanResult(nodes: nodes(for: rootContents, depth: 0), isTruncated: truncated,
                                   skippedDirectories: skipped)
    }
}

/// One recursive event stream per workspace. Poll only if event monitoring cannot start.
final class WorkspaceDirectoryMonitor: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private var fallbackTimer: DispatchSourceTimer?
    private let changed: @MainActor @Sendable () -> Void

    init(root: URL, fallbackInterval: TimeInterval = 3,
         createStream: (URL, inout FSEventStreamContext) -> FSEventStreamRef? = WorkspaceDirectoryMonitor.createStream,
         startStream: (FSEventStreamRef) -> Bool = FSEventStreamStart,
         changed: @escaping @MainActor @Sendable () -> Void) {
        self.changed = changed
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = createStream(root, &context)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            if startStream(stream) { return }
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = max(0.01, fallbackInterval)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { Task { @MainActor in changed() } }
        fallbackTimer = timer
        timer.resume()
    }

    static func createStream(_ root: URL, _ context: inout FSEventStreamContext) -> FSEventStreamRef? {
        FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<WorkspaceDirectoryMonitor>.fromOpaque(info).takeUnretainedValue()
            let changed = monitor.changed
            Task { @MainActor in changed() }
        }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
    }

    func stop() {
        fallbackTimer?.cancel()
        fallbackTimer = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}

/// Per-document revisions of open, possibly unsaved buffers. Kept out of `WorkspaceStore`'s
/// published state because it changes on every keystroke: only views that read open-buffer
/// contents (embedded documents) observe it, so typing does not re-evaluate every window that
/// observes the workspace.
@MainActor
final class WorkspaceContentRevisions: ObservableObject {
    @Published private(set) var values: [URL: Int] = [:]

    /// A fixed instance for previews without a workspace; it never changes.
    static let empty = WorkspaceContentRevisions()

    func bump(_ key: URL) { values[key, default: 0] &+= 1 }
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var rootURL: URL?
    @Published private(set) var nodes: [WorkspaceNode] = [] {
        didSet {
            nodesRevision &+= 1
            updateVisibleNodes()
        }
    }
    private var nodesRevision = 0
    private var quickOpenCache: (root: URL, revision: Int, index: WorkspaceQuickOpenIndex)?

    /// 書類一覧が変わるまで、クイックオープン・Wikiリンク・結合のシートで同じ索引を使う。
    var quickOpenIndex: WorkspaceQuickOpenIndex {
        guard let rootURL else { return .empty }
        if let cache = quickOpenCache, cache.root == rootURL, cache.revision == nodesRevision {
            return cache.index
        }
        let index = WorkspaceQuickOpenIndex(nodes: nodes, root: rootURL)
        quickOpenCache = (rootURL, nodesRevision, index)
        return index
    }
    @Published private(set) var visibleNodes: [WorkspaceNode] = []
    @Published private(set) var documentURLs: [URL] = []
    @Published private(set) var documentIndex = WorkspaceDocumentIndex(documents: [])
    @Published private(set) var fileSystemRevision = 0
    /// Observed only by embedded document views; see `WorkspaceContentRevisions`.
    let contentRevisions = WorkspaceContentRevisions()
    var openBufferRevisions: [URL: Int] { contentRevisions.values }

    func openBufferDidChange(for url: URL) {
        // Registration resolves aliases once; typing must not perform filesystem I/O.
        guard let key = openBufferKeys[url.standardizedFileURL] else { return }
        contentRevisions.bump(key)
    }
    @Published private(set) var isTruncated = false
    /// 列挙できなかったサブフォルダの数。
    @Published private(set) var skippedDirectoryCount = 0
    /// ルートを読めないときの理由。読めるようになると次の更新で nil に戻る。
    /// ルートの URL は保持したままにして、どのフォルダが読めないのかを表示できるようにする。
    @Published private(set) var rootUnavailableError: WorkspaceRootUnavailableError?
    var isRootUnavailable: Bool { rootUnavailableError != nil }
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
        guard let data = defaults.data(forKey: bookmarkKey),
              let restored = Self.restoreBookmark(data) else { return }
        // 読めないフォルダも黙って捨てず、ルートとして開いて利用不可の状態を表示する。
        setRoot(restored.url)
        // 移動や名前変更で古くなったブックマークは、フォルダがあれば作り直す。
        // 無い場合は元のブックマークを残し、ボリュームが戻った次回の起動で解決できるようにする。
        if restored.isStale, FileManager.default.fileExists(atPath: restored.url.path) {
            do { try saveBookmark(for: restored.url) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    /// 保存済みブックマークから開くフォルダを求める。解決できない（削除・取り外し）ときは
    /// ブックマークに記録されたパスを返し、どのフォルダが読めないのかを示せるようにする。
    static func restoreBookmark(_ data: Data) -> (url: URL, isStale: Bool)? {
        var stale = false
        if let url = (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                               relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: data, options: [],
                         relativeTo: nil, bookmarkDataIsStale: &stale)) {
            return (url, stale)
        }
        guard let path = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data)?.path else {
            return nil
        }
        // 作り直すとセキュリティスコープ付きの元のブックマークを失うため、古い扱いにしない。
        return (URL(fileURLWithPath: path, isDirectory: true), false)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "開く")
        if let rootURL { panel.directoryURL = rootURL.deletingLastPathComponent() }
        panel.beginAttached { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.setRoot(url)
            do { try self.saveBookmark(for: url) }
            catch { self.errorMessage = error.localizedDescription }
        }
    }

    private func saveBookmark(for url: URL) throws {
        let data = try? url.bookmarkData(options: [.withSecurityScope],
                                         includingResourceValuesForKeys: nil,
                                         relativeTo: nil)
        let bookmark = try data ?? url.bookmarkData(options: [],
                                                    includingResourceValuesForKeys: nil,
                                                    relativeTo: nil)
        defaults.set(bookmark, forKey: bookmarkKey)
    }

    /// ルートが読めない間だけ読み直す。アプリが前面に戻ったときやボリュームのマウント時に呼ぶ。
    func refreshIfRootUnavailable() {
        if isRootUnavailable { refresh(force: true) }
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
        rootUnavailableError = nil
        skippedDirectoryCount = 0
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
                Result { () throws(WorkspaceRootUnavailableError) -> WorkspaceScanResult in
                    try WorkspaceFileIndex.scan(root: rootURL)
                }
            }.value
            guard currentGeneration == generation else { return }
            switch result {
            case let .success(result):
                if rootUnavailableError != nil { rootUnavailableError = nil }
                if nodes != result.nodes { nodes = result.nodes }
                if isTruncated != result.isTruncated { isTruncated = result.isTruncated }
                if skippedDirectoryCount != result.skippedDirectories {
                    skippedDirectoryCount = result.skippedDirectories
                }
            case let .failure(error):
                // 以前の一覧は存在しないファイルを指しうるため残さない。
                if rootUnavailableError != error { rootUnavailableError = error }
                if !nodes.isEmpty { nodes = [] }
                if isTruncated { isTruncated = false }
                if skippedDirectoryCount != 0 { skippedDirectoryCount = 0 }
            }
            isRefreshing = false
            if refreshPending {
                refreshPending = false
                refresh(force: true)
            }
        }
    }
}
