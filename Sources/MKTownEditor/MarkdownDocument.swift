import SwiftUI
import UniformTypeIdentifiers

struct MarkdownDocument: FileDocument {
    #if SWIFT_PACKAGE
    // A SwiftPM executable has no application Info.plist declaring imported types.
    static let markdownType = UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
    #else
    static let markdownType = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
    #endif
    static let readableContentTypes: [UTType] = [markdownType, .plainText]
    static let writableContentTypes: [UTType] = [markdownType]

    private var storedText: String
    var text: String {
        get { storedText }
        set {
            let normalized = MarkdownTextFormat.normalizedText(newValue)
            format.updateNewlines(from: storedText, to: normalized)
            storedText = normalized
        }
    }
    var format = MarkdownTextFormat()

    init(text: String = "") {
        storedText = MarkdownTextFormat.normalizedText(text)
    }

    #if os(macOS)
    private(set) var encoding: MarkdownTextEncoding = .utf8
    private(set) var pendingEncodingData: Data?
    private var hasUTF16BOM = false

    // CP932 has multiple byte sequences for some characters. Opening and saving an
    // unchanged file must preserve even the spelling that the system encoder doesn't emit.
    private struct OriginalFile {
        let data: Data
        let text: String
        let format: MarkdownTextFormat
    }
    private var originalFile: OriginalFile?

    struct UnrepresentableTextError: LocalizedError {
        var errorDescription: String? { MarkdownEncodingError.cannotEncode.errorDescription }
        var recoverySuggestion: String? {
            String(localized: "「文字コード」メニューの「保存できない文字」から、UTF-8への変換か文字の置換を選んでください。")
        }
    }

    init(data: Data, candidates: [MarkdownTextEncoding] = MarkdownEncodingPreferences.candidates()) throws {
        self.init(data: data, decoded: try MarkdownEncodingConverter.detect(data, candidates: candidates))
    }

    init(data: Data, encoding: MarkdownTextEncoding) throws {
        self.init(data: data, decoded: try MarkdownEncodingConverter.read(data, as: encoding))
    }

    private init(data: Data, decoded: MarkdownEncodingConverter.Decoded) {
        encoding = decoded.encoding
        (storedText, format) = MarkdownTextFormat.read(text: decoded.text,
                                                  hasUTF8BOM: encoding == .utf8 && decoded.hasBOM)
        hasUTF16BOM = (encoding == .utf16LE || encoding == .utf16BE) && decoded.hasBOM
        if encoding != .utf8 {
            originalFile = OriginalFile(data: data, text: text, format: format)
        }
    }

    // Only an interactive DocumentGroup open can ask the user to choose an encoding.
    // Batch operations use the throwing initializer above and skip undecodable files.
    init(opening data: Data, candidates: [MarkdownTextEncoding] = MarkdownEncodingPreferences.candidates()) throws {
        do {
            try self.init(data: data, candidates: candidates)
        } catch MarkdownEncodingError.cannotDecode {
            self.init()
            pendingEncodingData = data
        }
    }

    mutating func convertToUTF8() {
        guard encoding != .utf8 else { return }
        encoding = .utf8
        originalFile = nil
        hasUTF16BOM = false
        // A BOM takes precedence over a legacy charset declaration in the document.
        format.hasUTF8BOM = true
    }

    /// TextKit already has the complete edited buffer. Check that this exact edit produced
    /// it before applying the saved line endings, without building a second copy on each key.
    mutating func acceptEditorText(_ source: String, replacing range: NSRange, with replacement: String,
                                   preservingNewlines: Bool) -> Bool {
        guard Self.isValid(range, in: storedText as NSString) else { return false }
        let normalized = MarkdownTextFormat.normalizedText(replacement)
        let old = storedText.utf8, new = source.utf8
        let start = String.Index(utf16Offset: range.location, in: storedText)
        let end = String.Index(utf16Offset: NSMaxRange(range), in: storedText)
        let prefix = old[..<start], suffix = old[end...]
        guard new.count == prefix.count + normalized.utf8.count + suffix.count else { return false }
        let insertion = new.index(new.startIndex, offsetBy: prefix.count)
        let after = new.index(insertion, offsetBy: normalized.utf8.count)
        guard new[insertion..<after].elementsEqual(normalized.utf8),
              new[..<insertion].elementsEqual(prefix), new[after...].elementsEqual(suffix) else { return false }
        updateEditedEndings(in: [range], with: replacement, preservingNewlines: preservingNewlines)
        storedText = source
        return true
    }

