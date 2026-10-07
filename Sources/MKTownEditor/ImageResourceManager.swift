import AppKit
import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class RemoteImageStore: ObservableObject {
    static let shared = RemoteImageStore()
    @Published private(set) var revision = 0
    private let images = NSCache<NSURL, NSImage>()
    private let fullImageData = NSCache<NSURL, NSData>()
    private var failed = Set<URL>()
    private var inFlight = Set<URL>()
    private(set) var isEnabled = false
    private let fetch: @Sendable (URL) async throws -> Data

    init(fetch: @escaping @Sendable (URL) async throws -> Data = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode), data.count <= 10_000_000 else {
            throw URLError(.badServerResponse)
        }
        return data
    }) {
        self.fetch = fetch
        images.totalCostLimit = 40_000_000
        fullImageData.totalCostLimit = 40_000_000
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if !enabled {
            images.removeAllObjects()
            fullImageData.removeAllObjects()
            failed.removeAll()
        }
        revision += 1
    }

    func image(for url: URL) -> NSImage? {
        guard isEnabled else { return nil }
        return images.object(forKey: url as NSURL)
    }

    func fullImage(for url: URL) -> NSImage? {
        guard isEnabled, let data = fullImageData.object(forKey: url as NSURL) else { return nil }
        return NSImage(data: data as Data)
    }

    func hasFailed(_ url: URL) -> Bool { isEnabled && failed.contains(url) }

    /// 本文から外部画像のURLを集める。解析済みの結果を渡せば本文を再解析しない。
    nonisolated static func referencedURLs(in markdown: String,
                                           analysis providedAnalysis: MarkdownAnalysis? = nil) -> Set<URL> {
        guard markdown.range(of: "http", options: .caseInsensitive) != nil else { return [] }
        return Set(imageDestinations(in: markdown, analysis: providedAnalysis)
            .compactMap { URL(string: $0) }
            .filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") })
    }

    /// 本文の画像の参照先。コードブロックとインラインコードの中は除き、参照形式も解決する。
    nonisolated static func imageDestinations(in markdown: String,
                                              analysis providedAnalysis: MarkdownAnalysis? = nil) -> [String] {
        guard markdown.contains("!["), !Task.isCancelled else { return [] }
        let analysis = providedAnalysis ?? MarkdownAnalysis(markdown)
        // 取り消された走査は、解析・マスク・リンク抽出の各段階の間で打ち切る。
        guard !Task.isCancelled else { return [] }
        let masked = NSMutableString(string: markdown)
        let codeBlocks = analysis.blocks.filter { $0.kind == .codeBlock }.map(\.sourceRange)
        for range in codeBlocks.sorted(by: { $0.location > $1.location }) {
            masked.replaceCharacters(in: range, with: String(repeating: " ", count: range.length))
        }
        for range in MarkdownInlineSyntax.codeSpanRanges(in: masked as String)
            .sorted(by: { $0.location > $1.location }) {
            masked.replaceCharacters(in: range, with: String(repeating: " ", count: range.length))
        }
        guard !Task.isCancelled else { return [] }
        let resolved = MarkdownRenderer.resolveReferences(in: masked as String,
            using: analysis.references)
        guard !Task.isCancelled else { return [] }
        return MarkdownLinkSyntax.inlineLinks(in: resolved).filter(\.isImage).map(\.destination)
    }

    func load(_ url: URL) async {
        guard isEnabled, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              images.object(forKey: url as NSURL) == nil,
              !failed.contains(url), !inFlight.contains(url) else { return }
        inFlight.insert(url)
        defer { inFlight.remove(url) }
        do {
            let data = try await fetch(url)
            guard isEnabled, !Task.isCancelled, data.count <= 10_000_000 else {
                throw URLError(.cannotDecodeContentData)
            }
            // デコードはメインアクターの外で、同時実行数を制限して行う。プレビューを閉じるなどで
            // 読み込みが取り消されたら、待機中・実行前のデコードも取り消す。
            let worker = Task.detached(priority: .utility) { () -> CGImage? in
                let limiter = ImageDecodeLimiter.remote
                await limiter.acquire()
                guard !Task.isCancelled else {
                    await limiter.release()
                    return nil
                }
                let image: CGImage? = {
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          CGImageSourceGetType(source) != nil else { return nil }
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 960
                    ] as CFDictionary)
                }()
                await limiter.release()
                return image
            }
            let decoded = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard isEnabled, !Task.isCancelled, let thumbnail = decoded else {
                throw URLError(.cannotDecodeContentData)
            }
            let scale = min(1, 480 / CGFloat(thumbnail.width), 320 / CGFloat(thumbnail.height))
            let image = NSImage(cgImage: thumbnail,
                size: NSSize(width: CGFloat(thumbnail.width) * scale,
                             height: CGFloat(thumbnail.height) * scale))
            images.setObject(image, forKey: url as NSURL,
                cost: thumbnail.width * thumbnail.height * 4)
            fullImageData.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
            revision += 1
        } catch {
            guard isEnabled, !Task.isCancelled else { return }
            failed.insert(url)
            revision += 1
        }
    }
}

