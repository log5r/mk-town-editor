import Foundation

public struct MarkdownFrontMatter: Equatable, Sendable {
    public let raw: String
    public let content: String
    public let sourceRange: NSRange

    public init?(source: String) {
        // 先頭行が区切り線でなければ、行の索引を作らずに終える。
        guard source.hasPrefix("---") else { return nil }
        let text = source as NSString
        // 行頭を順に求め、閉じ区切りが見つかった時点で走査を止める。本文の長さに依存しない。
        func nextLineStart(after start: Int) -> Int? {
            var offset = start
            while offset < text.length {
                let unit = text.character(at: offset)
                if unit == 13, offset + 1 < text.length, text.character(at: offset + 1) == 10 { return offset + 2 }
                if unit == 10 || unit == 13 { return offset + 1 }
                offset += 1
            }
            return nil
        }
        func line(from start: Int, to end: Int) -> String {
            text.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .newlines)
        }
        guard let firstContent = nextLineStart(after: 0),
              line(from: 0, to: firstContent) == "---" else { return nil }
        var start = firstContent
        var closing: (start: Int, end: Int)?
        while closing == nil {
            let next = nextLineStart(after: start)
            let end = next ?? text.length
            let value = line(from: start, to: end)
            if value == "---" || value == "..." { closing = (start, end); break }
            guard let next else { break }
            start = next
        }
        guard let closing else { return nil }
        sourceRange = NSRange(location: 0, length: closing.end)
        raw = text.substring(with: sourceRange)
        content = text.substring(with: NSRange(location: firstContent,
            length: closing.start - firstContent))
    }
}

/// A conservative presentation of common Obsidian properties, not a general YAML decoder.
/// Unsupported values retain their YAML; unsupported document structures use the raw view.
public enum FrontMatterPreviewProperties {
    public struct Row: Equatable, Sendable {
        public let key: String
        public let values: [String]
        public let isVerbatim: Bool
    }

    private static let entry = try! NSRegularExpression(
        pattern: #"^([\p{L}\p{N}_][\p{L}\p{N}_ -]*):(?:[ \t]+(.*)|$)"#)

    public static func rows(in frontMatter: MarkdownFrontMatter) -> [Row]? {
        var entries: [(key: String, lines: [String])] = []
        let content = frontMatter.content.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                if !entries.isEmpty { entries[entries.count - 1].lines.append(line) }
                continue
            }
            let text = line as NSString
            if let match = entry.firstMatch(in: line, range: NSRange(location: 0, length: text.length)) {
                let valueRange = match.range(at: 2)
                entries.append((text.substring(with: match.range(at: 1)),
                    [valueRange.location == NSNotFound ? "" : text.substring(with: valueRange)]))
            } else if !entries.isEmpty && (line.first?.isWhitespace == true || trimmed.hasPrefix("- ")) {
                entries[entries.count - 1].lines.append(line)
            } else {
                return nil
            }
        }
        return entries.map { item in
            let first = item.lines[0]
            let continuation = item.lines.dropFirst().filter {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !trimmed.hasPrefix("#")
            }
            if continuation.isEmpty {
                if let values = inlineList(first) {
                    return Row(key: item.key, values: values, isVerbatim: false)
                }
                if let value = scalar(first) {
                    return Row(key: item.key, values: [value], isVerbatim: false)
                }
            } else if scalar(first) == "" {
                var values: [String] = []
                var indentation: Int?
                for line in continuation {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    let width = line.prefix(while: { $0 == " " }).count
                    guard (indentation == nil || indentation == width), trimmed.hasPrefix("- "),
                          let value = scalar(String(trimmed.dropFirst(2))), !value.isEmpty else {
                        return Row(key: item.key, values: [item.lines.joined(separator: "\n")], isVerbatim: true)
                    }
                    indentation = width
                    values.append(value)
                }
                return Row(key: item.key, values: values, isVerbatim: false)
            }
            return Row(key: item.key, values: [item.lines.joined(separator: "\n")], isVerbatim: true)
        }
    }

    private static func scalar(_ source: String) -> String? {
        let value = source.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") {
            // JSON's quoted strings are a safe subset of YAML's double-quoted strings.
            // YAML-specific escapes remain verbatim rather than being misinterpreted.
            var escaped = false
            for index in value.indices.dropFirst() {
                let character = value[index]
                if !escaped && character == "\"" {
                    let suffix = value[value.index(after: index)...].trimmingCharacters(in: .whitespaces)
                    guard suffix.isEmpty || suffix.hasPrefix("#"),
                          let data = String(value[...index]).data(using: .utf8) else { return nil }
                    return (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? String
                }
                if character == "\\" { escaped.toggle() } else { escaped = false }
            }
            return nil
        }
        if value.hasPrefix("'") {
            var cursor = value.index(after: value.startIndex)
            var result = ""
            while cursor < value.endIndex {
                let next = value.index(after: cursor)
                if value[cursor] == "'" {
                    if next < value.endIndex && value[next] == "'" {
                        result.append("'")
                        cursor = value.index(after: next)
                        continue
                    }
                    let suffix = value[next...].trimmingCharacters(in: .whitespaces)
                    return suffix.isEmpty || suffix.hasPrefix("#") ? result : nil
                }
                result.append(value[cursor])
                cursor = next
            }
            return nil
        }
        let uncommented: String
        if let comment = value.range(of: #"(^|\s)#"#, options: .regularExpression) {
            uncommented = String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
        } else { uncommented = value }
        guard !uncommented.contains(": "), !uncommented.contains(":\t"),
              uncommented != "-", !uncommented.hasPrefix("- "),
              uncommented.first.map({ !"[]{}&*!|>@`%,?:".contains($0) }) ?? true else { return nil }
        return uncommented
    }

    private static func inlineList(_ source: String) -> [String]? {
        let value = source.trimmingCharacters(in: .whitespaces)
        guard value.first == "[" else { return nil }
        var result: [String] = []
        var part = ""
        var quote: Character?
        var escaped = false
        for index in value.indices.dropFirst() {
            let character = value[index]
            if let current = quote {
                part.append(character)
                if !escaped && character == current { quote = nil }
                if current == "\"" && character == "\\" { escaped.toggle() } else { escaped = false }
            } else if (character == "\"" || character == "'") && part.trimmingCharacters(in: .whitespaces).isEmpty {
                quote = character
                part.append(character)
            } else if character == "," || character == "]" {
                if !part.trimmingCharacters(in: .whitespaces).isEmpty {
                    guard let item = scalar(part), !item.isEmpty else { return nil }
                    result.append(item)
                } else if character == "," { return nil }
                part = ""
                if character == "]" {
                    let suffix = value[value.index(after: index)...].trimmingCharacters(in: .whitespaces)
                    return suffix.isEmpty || suffix.hasPrefix("#") ? result : nil
                }
            } else if character == "[" || character == "{" || character == "}" ||
                        (character == "#" && (part.isEmpty || part.last?.isWhitespace == true)) {
                return nil
            } else { part.append(character) }
        }
        return nil
    }
}
