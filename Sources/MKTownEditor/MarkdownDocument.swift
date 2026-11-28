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

    var text: String
    var format = MarkdownTextFormat()

    init(text: String = "") {
        self.text = text
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
        (text, format) = MarkdownTextFormat.read(text: decoded.text,
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

    mutating func replaceUnrepresentableCharacters() throws {
        let ranges = MarkdownEncodingConverter.unrepresentableRanges(in: text, as: encoding)
        guard !ranges.isEmpty else { return }
        let replaced = NSMutableString(string: text)
        for range in ranges.reversed() {
            replaced.replaceCharacters(in: range, with: "?")
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
        text = result.text
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
