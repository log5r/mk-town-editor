import Foundation

enum MarkdownTextEncoding: String, CaseIterable, Identifiable, Codable, Sendable {
    case utf8
    case shiftJIS
    case eucJP
    case iso2022JP
    case latin1
    case utf16LE
    case utf16BE

    // EUC-JP kana can also be valid CP932 half-width characters. Latin-1 is opt-in
    // because it can decode arbitrary bytes, including damaged Japanese documents.
    static let defaultDetectionOrder: [Self] = [.utf8, .eucJP, .shiftJIS, .iso2022JP, .utf16LE, .utf16BE]

    var id: Self { self }

    var title: String {
        switch self {
        case .shiftJIS: "Shift JIS (CP932)"
        case .utf16LE: "UTF-16 LE"
        case .utf16BE: "UTF-16 BE"
        default: declarationName
        }
    }

    fileprivate var declarationName: String {
        switch self {
        case .utf8: "UTF-8"
        case .shiftJIS: "Windows-31J"
        case .eucJP: "EUC-JP"
        case .iso2022JP: "ISO-2022-JP"
        case .latin1: "ISO-8859-1"
        case .utf16LE: "UTF-16LE"
        case .utf16BE: "UTF-16BE"
        }
    }

    var foundationEncoding: String.Encoding {
        switch self {
        case .utf8: .utf8
        // Foundation's Shift JIS is Windows code page 932, NEC and IBM extensions included.
        case .shiftJIS: .shiftJIS
        case .eucJP: .japaneseEUC
        case .iso2022JP: .iso2022JP
        case .latin1: .isoLatin1
        case .utf16LE: .utf16LittleEndian
        case .utf16BE: .utf16BigEndian
        }
    }

    fileprivate var byteOrderMark: [UInt8] {
        switch self {
        case .utf8: [0xEF, 0xBB, 0xBF]
        case .utf16LE: [0xFF, 0xFE]
        case .utf16BE: [0xFE, 0xFF]
        default: []
        }
    }

    fileprivate init?(declaration: String) {
        switch declaration.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "utf-8", "utf8": self = .utf8
        case "shift-jis", "shiftjis", "sjis", "x-sjis", "windows-31j", "windows-932", "cp932", "ms932":
            self = .shiftJIS
        case "euc-jp", "eucjp": self = .eucJP
        case "iso-2022-jp", "iso2022-jp", "iso2022jp": self = .iso2022JP
        case "iso-8859-1", "latin1", "latin-1": self = .latin1
        case "utf-16le", "utf16le": self = .utf16LE
        case "utf-16be", "utf16be": self = .utf16BE
        default: return nil
        }
    }
}

enum MarkdownEncodingError: LocalizedError {
    case cannotDecode
    case cannotEncode

    var errorDescription: String? {
        switch self {
        case .cannotDecode: String(localized: "この文字コードでは内容を損失なく読み込めません。")
        case .cannotEncode: String(localized: "選んだ文字コードでは表せない文字があります。別の文字コードを選んでください。")
        }
    }
}

enum MarkdownEncodingConverter {
    typealias Decoded = (text: String, encoding: MarkdownTextEncoding, hasBOM: Bool)
    static let lossReplacement = "?"

    static func detect(_ data: Data, candidates: [MarkdownTextEncoding] = MarkdownTextEncoding.defaultDetectionOrder) throws -> Decoded {
        if data.starts(with: [0xFF, 0xFE, 0, 0]) || data.starts(with: [0, 0, 0xFE, 0xFF]) {
            // A UTF-32 BOM starts with the same bytes as UTF-16 LE on little-endian systems.
            throw MarkdownEncodingError.cannotDecode
        }
        for encoding in [MarkdownTextEncoding.utf8, .utf16LE, .utf16BE] where data.starts(with: encoding.byteOrderMark) {
            return try read(data, as: encoding)
        }
        if let declaration = encodingDeclaration(in: data) {
            guard let encoding = declaration.encoding else {
                throw MarkdownEncodingError.cannotDecode
            }
            return try read(data, as: encoding)
        }

        // Both UTF-16 ASCII text and ISO-2022-JP can consist entirely of valid UTF-8 bytes.
        if let encoding = utf16ByteOrder(in: data) {
            guard candidates.contains(encoding) else { throw MarkdownEncodingError.cannotDecode }
            return try read(data, as: encoding)
        }
        // A NUL can be a byte of a UTF-16 code unit or part of a binary file. Without
        // a convincing byte order, require an explicit choice even if UTF-8 would decode.
        guard data.range(of: Data([0])) == nil else { throw MarkdownEncodingError.cannotDecode }
        if hasISO2022Shift(in: data) {
            guard candidates.contains(.iso2022JP) else { throw MarkdownEncodingError.cannotDecode }
            return try read(data, as: .iso2022JP)
        }

        var shortMatch: Decoded?
        for encoding in candidates where encoding != .utf16LE && encoding != .utf16BE {
            guard let match = try? read(data, as: encoding) else { continue }
            if let shortMatch, !match.text.utf8.elementsEqual(shortMatch.text.utf8) {
                throw MarkdownEncodingError.cannotDecode
            }
            if encoding == .utf8 || candidates.count == 1 { return match }
            let highBytes = data.lazy.filter { $0 >= 0x80 }.prefix(4).count
            if highBytes == 0 || highBytes >= 4 { return match }
            // One isolated legacy byte gives no reliable identification. A short sequence
            // with two distinct lossless readings must be selected from the previews.
            if highBytes > 1 { shortMatch = shortMatch ?? match }
        }
        guard let shortMatch else { throw MarkdownEncodingError.cannotDecode }
        return shortMatch
    }