/// ローカル画像のプレビュー用縮小画像を、パス・更新日時・大きさごとに保持する。
///
/// 描画のたびにディスクから再デコードしないためのキャッシュ。表示を確実に保つため、
/// 破棄はメモリ圧ではなく総コストの上限を超えたときに古い順で行う。
///
/// 直近に使った画像は上限を超えても追い出さない。表示中の画像は描画結果も同じ画像データを
/// 保持しているため、追い出してもメモリは減らず、読み直しと再描画を繰り返すだけになる。
/// 上限を超えた分は、しばらく使われていない画像から古い順に追い出す。
final class LocalImageCache: @unchecked Sendable {
    static let shared = LocalImageCache()

    struct Key: Hashable, Sendable {
        let path: String
        let modified: Date?
        let size: Int?
        /// 内容の世代識別子。大きさと更新日時を保ったまま内容が置き換わった場合も別の版にする。
        let generation: Data?

        init(path: String, modified: Date?, size: Int?, generation: Data? = nil) {
            self.path = path
            self.modified = modified
            self.size = size
            self.generation = generation
        }
    }

    private struct Entry {
        let image: NSImage?
        let cost: Int
        var lastUse: UInt64
        var lastUseDate: Date
        /// デコードを開始した順番。同じファイルの版の新旧はこの順で判定する。
        let generation: UInt64
    }

    private let lock = NSLock()
    private let costLimit: Int
    private let protectionInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var entries: [Key: Entry] = [:]
    private var totalCost = 0
    private var clock: UInt64 = 0
    private var nextGeneration: UInt64 = 0
    private(set) var decodeCount = 0

    init(costLimit: Int = 64_000_000, protectionInterval: TimeInterval = 5,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.costLimit = costLimit
        self.protectionInterval = protectionInterval
        self.now = now
    }

    static func key(for fileURL: URL) -> Key? {
        guard fileURL.isFileURL else { return nil }
        // URLは取得済みの属性を保持するため、更新を見落とさないよう毎回読み直す。
        var fileURL = fileURL
        fileURL.removeAllCachedResourceValues()
        guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey,
                                                                 .contentModificationDateKey, .fileSizeKey,
                                                                 .generationIdentifierKey]),
              values.isRegularFile == true else { return nil }
        return Key(path: fileURL.standardizedFileURL.path, modified: values.contentModificationDate,
                   size: values.fileSize,
                   generation: (values.generationIdentifier as? NSData).map { Data(referencing: $0) })
    }

    /// キャッシュ済みなら `.some`（デコードできなかった画像は `.some(nil)`）、未読込なら `nil` を返す。
    func cachedImage(for key: Key) -> NSImage?? {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[key] else { return nil }
        clock += 1
        entry.lastUse = clock
        entry.lastUseDate = now()
        entries[key] = entry
        return .some(entry.image)
    }

    /// キャッシュになければその場でデコードする。書き出しなど同期的に画像が必要な処理で使う。
    func image(at fileURL: URL) -> NSImage? {
        guard let key = Self.key(for: fileURL) else { return nil }
        if let cached = cachedImage(for: key) { return cached }
        return decode(key: key, fileURL: fileURL)
    }

    @discardableResult
    func decode(key: Key, fileURL: URL, generation reserved: UInt64? = nil) -> NSImage? {
        let generation = reserved ?? reserveGeneration()
        let image = ImageResourceManager().previewImage(at: fileURL, alt: "")
        insert(image, for: key, generation: generation)
        return image
    }

    /// デコードを始める前に順番を確保する。後から始めたデコードほど新しいファイルの内容を読む。
    func reserveGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        nextGeneration += 1
        return nextGeneration
    }

    /// デコード結果を保持する。同じファイルについて、後から始めたデコードの結果が既にあれば、
    /// 遅れて終わったこの結果は保持しない。版の新旧はファイルの更新日時ではなく開始順で決める。
    /// 古い日付のファイルに戻した場合も、後から始めたデコードが新しい版になる。
    func insert(_ image: NSImage?, for key: Key, generation: UInt64) {
        let cost = image.map { image in
            image.representations.reduce(0) { $0 + $1.pixelsWide * $1.pixelsHigh * 4 }
        } ?? 0
        lock.lock()
        defer { lock.unlock() }
        decodeCount += 1
        clock += 1
        if entries.contains(where: { $0.key.path == key.path && $0.value.generation > generation }) { return }
        // 同じファイルの以前の版は表示されないため、まとめて除く。
        for (staleKey, stale) in entries where staleKey.path == key.path {
            entries[staleKey] = nil
            totalCost -= stale.cost
        }
        let date = now()
        entries[key] = Entry(image: image, cost: cost, lastUse: clock, lastUseDate: date, generation: generation)
        totalCost += cost
        let protectedSince = date.addingTimeInterval(-protectionInterval)
        while totalCost > costLimit, entries.count > 1 {
            guard let oldest = entries.filter({ $0.key != key && $0.value.lastUseDate < protectedSince })
                .min(by: { $0.value.lastUse < $1.value.lastUse }) else { break }
            entries[oldest.key] = nil
            totalCost -= oldest.value.cost
        }
    }

    func contains(_ key: Key) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[key] != nil
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        totalCost = 0
    }
}

