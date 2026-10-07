import Foundation

struct BibTeXEntry: Equatable, Sendable {
    let key: String
    let fields: [String: String]

    var bibliographyText: String {
        let author = fields["author"] ?? fields["organization"] ?? key
        let year = fields["year"].map { " (\($0))" } ?? ""
        let title = fields["title"].map { ". \($0)" } ?? ""
        let venue = (fields["journal"] ?? fields["booktitle"] ?? fields["publisher"])
            .map { ". \($0)" } ?? ""
        let doi = fields["doi"].map { ". doi:\($0)" } ?? ""
        return author + year + title + venue + doi + "."
    }
}

enum BibTeXParser {
    static func parse(_ source: String) -> [BibTeXEntry] {
        let chars = Array(source)
        var index = 0
        var entries: [BibTeXEntry] = []
        while index < chars.count {
            guard chars[index] == "@" else { index += 1; continue }
            index += 1
            let typeStart = index
            while index < chars.count, chars[index].isLetter { index += 1 }
            let entryType = String(chars[typeStart..<index]).lowercased()
            skipSpace(chars, &index)
            guard index < chars.count, chars[index] == "{" || chars[index] == "(" else { continue }
            let opening = chars[index]
            let closing: Character = chars[index] == "{" ? "}" : ")"
            index += 1
            if ["comment", "string", "preamble"].contains(entryType) {
                var depth = 1
                while index < chars.count, depth > 0 {
                    if chars[index] == opening, !escaped(chars, index) { depth += 1 }
                    if chars[index] == closing, !escaped(chars, index) { depth -= 1 }
                    index += 1
                }
                continue
            }
            let keyStart = index
            while index < chars.count, chars[index] != ",", chars[index] != closing { index += 1 }
            guard index < chars.count, chars[index] == "," else { continue }
            let key = String(chars[keyStart..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            index += 1
            var fields: [String: String] = [:]
            while index < chars.count {
                skipSpaceAndCommas(chars, &index)
                if index >= chars.count { break }
                if chars[index] == closing { index += 1; break }
                let nameStart = index
                while index < chars.count, chars[index].isLetter || chars[index] == "_" { index += 1 }
                guard index > nameStart else { index += 1; continue }
                let name = String(chars[nameStart..<index]).lowercased()
                skipSpace(chars, &index)
                guard index < chars.count, chars[index] == "=" else { continue }
                index += 1
                skipSpace(chars, &index)
                guard index < chars.count else { break }
                let value: String
                if chars[index] == "{" {
                    value = braced(chars, &index)
                } else if chars[index] == "\"" {
                    value = quoted(chars, &index)
                } else {
                    let start = index
                    while index < chars.count, chars[index] != ",", chars[index] != closing { index += 1 }
                    value = String(chars[start..<index])
                }
                fields[name] = clean(value)
            }
            if !key.isEmpty, !entries.contains(where: { $0.key == key }) {
                entries.append(BibTeXEntry(key: key, fields: fields))
            }
        }
        return entries
    }

    private static func braced(_ chars: [Character], _ index: inout Int) -> String {
        index += 1
        let start = index
        var depth = 1
        while index < chars.count {
            if chars[index] == "{", !escaped(chars, index) { depth += 1 }
            if chars[index] == "}", !escaped(chars, index) {
                depth -= 1
                if depth == 0 { break }
            }
            index += 1
        }
        let result = String(chars[start..<index])
        if index < chars.count { index += 1 }
        return result
    }

    private static func quoted(_ chars: [Character], _ index: inout Int) -> String {
        index += 1
        let start = index
        while index < chars.count {
            if chars[index] == "\"", !escaped(chars, index) { break }
            index += 1
        }
        let result = String(chars[start..<index])
        if index < chars.count { index += 1 }
        return result
    }

    private static func escaped(_ chars: [Character], _ index: Int) -> Bool {
        var cursor = index
        var count = 0
        while cursor > 0, chars[cursor - 1] == "\\" { count += 1; cursor -= 1 }
        return count % 2 == 1
    }

    private static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .replacingOccurrences(of: "\\&", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func skipSpace(_ chars: [Character], _ index: inout Int) {
        while index < chars.count, chars[index].isWhitespace { index += 1 }
    }

    private static func skipSpaceAndCommas(_ chars: [Character], _ index: inout Int) {
        while index < chars.count, chars[index].isWhitespace || chars[index] == "," { index += 1 }
    }
}

struct MarkdownCitationCatalog: Equatable, Sendable {
    static let empty = MarkdownCitationCatalog(entries: [])

    let entries: [BibTeXEntry]
    private let numbers: [String: Int]

    init(entries: [BibTeXEntry]) {
        self.entries = entries
        numbers = Dictionary(entries.enumerated().map { ($0.element.key, $0.offset + 1) },
                             uniquingKeysWith: { first, _ in first })
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.entries == rhs.entries }

    static func bibliographyURL(documentURL: URL?) -> URL? {
        guard let documentURL, documentURL.isFileURL else { return nil }
        return documentURL.deletingLastPathComponent().appendingPathComponent("references.bib")
    }

    /// 参考文献ファイルの版を表す値。大きさ・更新日時に加え、ファイルの識別子と内容の世代識別子を含める。
    /// 復元や同期で、大きさと更新日時を保ったまま内容だけが置き換わった場合も別の版として扱う。
    static func fingerprint(documentURL: URL?) -> String? {
        guard let url = bibliographyURL(documentURL: documentURL),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey,
                                                             .fileIdentifierKey, .generationIdentifierKey]) else {
            return nil
        }
        let generation = (values.generationIdentifier as? NSData).map { Data(referencing: $0).base64EncodedString() }
        return "\(values.fileSize ?? -1):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)" +
            ":\(values.fileIdentifier.map(String.init) ?? "-"):\(generation ?? "-")"
    }

    /// 同じ大きさ・更新日時の参考文献は、解析済みの結果を共有キャッシュから返す。
    static func load(documentURL: URL?) -> MarkdownCitationCatalog? {
        MarkdownCitationCatalogCache.shared.catalog(documentURL: documentURL)
    }

    /// 文脈に解決済みのカタログがあればそれを使い、なければディスクから読む。
    static func resolved(for context: DocumentContext) -> MarkdownCitationCatalog? {
        context.citationCatalog ?? load(documentURL: context.fileURL)
    }

    fileprivate static func read(bibliography url: URL) -> MarkdownCitationCatalog? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 1_000_000, let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return MarkdownCitationCatalog(entries: BibTeXParser.parse(source))
    }

