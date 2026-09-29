import Foundation

struct CloudFileStatus: Equatable, Sendable {
    let isUbiquitous: Bool
    let downloadStatus: URLUbiquitousItemDownloadingStatus?
    let isDownloading: Bool
    let hasUnresolvedConflicts: Bool
    let modificationDate: Date?

    var needsDownload: Bool { isUbiquitous && downloadStatus == .notDownloaded }

    static func read(at url: URL) throws -> Self {
        let values = try url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey, .ubiquitousItemHasUnresolvedConflictsKey,
            .contentModificationDateKey
        ])
        return Self(isUbiquitous: values.isUbiquitousItem ?? false,
                    downloadStatus: values.ubiquitousItemDownloadingStatus,
                    isDownloading: values.ubiquitousItemIsDownloading ?? false,
                    hasUnresolvedConflicts: values.ubiquitousItemHasUnresolvedConflicts ?? false,
                    modificationDate: values.contentModificationDate)
    }
}

enum CloudFileError: LocalizedError {
    case unsupportedDownload
    case contentsUnavailable
    case noConflicts
    case saveNotFinished
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .unsupportedDownload: String(localized: "このファイルはiCloudのダウンロード対象ではありません。")
        case .contentsUnavailable: String(localized: "ファイルの内容を読み取れません。")
        case .noConflicts: String(localized: "解消する競合版はありません。")
        case .saveNotFinished: String(localized: "選択版がディスクに保存されるまで待ってから確定してください。")
        case .tooLarge: String(localized: "比較できるファイルサイズは4MBまでです。")
        }
    }
}

enum CloudFileVersions {
    static func requestDownload(at url: URL) throws {
        guard try CloudFileStatus.read(at: url).isUbiquitous else {
            throw CloudFileError.unsupportedDownload
        }
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    static func unresolved(at url: URL) -> [NSFileVersion] {
        NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
    }

    static func readCurrent(at url: URL) throws -> String {
        try coordinatedText(at: url)
    }

    static func read(_ version: NSFileVersion) throws -> String {
        guard version.hasLocalContents else { throw CloudFileError.contentsUnavailable }
        return try coordinatedText(at: version.url)
    }

    static func resolve(at url: URL, selectedText: String) throws {
        let versions = unresolved(at: url)
        guard !versions.isEmpty else { throw CloudFileError.noConflicts }
        guard try readCurrent(at: url) == selectedText else { throw CloudFileError.saveNotFinished }
        for version in versions {
            version.isResolved = true
            try version.remove()
        }
    }

    private static func coordinatedText(at url: URL) throws -> String {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinateError: NSError?
        var result: Result<String, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinateError) { coordinatedURL in
            result = Result {
                let data = try Data(contentsOf: coordinatedURL)
                guard data.count <= 4_000_000 else { throw CloudFileError.tooLarge }
                guard let text = String(data: data, encoding: .utf8) else {
                    throw CloudFileError.contentsUnavailable
                }
                return text
            }
        }
        if let coordinateError { throw coordinateError }
        guard let result else { throw CloudFileError.contentsUnavailable }
        return try result.get()
    }
}
