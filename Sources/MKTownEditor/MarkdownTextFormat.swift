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
        let payload = bom ? data.dropFirst(3) : data[...]
        guard var value = String(data: payload, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let scan = NewlineScan(payload)
        let newline: Newline
        if scan.crlfCount > 0 && scan.crlfCount >= scan.crCount && scan.crlfCount >= scan.lfCount {
            newline = .crlf
        } else if scan.crCount > 0 && scan.crCount >= scan.lfCount {
            newline = .cr
        } else {
            newline = .lf
        }
        if scan.containsCarriageReturn {
            // 検証済みのUTF-8バイト列からCRを1回の走査で取り除き、ネイティブ文字列を直接作る。
            value = String(decoding: normalizedBytes(payload, capacity: payload.count), as: UTF8.self)
        } else {
            value.makeContiguousUTF8()
        }
        return (value, Self(newline: newline, hasUTF8BOM: bom,
                            originalNewlines: scan.mixedEndings))
    }

    func encode(_ text: String) -> Data {
        var data = Data()
        let utf8 = text.utf8
        data.reserveCapacity(utf8.count + (hasUTF8BOM ? 3 : 0) + (newline == .crlf ? utf8.count / 32 : 0))
        if hasUTF8BOM { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        let endings = originalNewlines.flatMap { $0.count == NewlineScan(utf8).totalCount ? $0 : nil }
        let fixed = Array(newline.sequence.utf8)
        var lineIndex = 0
        var segmentStart = utf8.startIndex
        var index = utf8.startIndex
        // 行の配列や置換後の中間文字列を作らず、改行位置ごとに区切りながら追記する。
        while index != utf8.endIndex {
            let byte = utf8[index]
            guard byte == 0x0A || byte == 0x0D else {
                utf8.formIndex(after: &index)
                continue
            }
            data.append(contentsOf: utf8[segmentStart..<index])
            utf8.formIndex(after: &index)
            if byte == 0x0D, index != utf8.endIndex, utf8[index] == 0x0A {
                utf8.formIndex(after: &index)
            }
            if let endings {
                data.append(contentsOf: endings[lineIndex].sequence.utf8)
            } else {
                data.append(contentsOf: fixed)
            }
            lineIndex += 1
            segmentStart = index
        }
        data.append(contentsOf: utf8[segmentStart..<utf8.endIndex])
        return data
    }

    /// UTF-8バイト列を1回走査して、改行の種類ごとの件数と混在時の並びを求める。
    private struct NewlineScan {
        var crlfCount = 0
        var crCount = 0
        var lfCount = 0
        private var firstKind: Newline?
        private(set) var mixedEndings: [Newline]?

        var totalCount: Int { crlfCount + crCount + lfCount }
        var containsCarriageReturn: Bool { crlfCount + crCount > 0 }

        init<Bytes: Collection>(_ bytes: Bytes) where Bytes.Element == UInt8 {
            var index = bytes.startIndex
            while index != bytes.endIndex {
                let byte = bytes[index]
                bytes.formIndex(after: &index)
                let kind: Newline
                if byte == 0x0D {
                    if index != bytes.endIndex, bytes[index] == 0x0A {
                        bytes.formIndex(after: &index)
                        kind = .crlf
                    } else {
                        kind = .cr
                    }
                } else if byte == 0x0A {
                    kind = .lf
                } else {
                    continue
                }
                record(kind)
            }
        }

        private mutating func record(_ kind: Newline) {
            let previousTotal = totalCount
            switch kind {
            case .crlf: crlfCount += 1
            case .cr: crCount += 1
            case .lf: lfCount += 1
            }
            if mixedEndings != nil {
                mixedEndings?.append(kind)
            } else if let firstKind {
                if firstKind != kind {
                    // 2種類目が現れた時だけ並びを記録する。単一種類の文書では配列を作らない。
                    var endings = Array(repeating: firstKind, count: previousTotal)
                    endings.append(kind)
                    mixedEndings = endings
                }
            } else {
                firstKind = kind
            }
        }
    }

    private static func normalizedBytes(_ bytes: Data.SubSequence, capacity: Int) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(capacity)
        var index = bytes.startIndex
        while index != bytes.endIndex {
            let byte = bytes[index]
            bytes.formIndex(after: &index)
            if byte == 0x0D {
                if index != bytes.endIndex, bytes[index] == 0x0A {
                    bytes.formIndex(after: &index)
                }
                result.append(0x0A)
            } else {
                result.append(byte)
            }
        }
        return result
    }
}
