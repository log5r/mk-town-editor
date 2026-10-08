import Foundation

/// Converts a small, explicit HTML subset to Markdown for the native preview.
/// No HTML interpreter, web view, script, style, or external resource is used.
enum MarkdownSafeHTML {
    private static let formatting: [String: String] = [
        "b": "**", "strong": "**", "i": "_", "em": "_",
        "s": "~~", "del": "~~", "code": "`"
    ]
    private static let containers: Set<String> = ["p", "div", "span"]
    private static let blocked: Set<String> = ["script", "style", "iframe", "object", "embed", "form"]
    private static let hrefPattern = try! NSRegularExpression(
        pattern: #"(?i)\bhref\s*=\s*(?:"([^"]*)"|'([^']*)')"#)

    static func previewMarkdown(_ source: String) -> String {
        guard source.contains("<") else { return source }
        let characters = Array(source)
        var output = ""
        var index = 0
        var codeRun = 0
        var openTags: [(name: String, suffix: String)] = []

        while index < characters.count {
            if characters[index] == "`", openTags.last?.name != "code" {
                let start = index
                while index < characters.count && characters[index] == "`" { index += 1 }
                let run = index - start
                if codeRun == 0 { codeRun = run }
                else if codeRun == run { codeRun = 0 }
                output += String(repeating: "`", count: run)
                continue
            }
            guard codeRun == 0, characters[index] == "<",
                  index == 0 || characters[index - 1] != "\\" else {
                output.append(characters[index])
                index += 1
                continue
            }
            if openTags.last?.name == "code",
               !has("</code", at: index, in: characters, caseInsensitive: true) {
                output.append("<")
                index += 1
                continue
            }
            if has("<!--", at: index, in: characters) {
                index += 4
                while index < characters.count && !has("-->", at: index, in: characters) { index += 1 }
                if index < characters.count { index += 3 }
                continue
            }
            guard let tag = parseTag(at: index, in: characters) else {
                output.append("<")
                index += 1
                continue
            }
            index = tag.end
            let name = tag.name
            if blocked.contains(name) {
                if !tag.closing {
                    output += String(localized: "未対応HTML要素: \(name)")
                    let closing = "</\(name)>"
                    while index < characters.count && !has(closing, at: index, in: characters,
                                                              caseInsensitive: true) { index += 1 }
                    if index < characters.count { index += closing.count }
                }
                continue
            }
            if name == "br" {
                if !tag.closing { output += "\n" }
                continue
            }
            if tag.closing {
                guard let position = openTags.lastIndex(where: { $0.name == name }) else { continue }
                for opened in openTags[position...].reversed() { output += opened.suffix }
                openTags.removeSubrange(position...)
                continue
            }
            if let marker = formatting[name] {
                output += marker
                if !tag.selfClosing { openTags.append((name, marker)) }
            } else if name == "a", let destination = safeDestination(in: tag.attributes) {
                output += "["
                if !tag.selfClosing { openTags.append((name, "](<\(destination)>)")) }
            } else if containers.contains(name) {
                if name != "span", !output.isEmpty, !output.hasSuffix("\n") { output += "\n" }
                if !tag.selfClosing { openTags.append((name, name == "span" ? "" : "\n")) }
            } else {
                output += String(localized: "未対応HTML要素: \(name)")
            }
        }
        for opened in openTags.reversed() { output += opened.suffix }
        return output
    }

    private static func has(_ value: String, at index: Int, in characters: [Character],
                            caseInsensitive: Bool = false) -> Bool {
        let expected = Array(value)
        guard index + expected.count <= characters.count else { return false }
        for offset in expected.indices {
            let actual = characters[index + offset]
            if caseInsensitive {
                guard actual.lowercased() == expected[offset].lowercased() else { return false }
            } else if actual != expected[offset] { return false }
        }
        return true
    }

    private struct Tag {
        let name: String
        let attributes: String
        let closing: Bool
        let selfClosing: Bool
        let end: Int
    }

    private static func parseTag(at start: Int, in characters: [Character]) -> Tag? {
        var cursor = start + 1
        let closing = cursor < characters.count && characters[cursor] == "/"
        if closing { cursor += 1 }
        let nameStart = cursor
        while cursor < characters.count && characters[cursor].isASCII &&
                (characters[cursor].isLetter || characters[cursor].isNumber || characters[cursor] == "-") {
            cursor += 1
        }
        guard cursor > nameStart, characters[nameStart].isLetter else { return nil }
        guard cursor < characters.count,
              characters[cursor].isWhitespace || characters[cursor] == "/" || characters[cursor] == ">"
        else { return nil }
        let name = String(characters[nameStart..<cursor]).lowercased()
        let attributesStart = cursor
        var quote: Character?
        while cursor < characters.count {
            let character = characters[cursor]
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                let attributes = String(characters[attributesStart..<cursor])
                return Tag(name: name, attributes: attributes, closing: closing,
                           selfClosing: attributes.trimmingCharacters(in: .whitespaces).hasSuffix("/"),
                           end: cursor + 1)
            }
            cursor += 1
        }
        return nil
    }

    private static func safeDestination(in attributes: String) -> String? {
        let range = NSRange(attributes.startIndex..<attributes.endIndex, in: attributes)
        guard let match = hrefPattern.firstMatch(in: attributes, range: range),
              let valueRange = Range(match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1),
                                     in: attributes) else { return nil }
        let value = String(attributes[valueRange])
        // Browsers drop surrounding spaces, tabs, line breaks and control characters before reading
        // a scheme, so " javascript:" or "java\tscript:" must not slip past a failed URL parse.
        // An inner space, as in "my file.md", is kept inside the <…> destination.
        guard !value.isEmpty, !value.contains("<"), !value.contains(">"), !value.contains("\\"),
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: {
                  $0 != " " && (CharacterSet.whitespacesAndNewlines.contains($0) ||
                                CharacterSet.controlCharacters.contains($0))
              }),
              let url = URL(string: value) else { return nil }
        if let scheme = url.scheme?.lowercased() {
            guard ["http", "https", "mailto"].contains(scheme) else { return nil }
        }
        return value
    }
}
