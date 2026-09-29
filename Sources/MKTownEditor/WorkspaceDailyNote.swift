import Foundation

enum WorkspaceDailyNoteTemplate: String, CaseIterable, Identifiable {
    case blank
    case journal
    case meeting

    var id: Self { self }

    var title: String {
        switch self {
        case .blank: String(localized: "空白")
        case .journal: String(localized: "日記")
        case .meeting: String(localized: "会議メモ")
        }
    }

    func text(for date: String) -> String {
        switch self {
        case .blank: ""
        case .journal: String(localized: "# \(date)\n\n## 今日のメモ\n\n## 振り返り\n")
        case .meeting: String(localized: "# \(date) 会議メモ\n\n## 議題\n\n## 決定事項\n\n## 次のアクション\n")
        }
    }
}

enum WorkspaceDailyNote {
    static func dateName(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
            components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    static func destination(for date: Date, root: URL,
                            calendar: Calendar = .current) -> URL {
        root.appendingPathComponent("Daily", isDirectory: true)
            .appendingPathComponent(dateName(for: date, calendar: calendar) + ".md")
    }

    @discardableResult
    static func openOrCreate(for date: Date, root: URL,
                             template: WorkspaceDailyNoteTemplate,
                             calendar: Calendar = .current) throws -> URL {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let folder = root.appendingPathComponent("Daily", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            do {
                _ = try WorkspaceFileOperations.create(name: "Daily", in: root,
                    root: root, folder: true)
            } catch WorkspaceFileOperationError.destinationExists {
                // Another window may have created the folder meanwhile.
            }
        }
        let resolvedFolder = folder.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedFolder.pathComponents.starts(with: root.pathComponents),
              (try? resolvedFolder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw WorkspaceFileOperationError.outsideWorkspace
        }
        let name = dateName(for: date, calendar: calendar)
        let destination = resolvedFolder.appendingPathComponent(name + ".md")
        if FileManager.default.fileExists(atPath: destination.path) {
            return try validatedExisting(destination, root: root)
        }
        do {
            return try WorkspaceFileOperations.create(name: name + ".md", in: resolvedFolder,
                root: root, folder: false, contents: template.text(for: name))
        } catch WorkspaceFileOperationError.destinationExists {
            return try validatedExisting(destination, root: root)
        }
    }

    private static func validatedExisting(_ url: URL, root: URL) throws -> URL {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.pathComponents.starts(with: root.pathComponents),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw WorkspaceFileOperationError.outsideWorkspace
        }
        return url
    }
}
