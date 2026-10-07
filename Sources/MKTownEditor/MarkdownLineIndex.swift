import Foundation

struct MarkdownLineDestination: Equatable {
    let requestedLine: Int
    let resolvedLine: Int
    let utf16Location: Int

    var wasClamped: Bool { requestedLine != resolvedLine }
}

struct MarkdownLineIndex {
    let starts: [Int]

    /// `limit` を指定すると、その位置以降で最初の行頭を記録した時点で走査を止める。
    /// フロントマターのように先頭付近だけを扱う処理で、文書全体を走査しないために使う。
    init(_ text: String, through limit: Int = .max) {
        let source = text as NSString
        var result = [0]
        var offset = 0
        while offset < source.length, result[result.count - 1] < limit {
            let unit = source.character(at: offset)
            if unit == 13, offset + 1 < source.length, source.character(at: offset + 1) == 10 {
                offset += 2
                result.append(offset)
            } else if unit == 10 || unit == 13 {
                offset += 1
                result.append(offset)
            } else {
                offset += 1
            }
        }
        starts = result
    }

    var lineCount: Int { starts.count }

    func destination(for requestedLine: Int) -> MarkdownLineDestination {
        let resolved = min(max(1, requestedLine), lineCount)
        return MarkdownLineDestination(requestedLine: requestedLine, resolvedLine: resolved,
                                       utf16Location: starts[resolved - 1])
    }

    func line(containingUTF16Offset location: Int) -> Int {
        let position = max(0, location)
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= position { low = middle + 1 } else { high = middle }
        }
        return max(1, low)
    }
}
