import Foundation

struct WorkspaceViewSettings: Codable, Equatable {
    enum SortOrder: String, Codable, CaseIterable {
        case name
        case modified

        var title: String { self == .name ? "名前順" : "更新日時順" }
    }

    enum FileFilter: String, Codable, CaseIterable {
        case all
        case documents
        case attachments

        var title: String {
            switch self {
            case .all: "すべて"
            case .documents: "書類"
            case .attachments: "添付"
            }
        }
    }

    var sortOrder: SortOrder = .name
    var filter: FileFilter = .all
    var fileExtension: String?
    var pinnedPaths: Set<String> = []

    static func availableExtensions(in nodes: [WorkspaceNode]) -> [String] {
        let values = nodes.flatMap { node -> [String] in
            if let children = node.children { return availableExtensions(in: children) }
            return [node.url.pathExtension.lowercased()]
        }
        return Array(Set(values)).sorted()
    }

    func isPinned(_ url: URL, root: URL) -> Bool {
        pinnedPaths.contains(relativePath(url, root: root))
    }

    mutating func togglePin(_ url: URL, root: URL) {
        let path = relativePath(url, root: root)
        if pinnedPaths.contains(path) { pinnedPaths.remove(path) }
        else { pinnedPaths.insert(path) }
    }

    mutating func remapPins(from source: URL, to destination: URL, root: URL) {
        let oldPath = relativePath(source, root: root)
        let newPath = relativePath(destination, root: root)
        pinnedPaths = Set(pinnedPaths.map { path in
            if path == oldPath { return newPath }
            if path.hasPrefix(oldPath + "/") { return newPath + String(path.dropFirst(oldPath.count)) }
            return path
        })
    }

    mutating func removePins(under source: URL, root: URL) {
        let path = relativePath(source, root: root)
        pinnedPaths = pinnedPaths.filter { $0 != path && !$0.hasPrefix(path + "/") }
    }

    func display(_ nodes: [WorkspaceNode], root: URL) -> [WorkspaceNode] {
        let filtered = nodes.compactMap { node -> WorkspaceNode? in
            if let children = node.children {
                let visible = display(children, root: root)
                if filter != .all && visible.isEmpty { return nil }
                return WorkspaceNode(url: node.url, name: node.name, children: visible,
                                     modifiedAt: node.modifiedAt)
            }
            if let fileExtension, node.url.pathExtension.lowercased() != fileExtension {
                return nil
            }
            switch filter {
            case .all: return node
            case .documents: return node.isEditableDocument ? node : nil
            case .attachments: return node.isEditableDocument ? nil : node
            }
        }
        return filtered.sorted { left, right in
            let leftPinned = isPinned(left.url, root: root)
            let rightPinned = isPinned(right.url, root: root)
            if leftPinned != rightPinned { return leftPinned }
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            if sortOrder == .modified, left.modifiedAt != right.modifiedAt {
                return (left.modifiedAt ?? .distantPast) > (right.modifiedAt ?? .distantPast)
            }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    private func relativePath(_ url: URL, root: URL) -> String {
        let source = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let base = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard source.starts(with: base) else { return url.lastPathComponent }
        return source.dropFirst(base.count).joined(separator: "/")
    }
}