    func hasCitation(in analysis: MarkdownAnalysis) -> Bool {
        guard !entries.isEmpty, analysis.containsCitationSyntax else { return false }
        return analysis.blocks.contains { block in
            block.kind != .codeBlock && (replaceInline(block.content) != block.content ||
                block.inlineCells.contains { replaceInline($0) != $0 })
        } || analysis.footnotes.entries.contains { replaceInline($0.content) != $0.content }
    }

    func replaceInline(_ source: String) -> String {
        guard !entries.isEmpty, source.contains("[@") else { return source }
        let chars = Array(source)
        var result = ""
        var index = 0
        var codeTicks = 0
        while index < chars.count {
            if chars[index] == "`" {
                let count = chars[index...].prefix(while: { $0 == "`" }).count
                if codeTicks == 0 { codeTicks = count }
                else if codeTicks == count { codeTicks = 0 }
                result += String(chars[index..<(index + count)])
                index += count
                continue
            }
            if codeTicks == 0, chars[index] == "[", index + 2 < chars.count,
               chars[index + 1] == "@", !escaped(chars, index),
               let end = chars[(index + 2)...].firstIndex(of: "]") {
                let key = String(chars[(index + 2)..<end])
                if key.allSatisfy({ $0.isLetter || $0.isNumber || "_:.+-".contains($0) }),
                   let number = numbers[key] {
                    result += "[\(number)]"
                    index = end + 1
                    continue
                }
            }
            result.append(chars[index])
            index += 1
        }
        return result
    }

