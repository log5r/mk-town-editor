import AppKit
import Foundation

struct WorkspaceNode: Identifiable, Sendable {
    let url: URL
    let name: String
    let children: [WorkspaceNode]?

    var id: URL { url }
    var isDirectory: Bool { children != nil }
    var isEditableDocument: Bool { ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()) }
}

struct WorkspaceScanResult: Sendable {
    let nodes: [WorkspaceNode]
    let isTruncated: Bool
}

enum WorkspaceFileIndex {
    private static let supportedExtensions: Set<String> = [
        "md", "markdown", "txt", "png", "jpg", "jpeg", "gif", "webp", "pdf"
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
                at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            var nodes: [WorkspaceNode] = []
            for url in urls {
                guard visited < maximumEntries else { truncated = true; break }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { continue }
                if values?.isDirectory == true {
                    visited += 1
                    nodes.append(WorkspaceNode(url: url, name: url.lastPathComponent,
                                               children: descend(url, depth: depth + 1)))
                } else if supportedExtensions.contains(url.pathExtension.lowercased()) {
                    visited += 1
                    nodes.append(WorkspaceNode(url: url, name: url.lastPathComponent, children: nil))
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

    private let defaults: UserDefaults
    private let bookmarkKey = "workspaceFolderBookmark"
    private var hasSecurityScope = false
    private var generation = 0
    private var isRefreshing = false
    private var lastRefresh = Date.distantPast

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
        nodes = []
        generation += 1
        isRefreshing = false
        lastRefresh = .distantPast
        refresh()
    }

    func clearError() { errorMessage = nil }

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
