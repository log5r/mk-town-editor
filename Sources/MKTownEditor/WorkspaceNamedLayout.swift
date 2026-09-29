import Foundation

struct WorkspaceNamedLayout: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var documentPaths: [String]
    var activePath: String?
    var mode: EditorMode
    var sidebarTab: String
    var sidebarVisible: Bool
    var splitRatio: Double
    var splitOrientation: EditorSplitOrientation
    var previewFirst: Bool

    static func capture(name: String, root: URL, openDocuments: [URL],
                        activeDocument: URL?, mode: EditorMode,
                        sidebarTab: String, sidebarVisible: Bool,
                        splitRatio: Double, splitOrientation: EditorSplitOrientation,
                        previewFirst: Bool) -> Self {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        func relative(_ url: URL) -> String? {
            let parts = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            let base = root.pathComponents
            guard parts.starts(with: base), parts.count > base.count else { return nil }
            return parts.dropFirst(base.count).joined(separator: "/")
        }
        let activePath = activeDocument.flatMap(relative)
        var paths = Array(Set(openDocuments.compactMap(relative))).sorted()
        if let activePath, !paths.contains(activePath) { paths.append(activePath) }
        return Self(id: UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            documentPaths: paths, activePath: activePath, mode: mode,
            sidebarTab: sidebarTab, sidebarVisible: sidebarVisible,
            splitRatio: min(0.8, max(0.2, splitRatio)),
            splitOrientation: splitOrientation, previewFirst: previewFirst)
    }

    func resolveDocuments(root: URL) -> (urls: [URL], missing: [String]) {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        var urls: [URL] = []
        var missing: [String] = []
        for path in documentPaths {
            let url = root.appendingPathComponent(path)
                .resolvingSymlinksInPath().standardizedFileURL
            guard url.pathComponents.starts(with: root.pathComponents),
                  ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                missing.append(path)
                continue
            }
            urls.append(url)
        }
        if let activePath,
           let index = urls.firstIndex(where: {
               $0 == root.appendingPathComponent(activePath)
                   .resolvingSymlinksInPath().standardizedFileURL
           }) {
            urls.append(urls.remove(at: index))
        }
        return (urls, missing)
    }
}

struct WorkspaceNamedLayoutStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func layouts(for root: URL) -> [WorkspaceNamedLayout] {
        guard let data = defaults.data(forKey: key(for: root)),
              let layouts = try? JSONDecoder().decode([WorkspaceNamedLayout].self,
                  from: data) else { return [] }
        return layouts
    }

    func save(_ layout: WorkspaceNamedLayout, for root: URL) {
        guard !layout.name.isEmpty else { return }
        var existing = layouts(for: root)
        if let index = existing.firstIndex(where: {
            $0.name.localizedCaseInsensitiveCompare(layout.name) == .orderedSame
        }) {
            let updated = WorkspaceNamedLayout(id: existing[index].id, name: layout.name,
                documentPaths: layout.documentPaths, activePath: layout.activePath,
                mode: layout.mode, sidebarTab: layout.sidebarTab,
                sidebarVisible: layout.sidebarVisible, splitRatio: layout.splitRatio,
                splitOrientation: layout.splitOrientation, previewFirst: layout.previewFirst)
            existing[index] = updated
        } else {
            existing.append(layout)
        }
        persist(existing, for: root)
    }

    func delete(_ id: UUID, for root: URL) {
        persist(layouts(for: root).filter { $0.id != id }, for: root)
    }

    func remapDocuments(from source: URL, to destination: URL, root: URL) {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        func relative(_ url: URL) -> String? {
            let parts = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard parts.starts(with: root.pathComponents), parts.count > root.pathComponents.count else {
                return nil
            }
            return parts.dropFirst(root.pathComponents.count).joined(separator: "/")
        }
        guard let old = relative(source), let new = relative(destination) else { return }
        func mapped(_ path: String) -> String {
            if path == old { return new }
            if path.hasPrefix(old + "/") { return new + String(path.dropFirst(old.count)) }
            return path
        }
        var saved = layouts(for: root)
        for index in saved.indices {
            saved[index].documentPaths = saved[index].documentPaths.map(mapped)
            saved[index].activePath = saved[index].activePath.map(mapped)
        }
        persist(saved, for: root)
    }

    private func persist(_ layouts: [WorkspaceNamedLayout], for root: URL) {
        guard let data = try? JSONEncoder().encode(layouts) else { return }
        defaults.set(data, forKey: key(for: root))
    }

    private func key(for root: URL) -> String {
        "workspaceNamedLayouts.\(root.resolvingSymlinksInPath().standardizedFileURL.path)"
    }
}
