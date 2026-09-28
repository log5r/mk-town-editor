import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageInput: Sendable {
    case remote(String)
    case file(URL)
}

enum ImageImportMode: String, Codable, CaseIterable, Sendable {
    case managedCopy
    case relativeReference

    var title: String {
        switch self {
        case .managedCopy: "assets にコピー"
        case .relativeReference: "元ファイルを参照"
        }
    }
}

struct ImportedImage: Sendable {
    let relativePath: String
    let createdFileURL: URL?
}

enum ImageResourceError: LocalizedError, Equatable {
    case unsavedDocument
    case invalidImage
    case noAvailableName
    case unsafeAssetsDirectory

    var errorDescription: String? {
        switch self {
        case .unsavedDocument: "ファイル画像を挿入するには、先に文書を保存してください。"
        case .invalidImage: "選択したファイルは対応する画像ではありません。"
        case .noAvailableName: "画像の保存名を決められません。"
        case .unsafeAssetsDirectory: "画像保存先の assets フォルダを確認してください。"
        }
    }
}

enum ImageInsertionError: LocalizedError {
    case documentChanged

    var errorDescription: String? {
        "本文が変更されたため画像を挿入できません。もう一度挿入してください。"
    }
}

struct ImageResourceManager {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func previewImage(at fileURL: URL, alt: String) -> NSImage? {
        guard fileURL.isFileURL,
              let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              CGImageSourceGetType(source) != nil,
              CGImageSourceGetCount(source) > 0,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 960
              ] as CFDictionary) else { return nil }
        let scale = min(1, 480 / CGFloat(thumbnail.width), 320 / CGFloat(thumbnail.height))
        let image = NSImage(cgImage: thumbnail,
                            size: NSSize(width: CGFloat(thumbnail.width) * scale,
                                         height: CGFloat(thumbnail.height) * scale))
        image.accessibilityDescription = alt
        return image
    }

    func importImage(at fileURL: URL, for context: DocumentContext,
                     mode: ImageImportMode = .managedCopy) throws -> ImportedImage {
        guard let directoryURL = context.directoryURL else { throw ImageResourceError.unsavedDocument }
        let hasAccess = fileURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { fileURL.stopAccessingSecurityScopedResource() } }
        let source = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        guard source.isFileURL,
              UTType(filenameExtension: source.pathExtension)?.conforms(to: .image) == true,
              let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetType(imageSource) != nil,
              CGImageSourceGetCount(imageSource) > 0 else {
            throw ImageResourceError.invalidImage
        }
        let directory = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
        let directoryPath = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        if source.path.hasPrefix(directoryPath) {
            return ImportedImage(relativePath: String(source.path.dropFirst(directoryPath.count)),
                                 createdFileURL: nil)
        }

        if mode == .relativeReference {
            let base = directory.pathComponents
            let target = source.pathComponents
            let common = zip(base, target).prefix(while: { $0.0 == $0.1 }).count
            let relative = Array(repeating: "..", count: base.count - common) + Array(target.dropFirst(common))
            return ImportedImage(relativePath: relative.joined(separator: "/"), createdFileURL: nil)
        }

        let assets = try assetsDirectory(beside: directory)
        let staging = assets.appendingPathComponent(".import-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: source, to: staging)
        if let existing = try matchingImage(for: staging, in: assets) {
            return ImportedImage(relativePath: "assets/\(existing.lastPathComponent)",
                                 createdFileURL: nil)
        }
        let name = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        for suffix in 1...10_000 {
            let fileName = suffix == 1 ? source.lastPathComponent : "\(name)-\(suffix).\(ext)"
            let destination = assets.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: destination.path) { continue }
            do {
                try fileManager.moveItem(at: staging, to: destination)
                return ImportedImage(relativePath: "assets/\(fileName)", createdFileURL: destination)
            } catch {
                if (error as? CocoaError)?.code == .fileWriteFileExists {
                    if fileManager.contentsEqual(atPath: staging.path, andPath: destination.path) {
                        return ImportedImage(relativePath: "assets/\(fileName)", createdFileURL: nil)
                    }
                    continue
                }
                throw error
            }
        }
        throw ImageResourceError.noAvailableName
    }

    func savePastedImage(_ data: Data, for context: DocumentContext,
                         now: Date = Date()) throws -> ImportedImage {
        guard let directoryURL = context.directoryURL else { throw ImageResourceError.unsavedDocument }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageResourceError.invalidImage
        }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil) else {
            throw ImageResourceError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageResourceError.invalidImage }

        let assets = try assetsDirectory(beside: directoryURL.standardizedFileURL.resolvingSymlinksInPath())
        let staging = assets.appendingPathComponent(".paste-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staging) }
        try (encoded as Data).write(to: staging, options: .withoutOverwriting)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "screenshot-\(formatter.string(from: now))"
        for suffix in 1...10_000 {
            let name = suffix == 1 ? "\(base).png" : "\(base)-\(suffix).png"
            let url = assets.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) { continue }
            do {
                try fileManager.moveItem(at: staging, to: url)
                return ImportedImage(relativePath: "assets/\(name)", createdFileURL: url)
            } catch {
                if (error as? CocoaError)?.code == .fileWriteFileExists { continue }
                throw error
            }
        }
        throw ImageResourceError.noAvailableName
    }

    private func assetsDirectory(beside directory: URL) throws -> URL {
        let directoryPath = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        let assets = directory.appendingPathComponent("assets", isDirectory: true)
        try fileManager.createDirectory(at: assets, withIntermediateDirectories: true)
        guard assets.resolvingSymlinksInPath().path.hasPrefix(directoryPath) else {
            throw ImageResourceError.unsafeAssetsDirectory
        }
        return assets
    }

    private func matchingImage(for staging: URL, in assets: URL) throws -> URL? {
        let size = try staging.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let candidates = try fileManager.contentsOfDirectory(at: assets,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles])
        for candidate in candidates {
            guard let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey,
                                                                        .isSymbolicLinkKey,
                                                                        .fileSizeKey]) else { continue }
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  values.fileSize == size,
                  UTType(filenameExtension: candidate.pathExtension)?.conforms(to: .image) == true,
                  fileManager.contentsEqual(atPath: staging.path, andPath: candidate.path) else {
                continue
            }
            return candidate
        }
        return nil
    }

    func rollback(_ imported: ImportedImage) {
        guard let createdFileURL = imported.createdFileURL else { return }
        try? fileManager.removeItem(at: createdFileURL)
    }
}