/// ローカル画像のデコードを要求したプレビューを表す。参照の同一性だけを使う。
final class LocalImageRequester: Sendable {}

/// プレビューのローカル画像を背景でデコードし、完了したら `revision` を進めて再描画させる。
@MainActor
final class LocalImageStore: ObservableObject {
    static let shared = LocalImageStore()
    @Published private(set) var revision = 0
    let cache: LocalImageCache
    private let limiter: ImageDecodeLimiter
    private struct Job {
        let id: Int
        let task: Task<Void, Never>
        var owners: Set<ObjectIdentifier>
        /// 要求元を指定しない要求があれば、取り消さない。
        var isShared: Bool
    }
    private var jobs: [LocalImageCache.Key: Job] = [:]
    private var nextJobID = 0
    private var publishScheduled = false

    init(cache: LocalImageCache = .shared, limiter: ImageDecodeLimiter = .local) {
        self.cache = cache
        self.limiter = limiter
    }

    enum Lookup {
        case image(NSImage)
        case unavailable
        case loading
    }

    /// 画像を返すか、背景でのデコードを要求する。`requester` が閉じたら `cancelRequests(from:)`
    /// で、その要求元だけが待っていたデコードを取り消せる。
    func lookup(_ fileURL: URL, requester: LocalImageRequester? = nil) -> Lookup {
        guard let key = LocalImageCache.key(for: fileURL) else { return .unavailable }
        if let cached = cache.cachedImage(for: key) {
            return cached.map(Lookup.image) ?? .unavailable
        }
        let owner = requester.map(ObjectIdentifier.init)
        if var job = jobs[key] {
            if let owner { job.owners.insert(owner) } else { job.isShared = true }
            jobs[key] = job
            return .loading
        }
        let cache = cache
        let limiter = limiter
        nextJobID += 1
        let id = nextJobID
        // 版の新旧は問い合わせの順で決める。背景の処理は起動順に実行されるとは限らない。
        let generation = cache.reserveGeneration()
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            await limiter.acquire()
            // 順番待ちの間に要求元がすべて閉じていれば、読み込まずに終える。
            if !Task.isCancelled { cache.decode(key: key, fileURL: fileURL, generation: generation) }
            await limiter.release()
            await self?.finish(key, job: id)
        }
        jobs[key] = Job(id: id, task: task, owners: owner.map { [$0] } ?? [], isShared: owner == nil)
        return .loading
    }

    /// 要求元が閉じた時に呼ぶ。ほかに待っている要求元のないデコードを取り消す。
    func cancelRequests(from requester: LocalImageRequester) {
        let owner = ObjectIdentifier(requester)
        for (key, var job) in jobs where job.owners.contains(owner) {
            job.owners.remove(owner)
            if job.owners.isEmpty && !job.isShared {
                job.task.cancel()
                jobs[key] = nil
            } else {
                jobs[key] = job
            }
        }
    }

    /// 画像の参照先から、描画時にデコードを要求するローカル画像のパスを求める。
    nonisolated static func localImagePaths(destinations: [String], context: DocumentContext) -> Set<String> {
        Set(destinations.compactMap { destination in
            let encoded = destination.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? destination
            guard (URL(string: destination) ?? URL(string: encoded))?.scheme == nil else { return nil }
            return context.resolveLocalResource(destination)?.path
        })
    }

    func pendingPaths(for requester: LocalImageRequester) -> Set<String> {
        let owner = ObjectIdentifier(requester)
        return Set(jobs.filter { $0.value.owners.contains(owner) }.map(\.key.path))
    }

    /// 表示内容が変わった時に呼ぶ。要求元が待っているデコードのうち、`paths` にない画像の分を取り下げる。
    func reconcileRequests(from requester: LocalImageRequester, keepingPaths paths: Set<String>) {
        let owner = ObjectIdentifier(requester)
        for (key, var job) in jobs where job.owners.contains(owner) && !paths.contains(key.path) {
            job.owners.remove(owner)
            if job.owners.isEmpty && !job.isShared {
                job.task.cancel()
                jobs[key] = nil
            } else {
                jobs[key] = job
            }
        }
    }

    var hasPendingDecodes: Bool { !jobs.isEmpty }

    private func finish(_ key: LocalImageCache.Key, job id: Int) {
        // 取り消した要求の後に同じ画像の要求が入っていれば、その記録は残す。
        if jobs[key]?.id == id { jobs[key] = nil }
        guard !publishScheduled, cache.contains(key) else { return }
        // 同時に終わったデコードをまとめ、プレビューの再描画を1回にする。
        publishScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.publishScheduled = false
            self.revision &+= 1
        }
    }
}

