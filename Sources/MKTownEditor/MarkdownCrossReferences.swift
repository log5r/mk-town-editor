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
    let targets: [MarkdownCrossReferenceTarget]
    let markerBlockIDs: Set<Int>

    init(blocks: [MarkdownBlock]) {
        var found: [MarkdownCrossReferenceTarget] = []
        var markers: Set<Int> = []
        var counts: [MarkdownCrossReferenceKind: Int] = [:]
        for (index, block) in blocks.enumerated() {
            guard block.kind == .paragraph,
                  let (kind, identifier) = Self.marker(block.content),
                  index > 0,
                  !found.contains(where: { $0.key == "\(kind.rawValue):\(identifier)" }) else { continue }
            guard let target = blocks[..<index].reversed().first(where: {
                $0.kind != .blank && !markers.contains($0.id)
            }), Self.matches(target, kind: kind) else { continue }
            let number = (counts[kind] ?? 0) + 1
            counts[kind] = number
            found.append(MarkdownCrossReferenceTarget(key: "\(kind.rawValue):\(identifier)",
                                                      kind: kind, number: number,
                                                      blockID: target.id))
            markers.insert(block.id)
        }
        targets = found
        markerBlockIDs = markers
    }

    func target(forBlockID id: Int) -> MarkdownCrossReferenceTarget? {
        targets.first(where: { $0.blockID == id })
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
        let chars = Array(source)
        var result = ""
        var index = 0
        var ticks = 0
        while index < chars.count {
            if chars[index] == "`" {
                let count = chars[index...].prefix(while: { $0 == "`" }).count
                if ticks == 0 { ticks = count }
                else if ticks == count { ticks = 0 }
                result += String(chars[index..<(index + count)])
                index += count
                continue
            }
            if ticks == 0, chars[index] == "@", index + 5 < chars.count,
               (index == 0 || chars[index - 1] != "\\") {
                let rest = String(chars[index...])
                if let match = Self.referencePattern.firstMatch(in: rest,
                    range: NSRange(location: 0, length: (rest as NSString).length)), match.range.location == 0 {
                    let key = (rest as NSString).substring(with: match.range(at: 1)) + ":" +
                        (rest as NSString).substring(with: match.range(at: 2))
                    if let target = targets.first(where: { $0.key == key }) {
                        result += replacement(target)
                        index += Array((rest as NSString).substring(with: match.range)).count
                        continue
                    }
                }
            }
            result.append(chars[index])
            index += 1
        }
        return result
    }

    private static var referencePattern: NSRegularExpression {
        try! NSRegularExpression(pattern: #"^@(fig|tbl|eq):([A-Za-z][A-Za-z0-9_-]*)(?![A-Za-z0-9_:-]|\.[A-Za-z0-9_-])"#)
    }

    static func marker(_ content: String) -> (MarkdownCrossReferenceKind, String)? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = try! NSRegularExpression(pattern: #"^\{#(fig|tbl|eq):([A-Za-z][A-Za-z0-9_-]*)\}$"#)
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