enum ImageInsertionService {
    @MainActor
    static func insert(alt: String, input: ImageInput, title: String,
                       context: DocumentContext, model: MarkdownEditorModel,
                       currentContext: () -> DocumentContext) async throws {
        let imported: ImportedImage?
        let destination: String
        switch input {
        case let .remote(url):
            imported = nil
            destination = url
        case let .file(url):
            let result = try await Task.detached(priority: .userInitiated) {
                try ImageResourceManager().importImage(at: url, for: context)
            }.value
            imported = result
            destination = result.relativePath
        }
        guard !Task.isCancelled, currentContext() == context,
              model.commitImage(alt: alt, destination: destination, title: title) else {
            if let imported { ImageResourceManager().rollback(imported) }
            throw ImageInsertionError.documentChanged
        }
    }

    @MainActor
    static func insertDrop(fileURL: URL, draft: MarkdownImageDraft,
                           mode: ImageImportMode, context: DocumentContext,
                           model: MarkdownEditorModel,
                           currentContext: () -> DocumentContext) async throws {
        let imported = try await Task.detached(priority: .userInitiated) {
            try ImageResourceManager().importImage(at: fileURL, for: context, mode: mode)
        }.value
        let alt = fileURL.deletingPathExtension().lastPathComponent
        guard !Task.isCancelled, currentContext() == context,
              model.commitDroppedImage(draft, alt: alt.isEmpty ? "画像" : alt,
                                       destination: imported.relativePath) else {
            ImageResourceManager().rollback(imported)
            throw ImageInsertionError.documentChanged
        }
    }

    @MainActor
    static func insertPaste(imageData: Data, draft: MarkdownImageDraft,
                            context: DocumentContext, model: MarkdownEditorModel,
                            currentContext: () -> DocumentContext) async throws {
        let imported = try await Task.detached(priority: .userInitiated) {
            try ImageResourceManager().savePastedImage(imageData, for: context)
        }.value
        guard !Task.isCancelled, currentContext() == context,
              model.commitDroppedImage(draft, alt: "スクリーンショット",
                                       destination: imported.relativePath) else {
            ImageResourceManager().rollback(imported)
            throw ImageInsertionError.documentChanged
        }
    }
}