/// 画像のデコードを同時に実行する数の上限。多数の画像を一度に読み込んでも、
/// デコード中の画像データとCPUの使用を抑える。
actor ImageDecodeLimiter {
    static let remote = ImageDecodeLimiter(limit: 4)
    static let local = ImageDecodeLimiter(limit: 4)

    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var running = 0
    private(set) var maximumRunning = 0

    init(limit: Int) {
        available = max(1, limit)
    }

    func acquire() async {
        if available > 0 {
            available -= 1
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
        running += 1
        maximumRunning = max(maximumRunning, running)
    }

    func release() {
        running -= 1
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

enum MarkdownImageInspectionLink {
    static func make(_ destination: URL) -> URL? {
        guard destination.isFileURL ||
                ["http", "https"].contains(destination.scheme?.lowercased() ?? "") else { return nil }
        var components = URLComponents()
        components.scheme = "mktown-image"
        components.path = "/inspect"
        components.queryItems = [URLQueryItem(name: "url", value: destination.absoluteString)]
        return components.url
    }

    static func destination(_ link: URL) -> URL? {
        guard link.scheme == "mktown-image", link.path == "/inspect",
              let value = URLComponents(url: link, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "url" })?.value,
              let destination = URL(string: value),
              destination.isFileURL || ["http", "https"].contains(destination.scheme?.lowercased() ?? "")
        else { return nil }
        return destination
    }
}

enum ImageInput: Sendable {
    case remote(String)
    case file(URL)
}

enum ImageImportMode: String, Codable, CaseIterable, Sendable {
    case managedCopy
    case relativeReference

    var title: String {
        switch self {
        case .managedCopy: String(localized: "assets にコピー")
        case .relativeReference: String(localized: "元ファイルを参照")
        }
    }
}

enum ImageOutputFormat: String, CaseIterable, Sendable {
    case png = "PNG"
    case jpeg = "JPEG"
    case heic = "HEIC"

    var type: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        }
    }

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .heic: "heic"
        }
    }
}

struct ImageTransformOptions: Sendable {
    let maxWidth: Int?
    let maxHeight: Int?
    let format: ImageOutputFormat
    let quality: Double

    var isValid: Bool {
        (maxWidth.map { (1...10_000).contains($0) } ?? true) &&
        (maxHeight.map { (1...10_000).contains($0) } ?? true) &&
        (0...1).contains(quality)
    }
}

struct ImportedImage: Sendable {
    let relativePath: String
    let createdFileURL: URL?
}

enum ImageResourceError: LocalizedError, Equatable {
    case unsavedDocument
    case invalidImage
    case invalidAttachment
    case noAvailableName
    case unsafeAssetsDirectory