    // Only inspect declarations in the header. Examples further down a Markdown document
    // must not change the encoding used to reopen it.
    private static let textDeclaration = try! NSRegularExpression(
        pattern: #"(?im)^[ \t]*(?:(?:<!--|//|/\*|[#;!*])[ \t]*)?(?:-\*-[^\r\n]*?\b)?(?:coding|charset)[ \t]*[:=][ \t]*["']?([\w.-]+)"#
    )
    private static let markupDeclaration = try! NSRegularExpression(
        pattern: #"(?i)(?:<meta\b[^>]*?\bcharset\s*=|<\?xml\b[^>]*?\bencoding\s*=)[ \t]*["']?([\w.-]+)"#
    )

    private struct EncodingDeclaration {
        let encoding: MarkdownTextEncoding?
        let byteRange: Range<Data.Index>
    }

    private static func encodingDeclaration(in data: Data) -> EncodingDeclaration? {
        // A declaration is ASCII. Mapping each other byte to a single replacement character
        // keeps UTF-16 regex offsets aligned with file bytes, including CP932 aliases and CRLF.
        let sample = data.prefix(4096)
        let header = String(decoding: sample, as: Unicode.ASCII.self)
        let opening = header.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32).lowercased()
        let limit: String.Index
        let pattern: NSRegularExpression
        if ["<!doctype html", "<html", "<head", "<meta", "<?xml"].contains(where: opening.hasPrefix) {
            limit = header.endIndex
            pattern = markupDeclaration
        } else {
            let lines = header.split(maxSplits: 2, omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            limit = lines.prefix(2).last?.endIndex ?? header.startIndex
            pattern = textDeclaration
        }
        let area = NSRange(header.startIndex..<limit, in: header)
        guard let match = pattern.firstMatch(in: header, range: area) else { return nil }
        let token = match.range(at: 1)
        let start = data.startIndex + token.location
        var end = start + token.length
        if end == sample.endIndex {
            // When the token starts inside the header but crosses the sample boundary,
            // include its remaining bytes before replacing it.
            end = data[end...].firstIndex { byte in
                switch byte {
                case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F: false
                default: true
                }
            } ?? data.endIndex
        }
        let value = String(decoding: data[start..<end], as: Unicode.ASCII.self)
        return EncodingDeclaration(encoding: MarkdownTextEncoding(declaration: value), byteRange: start..<end)
    }

    private static func utf16ByteOrder(in data: Data) -> MarkdownTextEncoding? {
        let sample = data.prefix(4096)
        guard sample.contains(0) else { return nil }
        var little = 0
        var big = 0
        var index = sample.startIndex
        while index + 1 < sample.endIndex {
            let first = sample[index]
            let second = sample[index + 1]
            if first == 0 && (0x09...0x7E).contains(second) { big += 1 }
            if second == 0 && (0x09...0x7E).contains(first) { little += 1 }
            index += 2
        }
        if little >= 2 && little > big * 2 { return .utf16LE }
        if big >= 2 && big > little * 2 { return .utf16BE }
        return nil
    }

    private static func hasISO2022Shift(in data: Data) -> Bool {
        guard let escape = data.range(of: Data([0x1B]))?.lowerBound else { return false }
        let bytes = data[escape...]
        return [[0x1B, 0x24, 0x40], [0x1B, 0x24, 0x42], [0x1B, 0x28, 0x4A],
                [0x1B, 0x28, 0x49]].contains { bytes.range(of: Data($0)) != nil }
    }

    static func read(_ data: Data, as encoding: MarkdownTextEncoding) throws -> Decoded {
        let mark = encoding.byteOrderMark
        let hasBOM = !mark.isEmpty && data.starts(with: mark)
        let payload = hasBOM ? data.dropFirst(mark.count) : data
        return (try decode(payload, as: encoding), encoding, hasBOM)
    }

