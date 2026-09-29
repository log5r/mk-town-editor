import Foundation

struct WorkspaceTaskItem: Identifiable, Equatable, Sendable {
    let sourceURL: URL
    let relativePath: String
    let line: Int
    let sourceLocation: Int
    let expectedLine: String
    let title: String

    var id: String { "\(sourceURL.path):\(sourceLocation)" }
}

struct WorkspaceTaskIndex: Sendable {
    let tasks: [WorkspaceTaskItem]
    let skippedDocuments: Int
    let isTruncated: Bool

    static func scan(root: URL, nodes: [WorkspaceNode],
                     openBuffers: [URL: Data], isTruncated: Bool = false) throws -> Self {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var tasks: [WorkspaceTaskItem] = []
        var skipped = 0
        func visit(_ nodes: [WorkspaceNode]) throws {
            for node in nodes {
                try Task.checkCancellation()
                if let children = node.children {
                    try visit(children)
                    continue
                }
                guard node.isEditableDocument else { continue }
                let url = node.url.resolvingSymlinksInPath().standardizedFileURL
                guard url.path.hasPrefix(prefix) else { continue }
                let data: Data
                if let open = openBuffers[url] {
                    data = open
                } else {
                    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                          size <= 8_000_000,
                          let file = try? Data(contentsOf: url) else {
                        skipped += 1
                        continue
                    }
                    data = file
                }
                guard data.count <= 8_000_000,
                      let source = try? MarkdownDocument.decode(data) else {
                    skipped += 1
                    continue
                }
                let analysis = MarkdownAnalysis(source)
                let lines = MarkdownLineIndex(source)
                let text = source as NSString
                let relative = String(url.path.dropFirst(prefix.count))
                for block in analysis.blocks where block.task?.isChecked == false {
                    let line = lines.line(containingUTF16Offset: block.sourceRange.location)
                    let start = lines.starts[line - 1]
                    let end = line < lines.lineCount ? lines.starts[line] : text.length
                    let expected = text.substring(with: NSRange(location: start,
                        length: end - start))
                    tasks.append(WorkspaceTaskItem(sourceURL: url,
                        relativePath: relative, line: line, sourceLocation: start,
                        expectedLine: expected,
                        title: String((block.task?.content ?? "").prefix(240))))
                }
            }
        }
        try visit(nodes)
        tasks.sort {
            if $0.relativePath != $1.relativePath {
                return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
            return $0.sourceLocation < $1.sourceLocation
        }
        return Self(tasks: tasks, skippedDocuments: skipped, isTruncated: isTruncated)
    }

    static func toggleEdit(for task: WorkspaceTaskItem, in source: String) -> MarkdownEdit? {
        let text = source as NSString
        guard task.sourceLocation >= 0, task.sourceLocation < text.length else { return nil }
        let range = text.lineRange(for: NSRange(location: task.sourceLocation, length: 0))
        guard range.location == task.sourceLocation,
              text.substring(with: range) == task.expectedLine else { return nil }
        return MarkdownFormatter.toggleTasks(in: source,
            selection: NSRange(location: task.sourceLocation, length: 0))
    }
}
