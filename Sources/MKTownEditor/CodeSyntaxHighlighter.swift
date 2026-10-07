import AppKit

@MainActor
enum CodeSyntaxHighlighter {
    enum Token: Equatable {
        case keyword, string, comment, number
    }

    private struct Language {
        let keywords: Set<String>
        let lineComment: String
        let blockComments: Bool
        let singleQuotedStrings: Bool
    }

    private static let languages: [String: Language] = [
        "swift": Language(keywords: Set("let var func struct class enum protocol extension if else guard switch case return throw try await async import true false nil self".split(separator: " ").map(String.init)),
                          lineComment: "//", blockComments: true, singleQuotedStrings: false),
        "javascript": Language(keywords: Set("const let var function class if else return throw async await import export true false null undefined new".split(separator: " ").map(String.init)),
                               lineComment: "//", blockComments: true, singleQuotedStrings: true),
        "typescript": Language(keywords: Set("const let var function class interface type if else return throw async await import export true false null undefined new".split(separator: " ").map(String.init)),
                               lineComment: "//", blockComments: true, singleQuotedStrings: true),
        "python": Language(keywords: Set("def class if elif else return raise async await import from for while in and or not True False None".split(separator: " ").map(String.init)),
                           lineComment: "#", blockComments: false, singleQuotedStrings: true),
        "json": Language(keywords: ["true", "false", "null"], lineComment: "", blockComments: false,
                         singleQuotedStrings: false),
        "shell": Language(keywords: Set("if then else fi for in do done case esac function export local".split(separator: " ").map(String.init)),
                          lineComment: "#", blockComments: false, singleQuotedStrings: true)
    ]

    static func tokenRanges(in source: String, language name: String?) -> [(NSRange, Token)] {
        guard let language = language(named: name) else { return [] }
        let pattern = tokenPattern(for: language)
        guard let regex = RegularExpressionCache.shared.expression(pattern) else { return [] }
        let text = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0, length: text.length)).compactMap { match in
            let value = text.substring(with: match.range)
            if value.hasPrefix(language.lineComment), !language.lineComment.isEmpty {
                return (match.range, .comment)
            }
            if language.blockComments && value.hasPrefix("/*") { return (match.range, .comment) }
            if value.hasPrefix("\"") || (language.singleQuotedStrings && value.hasPrefix("'")) {
                return (match.range, .string)
            }
            if language.keywords.contains(value) { return (match.range, .keyword) }
            if value.first?.isNumber == true { return (match.range, .number) }
            return nil
        }
    }

    static func render(_ source: String, language: String?) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 8
        let result = NSMutableAttributedString(string: source, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.textColor,
            .backgroundColor: NSColor.controlBackgroundColor,
            .paragraphStyle: paragraph
        ])
        for (range, token) in tokenRanges(in: source, language: language) {
            let color: NSColor
            switch token {
            case .keyword: color = .systemBlue
            case .string: color = .systemGreen
            case .comment: color = .secondaryLabelColor
            case .number: color = .systemPurple
            }
            result.addAttribute(.foregroundColor, value: color, range: range)
        }
        return result
    }

    private static func language(named name: String?) -> Language? {
        guard let name = name?.lowercased() else { return nil }
        let canonical: String
        switch name {
        case "js", "jsx": canonical = "javascript"
        case "ts", "tsx": canonical = "typescript"
        case "py": canonical = "python"
        case "jsonc": canonical = "json"
        case "sh", "bash", "zsh": canonical = "shell"
        default: canonical = name
        }
        return languages[canonical]
    }

    private static func tokenPattern(for language: Language) -> String {
        var parts = [#"\"(?:\\.|[^\"\\])*\""#]
        if language.singleQuotedStrings { parts.append(#"'(?:\\.|[^'\\])*'"#) }
        if language.blockComments { parts.append(#"/\*[\s\S]*?\*/"#) }
        if !language.lineComment.isEmpty {
            parts.append(NSRegularExpression.escapedPattern(for: language.lineComment) + #"[^\n]*"#)
        }
        parts.append(#"\b[A-Za-z_][A-Za-z_0-9]*\b"#)
        parts.append(#"\b\d+(?:\.\d+)?\b"#)
        return parts.joined(separator: "|")
    }
}