    static func decode(_ data: Data, as encoding: MarkdownTextEncoding) throws -> String {
        if encoding == .utf8 {
            guard let text = MarkdownTextFormat.decodeUTF8Payload(data) else { throw MarkdownEncodingError.cannotDecode }
            return text
        }
        // Foundation silently drops an odd final byte when decoding explicitly ordered UTF-16.
        if (encoding == .utf16LE || encoding == .utf16BE) && !data.count.isMultiple(of: 2) {
            throw MarkdownEncodingError.cannotDecode
        }
        if encoding == .iso2022JP && !validISO2022Bytes(data) {
            throw MarkdownEncodingError.cannotDecode
        }
        // Compare text rather than bytes: Shift JIS has several byte sequences for one character
        // (IBM and NEC-selected IBM extensions), and they encode back to only one of them.
        guard let text = String(data: data, encoding: encoding.foundationEncoding),
              let roundTrip = text.data(using: encoding.foundationEncoding, allowLossyConversion: false),
              let decoded = String(data: roundTrip, encoding: encoding.foundationEncoding),
              decoded.utf8.elementsEqual(text.utf8) else {
            throw MarkdownEncodingError.cannotDecode
        }
        if (encoding == .utf16LE || encoding == .utf16BE) && roundTrip != data {
            throw MarkdownEncodingError.cannotDecode
        }
        return text
    }

    // Foundation accepts individual eight-bit bytes and can return an unfinished escape
    // as literal text. Neither is a complete ISO-2022-JP stream.
    private static func validISO2022Bytes(_ data: Data) -> Bool {
        var index = data.startIndex
        while index < data.endIndex {
            let byte = data[index]
            index += 1
            guard byte < 0x80 else { return false }
            if byte == 0x1B {
                guard index + 1 < data.endIndex else { return false }
                switch (data[index], data[index + 1]) {
                case (0x24, 0x40), (0x24, 0x42), (0x28, 0x42), (0x28, 0x49), (0x28, 0x4A): break
                default: return false
                }
                index += 2
            }
        }
        return true
    }

    static func encode(_ text: String, as encoding: MarkdownTextEncoding, hasBOM: Bool = false) throws -> Data {
        let payload: Data
        if encoding == .utf8 {
            payload = Data(text.utf8)
        } else {
            guard let data = text.data(using: encoding.foundationEncoding, allowLossyConversion: false),
                  encoding != .iso2022JP || validISO2022Bytes(data),
                  let decoded = String(data: data, encoding: encoding.foundationEncoding),
                  decoded.utf8.elementsEqual(text.utf8) else {
                throw MarkdownEncodingError.cannotEncode
            }
            payload = data
        }
        return hasBOM ? Data(encoding.byteOrderMark) + payload : payload
    }

    static func unrepresentableRanges(in text: String, as encoding: MarkdownTextEncoding) -> [NSRange] {
        unrepresentableRanges(in: text, as: encoding, checkCancellation: {})
    }

    static func unrepresentableRanges(in text: String, as encoding: MarkdownTextEncoding,
                                      checkCancellation: () throws -> Void) rethrows -> [NSRange] {
        try checkCancellation()
        guard encoding != .utf8 && encoding != .utf16BE && encoding != .utf16LE,
              (try? encode(text, as: encoding)) == nil else { return [] }
        var ranges: [NSRange] = []
        var offset = 0
        for character in text {
            try checkCancellation()
            let value = String(character)
            let length = value.utf16.count
            if (try? encode(value, as: encoding)) == nil {
                ranges.append(NSRange(location: offset, length: length))
            }
            offset += length
        }
        return ranges
    }

    static func convert(_ data: Data, from source: MarkdownTextEncoding,
                        to destination: MarkdownTextEncoding) throws -> Data {
        let decoded = try read(data, as: source)
        if source == destination && decoded.hasBOM { return data }
        if destination == .utf16LE || destination == .utf16BE {
            return source == destination ? data : try encode(decoded.text, as: destination, hasBOM: true)
        }

        // Use the original bytes when possible, even when fixing a stale declaration.
        // Re-encoding the entire file could change duplicate CP932 representations.
        var payload = source == destination ? data : try encode(decoded.text, as: destination)
        let declaration = encodingDeclaration(in: payload)
        if destination == .utf8 {
            // Preserve the text, including an old declaration or a literal leading U+FEFF.
            let staleDeclaration = declaration.map { $0.encoding != destination } ?? false
            if staleDeclaration || payload.starts(with: destination.byteOrderMark) {
                return Data(destination.byteOrderMark) + payload
            }
        } else if let declaration, declaration.encoding != destination {
            // Legacy encodings have no BOM to override the old label when the file is reopened.
            payload.replaceSubrange(declaration.byteRange, with: destination.declarationName.utf8)
        }
        return payload
    }
}