    func materialize(_ markdown: String) -> String {
        var fence: String?
        var transformed: [String] = []
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if fence == nil { fence = marker }
                else if fence == marker { fence = nil }
                transformed.append(line)
            } else {
                transformed.append(fence == nil ? replaceInline(line) : line)
            }
        }
        let body = transformed.joined(separator: "\n")
        guard body != markdown, !entries.isEmpty else { return body }
        return body.trimmingCharacters(in: .newlines) + "\n\n## 参考文献\n\n" +
            entries.enumerated().map { "\($0.offset + 1). \($0.element.bibliographyText)" }
                .joined(separator: "\n") + "\n"
    }

    private func escaped(_ chars: [Character], _ index: Int) -> Bool {
        index > 0 && chars[index - 1] == "\\"
    }
}

/// 参考文献ファイルの解析結果を、大きさ・更新日時が変わるまで共有する。
final class MarkdownCitationCatalogCache: @unchecked Sendable {
    static let shared = MarkdownCitationCatalogCache()

    private struct Entry {
        let fingerprint: String
        let catalog: MarkdownCitationCatalog?
    }

    private let lock = NSLock()
    private var entries: [URL: Entry] = [:]
    private(set) var parseCount = 0

    func catalog(documentURL: URL?) -> MarkdownCitationCatalog? {
        guard let url = MarkdownCitationCatalog.bibliographyURL(documentURL: documentURL),
              let fingerprint = MarkdownCitationCatalog.fingerprint(documentURL: documentURL) else {
            return nil
        }
        lock.lock()
        if let cached = entries[url], cached.fingerprint == fingerprint {
            lock.unlock()
            return cached.catalog
        }
        lock.unlock()
        let catalog = MarkdownCitationCatalog.read(bibliography: url)
        lock.lock()
        parseCount += 1
        if entries.count >= 64 { entries.removeAll() }
        entries[url] = Entry(fingerprint: fingerprint, catalog: catalog)
        lock.unlock()
        return catalog
    }
}

/// 書類のフォルダと `references.bib` の変更を通知する。ポーリングは行わない。
///
/// 保存時の置き換え（rename）を検出するためフォルダを監視し、内容の上書きを検出するため
/// ファイル自体も監視する。ファイルが置き換わるたびにファイル側の監視を張り直す。
final class MarkdownCitationFileMonitor: @unchecked Sendable {
    private let directory: URL
    private let file: URL
    private let queue = DispatchQueue(label: "MKTownEditor.citationMonitor")
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var onChange: (@Sendable () -> Void)?

    private init(file: URL) {
        self.file = file
        directory = file.deletingLastPathComponent()
    }

    static func changes(documentURL: URL?) -> AsyncStream<Void> {
        AsyncStream { continuation in
            guard let file = MarkdownCitationCatalog.bibliographyURL(documentURL: documentURL) else {
                continuation.finish()
                return
            }
            let monitor = MarkdownCitationFileMonitor(file: file)
            guard monitor.start(onChange: { continuation.yield(()) }) else {
                continuation.finish()
                return
            }
            continuation.onTermination = { _ in monitor.stop() }
        }
    }

    private func start(onChange: @escaping @Sendable () -> Void) -> Bool {
        queue.sync {
            self.onChange = onChange
            guard let source = makeSource(directory, mask: .write) else { return false }
            directorySource = source
            watchFile()
            return true
        }
    }

    private func stop() {
        queue.async { [self] in
            onChange = nil
            directorySource?.cancel()
            directorySource = nil
            fileSource?.cancel()
            fileSource = nil
        }
    }

    private func watchFile() {
        fileSource?.cancel()
        fileSource = makeSource(file, mask: [.write, .extend, .delete, .rename, .attrib])
    }

    private func makeSource(_ url: URL, mask: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: mask, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, self.onChange != nil else { return }
            self.watchFile()
            self.onChange?()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }
}
