import Foundation

/// Preserves code points when comparing text for source ranges, observation, or rendering.
struct MarkdownSourceText: Hashable {
    let text: String

    init(_ text: String) { self.text = text }

    static func == (lhs: Self, rhs: Self) -> Bool {
        MarkdownTextFormat.identicalText(lhs.text, rhs.text)
    }

    func hash(into hasher: inout Hasher) {
        var source = text
        source.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    }
}

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

    var hasMixedNewlines: Bool { originalNewlines != nil }

    func matchesNewlineCount(in text: String) -> Bool {
        guard let originalNewlines else { return true }
        return originalNewlines.count == NewlineScan(text.utf8).totalCount
    }

    mutating func normalizeNewlines() {
        originalNewlines = nil
    }

    struct NewlineWarning: Equatable, Sendable {
        let line: Int
        let range: NSRange
        let newline: Newline
    }

    /// The editor has one LF code unit per physical line ending, including CRLF.
    func newlineWarnings(in text: String) -> [NewlineWarning] {
        guard let originalNewlines else { return [] }
        var result: [NewlineWarning] = []
        var index = 0
        var previousOffset = -2
        for (offset, unit) in text.utf16.enumerated() where unit == 10 {
            guard index < originalNewlines.count else { break }
            let kind = Self.serializedNewline(at: index, in: originalNewlines,
                                              adjacentToPrevious: offset == previousOffset + 1)
            previousOffset = offset
            index += 1
            if kind != newline {
                result.append(NewlineWarning(line: index, range: NSRange(location: offset, length: 1),
                                             newline: kind))
            }
        }
        return result
    }

    /// Inspect the stored line ending at each selected LF without changing editor offsets.
    func textForUnicodeInspection(in source: String, selection: NSRange) -> String {
        let selectedText = (source as NSString).substring(with: selection)
        guard selectedText.utf8.contains(10) else { return selectedText }
        let overrides = Dictionary(uniqueKeysWithValues: newlineWarnings(in: source).map {
            ($0.range.location, $0.newline)
        })
        var result = String.UnicodeScalarView()
        var location = selection.location
        for scalar in selectedText.unicodeScalars {
            if scalar == "\n" {
                result.append(contentsOf: (overrides[location] ?? newline).sequence.unicodeScalars)
            } else {
                result.append(scalar)
            }
            location += scalar.value <= 0xFFFF ? 1 : 2
        }
        return String(result)
    }

    private static func serializedNewline(at index: Int, in endings: [Newline], adjacentToPrevious: Bool) -> Newline {
        // Deleting all text between a CR and LF would serialize two breaks as one CRLF.
        // Use CR + CRLF here so the blank line survives the next open.
        if adjacentToPrevious && index > 0 && endings[index - 1] == .cr && endings[index] == .lf {
            return .crlf
        }
        return endings[index]
    }

    /// Canonically equivalent text can have different UTF-16 offsets and encoded bytes.
    static func identicalText(_ lhs: String, _ rhs: String) -> Bool {
        var left = lhs, right = rhs
        return left.withUTF8 { a in right.withUTF8 { b in
            a.count == b.count && (a.baseAddress == b.baseAddress || a.elementsEqual(b))
        } }
    }

    static func normalizedText(_ text: String) -> String {
        guard text.utf8.contains(13) else { return text }
        return String(decoding: normalizedBytes(text.utf8), as: UTF8.self)
    }

    /// A binding or a batch command may publish a complete buffer with no edit range.
    /// Keep the line endings on both sides of the changed text. When editing several
    /// lines in place, retain their endings by position as well.
    mutating func updateNewlines(from oldText: String, to newText: String) {
        guard let originalNewlines else { return }
        let old = oldText.utf8, new = newText.utf8
        var oldStart = old.startIndex, newStart = new.startIndex
        var prefixLines = 0
        while oldStart < old.endIndex, newStart < new.endIndex, old[oldStart] == new[newStart] {
            if old[oldStart] == 10 { prefixLines += 1 }
            old.formIndex(after: &oldStart)
            new.formIndex(after: &newStart)
        }
        var oldEnd = old.endIndex, newEnd = new.endIndex
        var suffixLines = 0
        while oldEnd > oldStart, newEnd > newStart {
            let oldLast = old.index(before: oldEnd), newLast = new.index(before: newEnd)
            guard old[oldLast] == new[newLast] else { break }
            if old[oldLast] == 10 { suffixLines += 1 }
            oldEnd = oldLast
            newEnd = newLast
        }
        let replaced = prefixLines..<(originalNewlines.count - suffixLines)
        let inserted = NewlineScan(new[newStart..<newEnd]).totalCount
        guard inserted != replaced.count else { return }
        replaceEndings([replaced], with: Array(repeating: newline, count: inserted),
                       totalBefore: originalNewlines.count)
    }

    func endings(for replacement: String, preservingNewlines: Bool) -> [Newline] {
        let scan = NewlineScan(replacement.utf8)
        if preservingNewlines, let mixed = scan.mixedEndings { return mixed }
        let kind = preservingNewlines ? scan.dominant : newline
        return Array(repeating: kind, count: scan.totalCount)
    }

    /// The caller supplies disjoint ranges of newline ordinals in descending order.
    mutating func replaceEndings(_ ranges: [Range<Int>], with endings: [Newline], totalBefore: Int) {
        guard originalNewlines != nil || endings.contains(where: { $0 != newline }) else { return }
        if originalNewlines == nil { originalNewlines = Array(repeating: newline, count: totalBefore) }
        for range in ranges {
            originalNewlines?.replaceSubrange(range, with: endings)
        }
        if originalNewlines?.contains(where: { $0 != newline }) == false { originalNewlines = nil }
    }

    static func read(_ data: Data) throws -> (text: String, format: Self) {
        let bom = data.starts(with: [0xEF, 0xBB, 0xBF])
        let payload = bom ? data.dropFirst(3) : data[...]
        guard let value = decodeUTF8Payload(payload) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return read(text: value, hasUTF8BOM: bom)
    }

    static func decodeUTF8Payload(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // The caller has already consumed the file signature. Preserve a second U+FEFF,
        // which Foundation would otherwise also remove when decoding the payload.
        return data.starts(with: [0xEF, 0xBB, 0xBF]) ? String(decoding: data, as: UTF8.self) : text
    }

    static func read(text: String, hasUTF8BOM: Bool) -> (text: String, format: Self) {
        var value = text
        value.makeContiguousUTF8()
        let scan = NewlineScan(value.utf8)
        if scan.containsCarriageReturn {
            // 検証済みのUTF-8バイト列からCRを1回の走査で取り除き、ネイティブ文字列を直接作る。
            value = String(decoding: normalizedBytes(value.utf8), as: UTF8.self)
        }
        return (value, Self(newline: scan.dominant, hasUTF8BOM: hasUTF8BOM,
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
            let adjacent = segmentStart == index
            data.append(contentsOf: utf8[segmentStart..<index])
            utf8.formIndex(after: &index)
            if byte == 0x0D, index != utf8.endIndex, utf8[index] == 0x0A {
                utf8.formIndex(after: &index)
            }
            if let endings {
                let kind = Self.serializedNewline(at: lineIndex, in: endings, adjacentToPrevious: adjacent)
                data.append(contentsOf: kind.sequence.utf8)
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
        var dominant: Newline {
            if crlfCount > 0 && crlfCount >= crCount && crlfCount >= lfCount { return .crlf }
            if crCount > 0 && crCount >= lfCount { return .cr }
            return .lf
        }

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

    static func identicalText(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return identicalText(lhs, rhs)
    }

    private static func normalizedBytes(_ bytes: String.UTF8View) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
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