    /// Apply disjoint UTF-16 edits against one snapshot. The editor works in LF offsets
    /// while a paste or an undo can carry the original endings of the replacement.
    mutating func replaceText(in ranges: [NSRange], with replacement: String, preservingNewlines: Bool) -> Bool {
        let source = storedText as NSString
        let descending = ranges.sorted { $0.location > $1.location }
        var limit = source.length
        for range in descending {
            guard Self.isValid(range, in: source), NSMaxRange(range) <= limit else { return false }
            limit = range.location
        }
        let normalized = MarkdownTextFormat.normalizedText(replacement)
        updateEditedEndings(in: descending, with: replacement, preservingNewlines: preservingNewlines)
        let updated = NSMutableString(string: storedText)
        for range in descending { updated.replaceCharacters(in: range, with: normalized) }
        storedText = updated as String
        return true
    }

    private mutating func updateEditedEndings(in ranges: [NSRange], with replacement: String,
                                              preservingNewlines: Bool) {
        let endings = format.endings(for: replacement, preservingNewlines: preservingNewlines)
        guard format.hasMixedNewlines || endings.contains(where: { $0 != format.newline }) else { return }
        let source = storedText as NSString
        guard !endings.isEmpty || ranges.contains(where: {
            $0.length > 0 && source.range(of: "\n", options: .literal, range: $0).location != NSNotFound
        }) else { return }
        let lines = MarkdownLineIndex(storedText)
        let newlineRanges = ranges.map { range in
            let first = lines.line(containingUTF16Offset: range.location) - 1
            let end = lines.line(containingUTF16Offset: NSMaxRange(range)) - 1
            return first..<end
        }
        format.replaceEndings(newlineRanges, with: endings, totalBefore: lines.lineCount - 1)
    }

    private static func isValid(_ range: NSRange, in text: NSString) -> Bool {
        guard range.location >= 0, range.location <= text.length, range.length >= 0,
              range.length <= text.length - range.location else { return false }
        // TextKit ranges can split a grapheme cluster, but not a UTF-16 surrogate pair.
        return [range.location, NSMaxRange(range)].allSatisfy {
            $0 == text.length || !(0xDC00...0xDFFF).contains(text.character(at: $0))
        }
    }

    mutating func replaceUnrepresentableCharacters() throws {
        let ranges = MarkdownEncodingConverter.unrepresentableRanges(in: text, as: encoding)
        guard !ranges.isEmpty else { return }
        let replaced = NSMutableString(string: text)
        for range in ranges.reversed() {
            replaced.replaceCharacters(in: range, with: MarkdownEncodingConverter.lossReplacement)
        }
        var updated = self
        updated.text = replaced as String
        _ = try updated.encodedData()
        self = updated
    }

    static func decode(_ data: Data, candidates: [MarkdownTextEncoding] = MarkdownEncodingPreferences.candidates()) throws -> String {
        try Self(data: data, candidates: candidates).text
    }
    #else
    init(data: Data) throws {
        let result = try MarkdownTextFormat.read(data)
        storedText = result.text
        format = result.format
    }

    static func decode(_ data: Data) throws -> String {
        try MarkdownTextFormat.read(data).text
    }
    #endif

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        #if os(macOS)
        self = try Self(opening: data)
        #else
        self = try Self(data: data)
        #endif
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(regularFileWithContents: encodedData())
    }

    func encodedData() throws -> Data {
        #if os(macOS)
        guard pendingEncodingData == nil else { throw MarkdownEncodingError.cannotDecode }
        if encoding != .utf8 {
            if let originalFile, format == originalFile.format,
               text.utf8.elementsEqual(originalFile.text.utf8) {
                return originalFile.data
            }
            let serialized = String(decoding: format.encode(text), as: UTF8.self)
            do {
                return try MarkdownEncodingConverter.encode(serialized, as: encoding, hasBOM: hasUTF16BOM)
            } catch MarkdownEncodingError.cannotEncode {
                throw UnrepresentableTextError()
            }
        }
        #endif
        return format.encode(text)
    }
}