    var errorDescription: String? {
        switch self {
        case .unsavedDocument: String(localized: "ファイル画像を挿入するには、先に文書を保存してください。")
        case .invalidImage: String(localized: "選択したファイルは対応する画像ではありません。")
        case .invalidAttachment: String(localized: "選択したファイルを添付できません。")
        case .noAvailableName: String(localized: "画像の保存名を決められません。")
        case .unsafeAssetsDirectory: String(localized: "画像保存先の assets フォルダを確認してください。")
        }
    }
}

enum ImageInsertionError: LocalizedError {
    case documentChanged

    var errorDescription: String? {
        String(localized: "本文が変更されたため画像を挿入できません。もう一度挿入してください。")
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

        let assets = try assetsDirectory(beside: directory, name: context.attachmentDirectory.rawValue)
        let staging = assets.appendingPathComponent(".import-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: source, to: staging)
        if let existing = try matchingImage(for: staging, in: assets) {
            return ImportedImage(relativePath: "\(context.attachmentDirectory.rawValue)/\(existing.lastPathComponent)",
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
                return ImportedImage(relativePath: "\(context.attachmentDirectory.rawValue)/\(fileName)", createdFileURL: destination)
            } catch {
                if (error as? CocoaError)?.code == .fileWriteFileExists {
                    if fileManager.contentsEqual(atPath: staging.path, andPath: destination.path) {
                        return ImportedImage(relativePath: "\(context.attachmentDirectory.rawValue)/\(fileName)", createdFileURL: nil)
                    }
                    continue
                }
                throw error
            }
        }
        throw ImageResourceError.noAvailableName
    }

    func deriveImage(at fileURL: URL, for context: DocumentContext,
                     options: ImageTransformOptions) throws -> ImportedImage {
        guard let directoryURL = context.directoryURL else { throw ImageResourceError.unsavedDocument }
        guard options.isValid else { throw ImageResourceError.invalidImage }
        let hasAccess = fileURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { fileURL.stopAccessingSecurityScopedResource() } }
        guard fileURL.isFileURL,
              let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              CGImageSourceGetType(source) != nil,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              pixelWidth > 0, pixelHeight > 0 else { throw ImageResourceError.invalidImage }
        let orientation = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
        let rotated = (5...8).contains(orientation)
        let width = rotated ? pixelHeight : pixelWidth
        let height = rotated ? pixelWidth : pixelHeight
        let scale = min(1,
            Double(options.maxWidth ?? width) / Double(width),
            Double(options.maxHeight ?? height) / Double(height),
            10_000 / Double(max(width, height)))
        let outputSize = max(1, Int(ceil(Double(max(width, height)) * scale)))
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: outputSize
        ] as CFDictionary) else { throw ImageResourceError.invalidImage }
        let assets = try assetsDirectory(beside: directoryURL.standardizedFileURL.resolvingSymlinksInPath(),
                                         name: context.attachmentDirectory.rawValue)
        let staging = assets.appendingPathComponent(".derive-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staging) }
        guard let destination = CGImageDestinationCreateWithURL(staging as CFURL,
            options.format.type.identifier as CFString, 1, nil) else {
            throw ImageResourceError.invalidImage
        }
        let encoding: CFDictionary = options.format == .png ? [:] as CFDictionary : [
            kCGImageDestinationLossyCompressionQuality: options.quality
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, encoding)
        guard CGImageDestinationFinalize(destination) else { throw ImageResourceError.invalidImage }
        if let existing = try matchingImage(for: staging, in: assets) {
            return ImportedImage(relativePath: "\(context.attachmentDirectory.rawValue)/\(existing.lastPathComponent)",
                                 createdFileURL: nil)
        }
        let base = fileURL.deletingPathExtension().lastPathComponent + "-edited"
        let ext = options.format.fileExtension
        for suffix in 1...10_000 {
            let name = suffix == 1 ? "\(base).\(ext)" : "\(base)-\(suffix).\(ext)"
            let target = assets.appendingPathComponent(name)
            if fileManager.fileExists(atPath: target.path) { continue }
            do {
                try fileManager.moveItem(at: staging, to: target)
                return ImportedImage(relativePath: "\(context.attachmentDirectory.rawValue)/\(name)", createdFileURL: target)
            } catch {
                if (error as? CocoaError)?.code == .fileWriteFileExists { continue }
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

        let assets = try assetsDirectory(beside: directoryURL.standardizedFileURL.resolvingSymlinksInPath(),
                                         name: context.attachmentDirectory.rawValue)
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
                return ImportedImage(relativePath: "\(context.attachmentDirectory.rawValue)/\(name)", createdFileURL: url)
            } catch {
                if (error as? CocoaError)?.code == .fileWriteFileExists { continue }
                throw error
            }
        }
        throw ImageResourceError.noAvailableName
    }

    private func assetsDirectory(beside directory: URL, name: String) throws -> URL {
        let directoryPath = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        let assets = directory.appendingPathComponent(name, isDirectory: true)
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
    static func insert(alt: String, input: ImageInput, title: String, width: Int? = nil,
                       transform: ImageTransformOptions? = nil,
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
                if let transform {
                    return try ImageResourceManager().deriveImage(at: url, for: context,
                                                                  options: transform)
                }
                return try ImageResourceManager().importImage(at: url, for: context)
            }.value
            imported = result
            destination = result.relativePath
        }
        guard !Task.isCancelled, currentContext() == context,
              model.commitImage(alt: alt, destination: destination, title: title,
                                width: width) else {
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
              model.commitDroppedImage(draft, alt: alt.isEmpty ? String(localized: "画像") : alt,
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
              model.commitDroppedImage(draft, alt: String(localized: "スクリーンショット"),
                                       destination: imported.relativePath) else {
            ImageResourceManager().rollback(imported)
            throw ImageInsertionError.documentChanged
        }
    }
}

