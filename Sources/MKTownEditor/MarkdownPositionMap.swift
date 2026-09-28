import Foundation

/// A one-based source location. Columns count UTF-8 bytes, as Markdown parsers commonly do.
struct MarkdownSourcePosition: Hashable, Sendable {
    let line: Int
    let utf8Column: Int
}

/// Converts parser locations to NSTextView's UTF-16 offsets without splitting a Unicode scalar.
struct MarkdownPositionMap: Sendable {
    private let offsetsByPosition: [MarkdownSourcePosition: Int]
    private let positionsByUTF16Offset: [Int: MarkdownSourcePosition]

    init(_ text: String) {
        let scalars = Array(text.unicodeScalars)
        var offsets: [MarkdownSourcePosition: Int] = [:]
        var positions: [Int: MarkdownSourcePosition] = [:]
        var line = 1
        var column = 1
        var utf16Offset = 0

        for index in scalars.indices {
            let position = MarkdownSourcePosition(line: line, utf8Column: column)
            offsets[position] = utf16Offset
            positions[utf16Offset] = position

            let scalar = scalars[index]
            utf16Offset += scalar.value > 0xFFFF ? 2 : 1
            if scalar.value == 10 || (scalar.value == 13 &&
                (index + 1 == scalars.count || scalars[index + 1].value != 10)) {
                line += 1
                column = 1
            } else {
                column += String(scalar).utf8.count
            }
        }

        let endPosition = MarkdownSourcePosition(line: line, utf8Column: column)
        offsets[endPosition] = utf16Offset
        positions[utf16Offset] = endPosition
        offsetsByPosition = offsets
        positionsByUTF16Offset = positions
    }

    func utf16Offset(for position: MarkdownSourcePosition) -> Int? {
        offsetsByPosition[position]
    }

    func position(forUTF16Offset offset: Int) -> MarkdownSourcePosition? {
        positionsByUTF16Offset[offset]
    }

    func utf16Range(from start: MarkdownSourcePosition, to end: MarkdownSourcePosition) -> NSRange? {
        guard let lower = utf16Offset(for: start), let upper = utf16Offset(for: end), lower <= upper else {
            return nil
        }
        return NSRange(location: lower, length: upper - lower)
    }

    func positions(for range: NSRange) -> (start: MarkdownSourcePosition, end: MarkdownSourcePosition)? {
        let (upper, overflow) = range.location.addingReportingOverflow(range.length)
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              !overflow,
              let start = position(forUTF16Offset: range.location),
              let end = position(forUTF16Offset: upper) else {
            return nil
        }
        return (start, end)
    }
}
