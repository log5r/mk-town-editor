import AppKit

/// コードの字句の色。どの配色もコード背景に対して WCAG AA（4.5:1）以上のコントラストを保つ。
enum CodeSyntaxPalette {
    /// 明るい外観と暗い外観の色（16進数）。HTML 書き出しのスタイルシートと共有する。
    static let light: [CodeSyntaxToken: String] = [
        .keyword: "#9B2393", .type: "#0B4F79", .string: "#C41A16", .comment: "#5D6C79",
        .number: "#1C00CF", .attribute: "#815F03", .variable: "#326D74",
        .inserted: "#116329", .deleted: "#B31D28"
    ]
    static let dark: [CodeSyntaxToken: String] = [
        .keyword: "#FF7AB2", .type: "#6BDFFF", .string: "#FF8170", .comment: "#9AA5B1",
        .number: "#D9C97C", .attribute: "#E0A86E", .variable: "#78C2B3",
        .inserted: "#3FB950", .deleted: "#FF7B72"
    ]
    /// 紙色テーマのコード背景向けの濃い色。
    static let paper: [CodeSyntaxToken: String] = [
        .keyword: "#7A1C72", .type: "#0B4468", .string: "#9A1A12", .comment: "#5E5547",
        .number: "#1F1A9E", .attribute: "#6B4E00", .variable: "#23555B",
        .inserted: "#1B6630", .deleted: "#A3141F"
    ]

    private static let dynamicColors: [CodeSyntaxToken: NSColor] = Dictionary(
        uniqueKeysWithValues: CodeSyntaxToken.allCases.map { token in
            let lightColor = color(light[token]!), darkColor = color(dark[token]!)
            return (token, NSColor(name: NSColor.Name("MKTownCode.\(token.rawValue)")) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
            })
        })

    /// 外観に追従する色。編集画面とシステム配色のプレビューで使う。
    static func color(for token: CodeSyntaxToken) -> NSColor { dynamicColors[token]! }

    /// プレビューテーマ用の色。拡張テーマは作者がコード色を決めるため `nil`（単色のまま）。
    static func color(for token: CodeSyntaxToken, theme: PreviewTheme) -> NSColor? {
        switch theme {
        case .system: color(for: token)
        case .paper: paper[token].map(color)
        case .extensionTheme: nil
        }
    }

    static func color(_ hex: String) -> NSColor {
        DeclarativeExtension.Theme.parse(hex) ?? .textColor
    }
}

extension NSAttributedString.Key {
    /// プレビューのコードブロック内で字句の種類（`CodeSyntaxToken.rawValue`）を示す。テーマの色を後から当て直すために使う。
    static let codeSyntaxToken = NSAttributedString.Key("MKTownCodeSyntaxToken")
}

@MainActor
enum CodeSyntaxHighlighter {
    /// `tokens` は解析済みの字句（`DocumentSnapshot.codeSyntaxTokens`）。`nil` の場合は解析キャッシュ経由で求める。
    static func render(_ source: String, language: String?,
                       tokens: [CodeSyntaxTokenRange]? = nil) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 8
        let result = NSMutableAttributedString(string: source, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.textColor,
            .backgroundColor: NSColor.controlBackgroundColor,
            .paragraphStyle: paragraph
        ])
        let length = (source as NSString).length
        result.beginEditing()
        defer { result.endEditing() }
        for token in tokens ?? CodeSyntaxAnalyzer.tokens(in: source, language: language) {
            guard NSMaxRange(token.range) <= length else { continue }
            result.addAttributes([.foregroundColor: CodeSyntaxPalette.color(for: token.token),
                                  .codeSyntaxToken: token.token.rawValue], range: token.range)
        }
        return result
    }
}
