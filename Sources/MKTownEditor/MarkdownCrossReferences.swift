import Foundation

enum MarkdownCrossReferenceKind: String, Sendable {
    case figure = "fig"
    case table = "tbl"
    case equation = "eq"
}

struct MarkdownCrossReferenceTarget: Equatable, Sendable {
    let key: String
    let kind: MarkdownCrossReferenceKind
    let number: Int
    let blockID: Int

    var label: String {
        switch kind {
        case .figure: String(localized: "図\(number)")
        case .table: String(localized: "表\(number)")
        case .equation: String(localized: "式(\(number))")
        }
    }
}

struct MarkdownCrossReferences: Equatable, Sendable {
    private static let referenceExpression = try! NSRegularExpression(
        pattern: #"@(fig|tbl|eq):([A-Za-z][A-Za-z0-9_-]*)(?![A-Za-z0-9_:-]|\.[A-Za-z0-9_-])"#)
    private static let markerExpression = try! NSRegularExpression(
        pattern: #"^\{#(fig|tbl|eq):([A-Za-z][A-Za-z0-9_-]*)\}$"#)

    let targets: [MarkdownCrossReferenceTarget]
    let markerBlockIDs: Set<Int>
    private let targetsByKey: [String: MarkdownCrossReferenceTarget]
    private let targetsByBlockID: [Int: MarkdownCrossReferenceTarget]

    init(blocks: [MarkdownBlock]) {
        var found: [MarkdownCrossReferenceTarget] = []
        var markers: Set<Int> = []
        var counts: [MarkdownCrossReferenceKind: Int] = [:]
        var keys: Set<String> = []
        for (index, block) in blocks.enumerated() {
            guard block.kind == .paragraph,
                  block.content.contains("{#"),
                  let (kind, identifier) = Self.marker(block.content),
                  index > 0,
                  !keys.contains("\(kind.rawValue):\(identifier)") else { continue }
            guard let target = blocks[..<index].reversed().first(where: {
                $0.kind != .blank && !markers.contains($0.id)
            }), Self.matches(target, kind: kind) else { continue }
            let number = (counts[kind] ?? 0) + 1
            counts[kind] = number
            found.append(MarkdownCrossReferenceTarget(key: "\(kind.rawValue):\(identifier)",
                                                      kind: kind, number: number,
                                                      blockID: target.id))
            markers.insert(block.id)
            keys.insert("\(kind.rawValue):\(identifier)")
        }
        targets = found
        markerBlockIDs = markers
        targetsByKey = Dictionary(found.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        targetsByBlockID = Dictionary(found.map { ($0.blockID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func target(forBlockID id: Int) -> MarkdownCrossReferenceTarget? {
        targetsByBlockID[id]
    }

    func replaceInline(_ source: String) -> String {
        transformInline(source) { $0.label }
    }

    func placeholders(in source: String) -> (text: String, targets: [(String, MarkdownCrossReferenceTarget)]) {
        var found: [(String, MarkdownCrossReferenceTarget)] = []
        let text = transformInline(source) { target in
            let token = "MKTOWNCROSSREFERENCE\(found.count)END"
            found.append((token, target))
            return token
        }
        return (text, found)
    }

    private func transformInline(_ source: String,
                                 replacement: (MarkdownCrossReferenceTarget) -> String) -> String {
        guard !targets.isEmpty, source.contains("@") else { return source }
        // 本文をUTF-16のまま走査し、照合はアンカー付きの範囲指定で行う。部分文字列は作らない。
        let text = source as NSString
        let length = text.length
        var result = ""
        var segmentStart = 0
        var index = 0
        var ticks = 0
        while index < length {
            let unit = text.character(at: index)
            if unit == 0x60 {
                var end = index
                while end < length, text.character(at: end) == 0x60 { end += 1 }
                let count = end - index
                if ticks == 0 { ticks = count }
                else if ticks == count { ticks = 0 }
                index = end
                continue
            }
            if ticks == 0, unit == 0x40, index + 5 < length,
               index == 0 || text.character(at: index - 1) != 0x5C,
               let match = Self.referenceExpression.firstMatch(
                in: source, options: .anchored, range: NSRange(location: index, length: length - index)),
               let target = targetsByKey[text.substring(with: match.range(at: 1)) + ":" +
                    text.substring(with: match.range(at: 2))] {
                result += text.substring(with: NSRange(location: segmentStart, length: index - segmentStart))
                result += replacement(target)
                index = NSMaxRange(match.range)
                segmentStart = index
                continue
            }
            index += 1
        }
        guard segmentStart > 0 else { return source }
        result += text.substring(from: segmentStart)
        return result
    }

    static func marker(_ content: String) -> (MarkdownCrossReferenceKind, String)? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = markerExpression
        let source = trimmed as NSString
        guard let match = pattern.firstMatch(in: trimmed, range: NSRange(location: 0, length: source.length)),
              let kind = MarkdownCrossReferenceKind(rawValue: source.substring(with: match.range(at: 1))) else {
            return nil
        }
        return (kind, source.substring(with: match.range(at: 2)))
    }

    private static func matches(_ block: MarkdownBlock, kind: MarkdownCrossReferenceKind) -> Bool {
        switch kind {
        case .figure:
            return block.kind == .paragraph &&
                MarkdownImageLayout.parse(block.content).standaloneCaption != nil
        case .table: return block.kind == .table
        case .equation:
            return block.kind == .paragraph && MarkdownMath.displayFormula(block.content) != nil
        }
    }
}