struct FileAttachmentManager {
    func importFile(at fileURL: URL, for context: DocumentContext,
                    mode: ImageImportMode) throws -> ImportedImage {
        guard let directory = context.directoryURL else { throw ImageResourceError.unsavedDocument }
        let hasAccess = fileURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { fileURL.stopAccessingSecurityScopedResource() } }
        let source = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        guard source.isFileURL,
              (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { throw ImageResourceError.invalidAttachment }
        let base = directory.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        if source.path.hasPrefix(prefix) {
            return ImportedImage(relativePath: String(source.path.dropFirst(prefix.count)),
                                 createdFileURL: nil)
        }
        if mode == .relativeReference {
            let baseParts = base.pathComponents
            let sourceParts = source.pathComponents
            let common = zip(baseParts, sourceParts).prefix(while: { $0.0 == $0.1 }).count
            let parts = Array(repeating: "..", count: baseParts.count - common) +
                Array(sourceParts.dropFirst(common))
            return ImportedImage(relativePath: parts.joined(separator: "/"), createdFileURL: nil)
        }
        let assets = base.appendingPathComponent(context.attachmentDirectory.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        guard assets.resolvingSymlinksInPath().path.hasPrefix(prefix) else {
            throw ImageResourceError.unsafeAssetsDirectory
        }
        let staging = assets.appendingPathComponent(".attach-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        let size = try staging.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let existing = try FileManager.default.contentsOfDirectory(at: assets,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]).first { candidate in
                guard let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey,
                    .isSymbolicLinkKey, .fileSizeKey]) else { return false }
                return values.isRegularFile == true && values.isSymbolicLink != true &&
                    candidate.pathExtension.lowercased() == source.pathExtension.lowercased() &&
                    values.fileSize == size &&
                    FileManager.default.contentsEqual(atPath: staging.path, andPath: candidate.path)
            }
        if let existing {
            return ImportedImage(relativePath: "\(context.attachmentDirectory.rawValue)/\(existing.lastPathComponent)",
                                 createdFileURL: nil)
        }
        let name = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        for suffix in 1...10_000 {
            let filename = suffix == 1 ? source.lastPathComponent :
                "\(name)-\(suffix)" + (ext.isEmpty ? "" : ".\(ext)")
            let target = assets.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: target.path) { continue }
            do {
                try FileManager.default.moveItem(at: staging, to: target)
                return ImportedImage(relativePath: "\(context.attachmentDirectory.rawValue)/\(filename)", createdFileURL: target)
            } catch {
                if (error as? CocoaError)?.code == .fileWriteFileExists { continue }
                throw error
            }
        }
        throw ImageResourceError.noAvailableName
    }
}

enum AttachmentInsertionService {
    @MainActor
    static func insert(label: String, fileURL: URL, mode: ImageImportMode,
                       context: DocumentContext, model: MarkdownEditorModel,
                       currentContext: () -> DocumentContext) async throws {
        let imported = try await Task.detached(priority: .userInitiated) {
            try FileAttachmentManager().importFile(at: fileURL, for: context, mode: mode)
        }.value
        guard !Task.isCancelled, currentContext() == context,
              model.commitLink(label: label, destination: imported.relativePath, title: "") else {
            ImageResourceManager().rollback(imported)
            throw ImageInsertionError.documentChanged
        }
    }
}
