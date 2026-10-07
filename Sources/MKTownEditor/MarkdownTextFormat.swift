import Foundation

struct MarkdownTextFormat: Equatable {
    enum Newline: String, CaseIterable, Identifiable {
        case lf
        case crlf
        case cr

        var id: Self { self }

        var title: String {
            switch self {
            case .lf: "LF (Unix)"
            case .crlf: "CRLF (Windows)"
            case .cr: String(localized: "CR (旧Mac)")
            }
        }

        var sequence: String {
            switch self {
            case .lf: "\n"
            case .crlf: "\r\n"
            case .cr: "\r"
            }
        }
    }

    var newline: Newline = .lf {
        didSet { originalNewlines = nil }
    }
    var hasUTF8BOM = false
    private var originalNewlines: [Newline]?

    static func read(_ data: Data) throws -> (text: String, format: Self) {
        let bom = data.starts(with: [0xEF, 0xBB, 0xBF])
        let payload = bom ? Data(data.dropFirst(3)) : data
        guard let value = String(data: payload, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let crlfCount = value.components(separatedBy: "\r\n").count - 1
        let withoutCRLF = value.replacingOccurrences(of: "\r\n", with: "")
        let crCount = withoutCRLF.filter { $0 == "\r" }.count
        let lfCount = withoutCRLF.filter { $0 == "\n" }.count
        let newline: Newline
        if crlfCount > 0 && crlfCount >= crCount && crlfCount >= lfCount {
            newline = .crlf
        } else if crCount > 0 && crCount >= lfCount {
            newline = .cr
        } else {
            newline = .lf
        }
        let endings = newlineSequence(in: value)
        let mixed = Set(endings).count > 1 ? endings : nil
        var normalized = normalize(value)
        normalized.makeContiguousUTF8()
        return (normalized, Self(newline: newline, hasUTF8BOM: bom,
                                       originalNewlines: mixed))
    }

    func encode(_ text: String) -> Data {
        let normalized = Self.normalize(text)
        var data = hasUTF8BOM ? Data([0xEF, 0xBB, 0xBF]) : Data()
        let lines = normalized.components(separatedBy: "\n")
        if let originalNewlines, originalNewlines.count == lines.count - 1 {
            for (index, line) in lines.enumerated() {
                if index > 0 { data.append(contentsOf: originalNewlines[index - 1].sequence.utf8) }
                data.append(contentsOf: line.utf8)
            }
        } else {
            data.append(contentsOf: normalized.replacingOccurrences(of: "\n", with: newline.sequence).utf8)
        }
        return data
    }

    private static func newlineSequence(in text: String) -> [Newline] {
        let scalars = Array(text.unicodeScalars)
        var result: [Newline] = []
        var index = 0
        while index < scalars.count {
            if scalars[index] == "\r" {
                if index + 1 < scalars.count, scalars[index + 1] == "\n" {
                    result.append(.crlf)
                    index += 2
                    continue
                }
                result.append(.cr)
            } else if scalars[index] == "\n" {
                result.append(.lf)
            }
            index += 1
        }
        return result
    }

    private static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
