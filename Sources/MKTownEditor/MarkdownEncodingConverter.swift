import Foundation

enum MarkdownTextEncoding: String, CaseIterable, Identifiable {
    case utf8
    case shiftJIS
    case eucJP
    case latin1
    case utf16LE
    case utf16BE

    var id: Self { self }

    var title: String {
        switch self {
        case .utf8: "UTF-8"
        case .shiftJIS: "Shift JIS"
        case .eucJP: "EUC-JP"
        case .latin1: "ISO-8859-1"
        case .utf16LE: "UTF-16 LE"
        case .utf16BE: "UTF-16 BE"
        }
    }

    var foundationEncoding: String.Encoding {
        switch self {
        case .utf8: .utf8
        case .shiftJIS: .shiftJIS
        case .eucJP: .japaneseEUC
        case .latin1: .isoLatin1
        case .utf16LE: .utf16LittleEndian
        case .utf16BE: .utf16BigEndian
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
    static func decode(_ data: Data, as encoding: MarkdownTextEncoding) throws -> String {
        guard let text = String(data: data, encoding: encoding.foundationEncoding),
              let roundTrip = text.data(using: encoding.foundationEncoding,
                                        allowLossyConversion: false),
              roundTrip == data else {
            throw MarkdownEncodingError.cannotDecode
        }
        return text
    }

    static func encode(_ text: String, as encoding: MarkdownTextEncoding) throws -> Data {
        guard let data = text.data(using: encoding.foundationEncoding,
                                   allowLossyConversion: false),
              String(data: data, encoding: encoding.foundationEncoding) == text else {
            throw MarkdownEncodingError.cannotEncode
        }
        return data
    }

    static func convert(_ data: Data, from source: MarkdownTextEncoding,
                        to destination: MarkdownTextEncoding) throws -> Data {
        try encode(decode(data, as: source), as: destination)
    }
}
