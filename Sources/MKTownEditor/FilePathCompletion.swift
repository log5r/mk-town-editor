import Foundation

struct FilePathSuggestion: Equatable, Identifiable, Sendable {
    let path: String
    let isDirectory: Bool

    var id: String { path }
}

enum FilePathCompletion {
    /// Scan only the current document folder. Never traverse hidden folders or packages.
    static func scan(in directory: URL, limit: Int = 500) -> [FilePathSuggestion] {
        guard directory.isFileURL, limit > 0,
              let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else { return [] }
        var result: [FilePathSuggestion] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            let isDirectory = values?.isDirectory == true
            guard isDirectory || values?.isRegularFile == true else { continue }
            let path = url.pathComponents.suffix(enumerator.level).joined(separator: "/") +
                (isDirectory ? "/" : "")
            result.append(FilePathSuggestion(path: path, isDirectory: isDirectory))
            if result.count >= limit { break }
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func matches(_ query: String, in candidates: [FilePathSuggestion], limit: Int = 8) -> [FilePathSuggestion] {
        guard !query.isEmpty, !query.contains("://"), !query.hasPrefix("/"),
              !query.hasPrefix("#"), limit > 0 else { return [] }
        return Array(candidates.lazy.filter {
            $0.path.localizedStandardContains(query)
        }.prefix(limit))
    }
}
