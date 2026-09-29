import Foundation

struct BibTeXEntry: Equatable, Sendable {
    let key: String
    let fields: [String: String]

    var bibliographyText: String {
        let author = fields["author"] ?? fields["organization"] ?? key
        let year = fields["year"].map { " (\($0))" } ?? ""
        let title = fields["title"].map { ". \($0)" } ?? ""
        let venue = (fields["journal"] ?? fields["booktitle"] ?? fields["publisher"])
            .map { ". \($0)" } ?? ""
        let doi = fields["doi"].map { ". doi:\($0)" } ?? ""
        return author + year + title + venue + doi + "."
    }
}

enum BibTeXParser {
    static func parse(_ source: String) -> [BibTeXEntry] {
        let chars = Array(source)
        var index = 0
        var entries: [BibTeXEntry] = []
        while index < chars.count {
            guard chars[index] == "@" else { index += 1; continue }
            index += 1
            let typeStart = index
            while index < chars.count, chars[index].isLetter { index += 1 }
            let entryType = String(chars[typeStart..<index]).lowercased()
            skipSpace(chars, &index)
            guard index < chars.count, chars[index] == "{" || chars[index] == "(" else { continue }
            let opening = chars[index]
            let closing: Character = chars[index] == "{" ? "}" : ")"
            index += 1
            if ["comment", "string", "preamble"].contains(entryType) {
                var depth = 1
                while index < chars.count, depth > 0 {
                    if chars[index] == opening, !escaped(chars, index) { depth += 1 }
                    if chars[index] == closing, !escaped(chars, index) { depth -= 1 }
                    index += 1
                }
                continue
            }
            let keyStart = index
            while index < chars.count, chars[index] != ",", chars[index] != closing { index += 1 }
            guard index < chars.count, chars[index] == "," else { continue }
            let key = String(chars[keyStart..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            index += 1
            var fields: [String: String] = [:]
            while index < chars.count {
                skipSpaceAndCommas(chars, &index)
                if index >= chars.count { break }
                if chars[index] == closing { index += 1; break }
                let nameStart = index
                while index < chars.count, chars[index].isLetter || chars[index] == "_" { index += 1 }
                guard index > nameStart else { index += 1; continue }
                let name = String(chars[nameStart..<index]).lowercased()
                skipSpace(chars, &index)
                guard index < chars.count, chars[index] == "=" else { continue }
                index += 1
                skipSpace(chars, &index)
                guard index < chars.count else { break }
                let value: String
                if chars[index] == "{" {
                    value = braced(chars, &index)
                } else if chars[index] == "\"" {
                    value = quoted(chars, &index)
                } else {
                    let start = index
                    while index < chars.count, chars[index] != ",", chars[index] != closing { index += 1 }
                    value = String(chars[start..<index])
                }
                fields[name] = clean(value)
            }
            if !key.isEmpty, !entries.contains(where: { $0.key == key }) {
                entries.append(BibTeXEntry(key: key, fields: fields))
            }
        }
        return entries
    }

    private static func braced(_ chars: [Character], _ index: inout Int) -> String {
        index += 1
        let start = index
        var depth = 1
        while index < chars.count {
            if chars[index] == "{", !escaped(chars, index) { depth += 1 }
            if chars[index] == "}", !escaped(chars, index) {
                depth -= 1
                if depth == 0 { break }
            }
            index += 1
        }
        let result = String(chars[start..<index])
        if index < chars.count { index += 1 }
        return result
    }

    private static func quoted(_ chars: [Character], _ index: inout Int) -> String {
        index += 1
        let start = index
        while index < chars.count {
            if chars[index] == "\"", !escaped(chars, index) { break }
            index += 1
        }
        let result = String(chars[start..<index])
        if index < chars.count { index += 1 }
        return result
    }

    private static func escaped(_ chars: [Character], _ index: Int) -> Bool {
        var cursor = index
        var count = 0
        while cursor > 0, chars[cursor - 1] == "\\" { count += 1; cursor -= 1 }
        return count % 2 == 1
    }

    private static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .replacingOccurrences(of: "\\&", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func skipSpace(_ chars: [Character], _ index: inout Int) {
        while index < chars.count, chars[index].isWhitespace { index += 1 }
    }

    private static func skipSpaceAndCommas(_ chars: [Character], _ index: inout Int) {
        while index < chars.count, chars[index].isWhitespace || chars[index] == "," { index += 1 }
    }
}

struct MarkdownCitationCatalog: Equatable, Sendable {
    let entries: [BibTeXEntry]

    static func fingerprint(documentURL: URL?) -> String? {
        guard let documentURL, documentURL.isFileURL else { return nil }
        let url = documentURL.deletingLastPathComponent().appendingPathComponent("references.bib")
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return nil
        }
        return "\(values.fileSize ?? -1):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }

    static func load(documentURL: URL?) -> MarkdownCitationCatalog? {
        guard let documentURL, documentURL.isFileURL else { return nil }
        let url = documentURL.deletingLastPathComponent().appendingPathComponent("references.bib")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 1_000_000, let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return MarkdownCitationCatalog(entries: BibTeXParser.parse(source))
    }

    func hasCitation(in analysis: MarkdownAnalysis) -> Bool {
        analysis.blocks.contains { block in
            block.kind != .codeBlock && replaceInline(block.content) != block.content
        } || analysis.footnotes.entries.contains { replaceInline($0.content) != $0.content }
    }

    func replaceInline(_ source: String) -> String {
        let chars = Array(source)
        var result = ""
        var index = 0
        var codeTicks = 0
        while index < chars.count {
            if chars[index] == "`" {
                let count = chars[index...].prefix(while: { $0 == "`" }).count
                if codeTicks == 0 { codeTicks = count }
                else if codeTicks == count { codeTicks = 0 }
                result += String(chars[index..<(index + count)])
                index += count
                continue
            }
            if codeTicks == 0, chars[index] == "[", index + 2 < chars.count,
               chars[index + 1] == "@", !escaped(chars, index),
               let end = chars[(index + 2)...].firstIndex(of: "]") {
                let key = String(chars[(index + 2)..<end])
                if key.allSatisfy({ $0.isLetter || $0.isNumber || "_:.+-".contains($0) }),
                   let number = entries.firstIndex(where: { $0.key == key }).map({ $0 + 1 }) {
                    result += "[\(number)]"
                    index = end + 1
                    continue
                }
            }
            result.append(chars[index])
            index += 1
        }
        return result
    }

    func materialize(_ markdown: String) -> String {
        var fence: String?
        var transformed: [String] = []
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if fence == nil { fence = marker }
                else if fence == marker { fence = nil }
                transformed.append(line)
            } else {
                transformed.append(fence == nil ? replaceInline(line) : line)
            }
        }
        let body = transformed.joined(separator: "\n")
        guard body != markdown, !entries.isEmpty else { return body }
        return body.trimmingCharacters(in: .newlines) + "\n\n## 参考文献\n\n" +
            entries.enumerated().map { "\($0.offset + 1). \($0.element.bibliographyText)" }
                .joined(separator: "\n") + "\n"
    }

    private func escaped(_ chars: [Character], _ index: Int) -> Bool {
        index > 0 && chars[index - 1] == "\\"
    }
}
