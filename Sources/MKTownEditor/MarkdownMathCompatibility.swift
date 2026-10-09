import Foundation
import SwiftMath

/// SwiftMathが解釈しないKaTeX・MathJax由来の記法を、同じ見た目になるSwiftMathの記法へ書き換える。
/// 元のLaTeXは `MarkdownMath.Formula.latex` に残し、書き換えた結果は描画と妥当性判定だけに使う。
enum MarkdownMathCompatibility {
    /// SwiftMathが知らない別名。値はそのまま置き換える文字列。
    private static let aliases: [String: String] = [
        "lt": "<",
        "gt": ">",
        "plusmn": "\\pm",
        "exist": "\\exists",
    ]

    /// SwiftMathが持たない記号。`MTMathAtomFactory` に一度だけ登録する。
    private static let symbols: [(name: String, value: String)] = [
        ("therefore", "\u{2234}"),
        ("because", "\u{2235}"),
        ("gtrless", "\u{2277}"),
        ("lessgtr", "\u{2276}"),
    ]

    /// 添字を下に置く大型演算子として登録する演算子。
    private static let operators: [(name: String, text: String)] = [
        ("argmax", "arg max"),
        ("argmin", "arg min"),
    ]

    private static let styleCommands: Set<String> = ["displaystyle", "textstyle", "scriptstyle", "scriptscriptstyle"]

    /// 環境名の読み替え。値が空の環境は `\begin`・`\end` を外して本体だけを残す。
    private static let environmentNames: [String: String] = [
        "equation": "", "equation*": "",
        "align": "aligned", "align*": "aligned",
        "gather*": "gather",
        "eqnarray*": "eqnarray",
    ]

    /// SwiftMathがちょうど2列を要求する環境。`&` のない本体には空の2列目を補い、
    /// 2つ目以降の `&` は揃え位置にせず、間隔と文字の並びに置き換える。
    private static let twoColumnEnvironments: Set<String> = ["aligned", "split", "eqalign", "cases"]

    static func normalize(_ latex: String, display: Bool) -> String {
        _ = registration
        let chars = Array(latex)
        let environments = rewriteBody(chars[...], environment: nil)
        return rewriteCommands(environments[...], style: display ? "\\displaystyle" : "\\textstyle")
    }

    private static let registration: Void = {
        for symbol in symbols {
            // 公開APIで作れる既存の記号を複製し、記号と種別だけ差し替える。
            guard let atom = MTMathAtomFactory.atom(forLatexSymbol: "leq") else { continue }
            atom.type = .relation
            atom.nucleus = symbol.value
            MTMathAtomFactory.add(latexSymbol: symbol.name, value: atom)
        }
        for item in operators {
            MTMathAtomFactory.add(latexSymbol: item.name,
                                  value: MTMathAtomFactory.operatorWithName(item.text, limits: true))
        }
    }()

    // MARK: - 環境

    /// 環境の本体を行と列に分けて整え、入れ子の環境は先に書き換える。
    /// `environment` が nil のときは式全体を扱う。
    private static func rewriteBody(_ chars: ArraySlice<Character>, environment: String?) -> [Character] {
        var rows: [[Character]] = [[]]
        /// 各行で、波括弧と環境の外にある `&` の位置。
        var separators: [[Int]] = [[]]
        var depth = 0
        var index = chars.startIndex
        while index < chars.endIndex {
            let char = chars[index]
            if char == "\\" {
                let length = commandLength(at: index, in: chars)
                let name = String(chars[(index + 1)..<(index + 1 + length)])
                if name == "\\", depth == 0 {
                    rows.append([])
                    separators.append([])
                    index += 2
                    continue
                }
                if name == "begin", let found = environmentRange(from: index + 1 + length, in: chars),
                   let end = matchingEnd(for: found.name, after: found.end, in: chars) {
                    let body = rewriteBody(chars[found.end..<end.start], environment: found.name)
                    rows[rows.count - 1] += wrap(body, environment: found.name)
                    index = end.end
                    continue
                }
                rows[rows.count - 1] += chars[index..<(index + 1 + length)]
                index += 1 + length
                continue
            }
            if char == "{" { depth += 1 } else if char == "}" { depth = max(0, depth - 1) }
            if char == "&", depth == 0 { separators[separators.count - 1].append(rows[rows.count - 1].count) }
            rows[rows.count - 1].append(char)
            index += 1
        }
        // 末尾の `\\` は空の行を作るだけなので取り除く。
        while rows.count > 1, rows[rows.count - 1].allSatisfy(\.isWhitespace) {
            rows.removeLast()
            separators.removeLast()
        }
        if let environment, twoColumnEnvironments.contains(swiftMathName(for: environment)) {
            if separators.allSatisfy(\.isEmpty) {
                rows = rows.map { $0.allSatisfy(\.isWhitespace) ? $0 : $0 + ["&"] }
            } else {
                rows = zip(rows, separators).map { reducedToTwoColumns($0, separators: $1) }
            }
        }
        return Array(rows.joined(separator: ["\\", "\\"]))
    }

    /// `align` の複数の揃え位置（`a &= b & c &= d`）はSwiftMathでは列が多すぎる。
    /// 最初の `&` だけを揃え位置として残し、組の区切りは `\qquad`、組の中の揃え位置は取り除く。
    private static func reducedToTwoColumns(_ row: [Character], separators: [Int]) -> [Character] {
        var row = row
        for (order, position) in separators.enumerated().reversed() where order > 0 {
            row.replaceSubrange(position...position, with: order % 2 == 1 ? Array("\\qquad ") : [])
        }
        return row
    }

    private static func swiftMathName(for environment: String) -> String {
        environmentNames[environment] ?? environment
    }

    private static func wrap(_ body: [Character], environment: String) -> [Character] {
        let name = swiftMathName(for: environment)
        guard !name.isEmpty else { return body }
        return Array("\\begin{\(name)}") + body + Array("\\end{\(name)}")
    }

    /// `\begin` または `\end` の直後にある `{名前}` を読む。
    private static func environmentRange(from index: Int, in chars: ArraySlice<Character>)
        -> (name: String, end: Int)? {
        var cursor = index
        while cursor < chars.endIndex, chars[cursor].isWhitespace { cursor += 1 }
        guard cursor < chars.endIndex, chars[cursor] == "{",
              let close = chars[cursor...].firstIndex(of: "}") else { return nil }
        let name = String(chars[(cursor + 1)..<close]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("\\") else { return nil }
        return (name, close + 1)
    }

    /// 入れ子を考慮して、対応する `\end{名前}` の範囲を返す。
    private static func matchingEnd(for name: String, after index: Int, in chars: ArraySlice<Character>)
        -> (start: Int, end: Int)? {
        var nesting = 1
        var cursor = index
        while cursor < chars.endIndex {
            guard chars[cursor] == "\\" else { cursor += 1; continue }
            let length = commandLength(at: cursor, in: chars)
            let command = String(chars[(cursor + 1)..<(cursor + 1 + length)])
            if command == "begin" || command == "end",
               let found = environmentRange(from: cursor + 1 + length, in: chars) {
                nesting += command == "begin" ? 1 : -1
                if nesting == 0 {
                    return found.name == name ? (cursor, found.end) : nil
                }
                cursor = found.end
                continue
            }
            cursor += 1 + length
        }
        return nil
    }

    // MARK: - コマンド

    /// 別名を置き換え、上下に積む命令を `\atop` で組み立てる。
    /// `style` は現在の書体サイズ命令で、積む本体の大きさを元の式と揃えるために使う。
    private static func rewriteCommands(_ chars: ArraySlice<Character>, style: String) -> String {
        var output = ""
        var styles = [style]
        var index = chars.startIndex
        while index < chars.endIndex {
            let char = chars[index]
            if char == "{" {
                styles.append(styles[styles.count - 1])
            } else if char == "}" {
                if styles.count > 1 { styles.removeLast() }
            }
            guard char == "\\" else {
                output.append(char)
                index += 1
                continue
            }
            let length = commandLength(at: index, in: chars)
            let name = String(chars[(index + 1)..<(index + 1 + length)])
            let next = index + 1 + length
            if styleCommands.contains(name) {
                styles[styles.count - 1] = "\\" + name
            } else if let replacement = aliases[name] {
                output += replacement
                index = next
                continue
            } else if let stacked = stack(command: name, from: next, in: chars, style: styles[styles.count - 1]) {
                output += stacked.text
                index = stacked.end
                continue
            }
            output += String(chars[index..<next])
            index = next
        }
        return output
    }

    /// `\underbrace{式}_{注釈}`、`\overbrace{式}^{注釈}`、`\underset{下}{本体}`、`\overset{上}{本体}` を
    /// `\atop` による縦積みに置き換える。SwiftMathは括弧を横に伸ばせないので、括弧は下線・上線で代用する。
    private static func stack(command: String, from index: Int, in chars: ArraySlice<Character>, style: String)
        -> (text: String, end: Int)? {
        switch command {
        case "underbrace", "overbrace":
            guard let body = argument(from: index, in: chars) else { return nil }
            let line = command == "underbrace" ? "\\underline" : "\\overline"
            let marker: Character = command == "underbrace" ? "_" : "^"
            let lined = "\(line){\(rewriteCommands(body.content, style: style))}"
            var cursor = body.end
            while cursor < chars.endIndex, chars[cursor].isWhitespace { cursor += 1 }
            guard cursor < chars.endIndex, chars[cursor] == marker,
                  let label = argument(from: cursor + 1, in: chars) else {
                return (lined, body.end)
            }
            let main = style + lined
            let annotation = "\\scriptstyle " + rewriteCommands(label.content, style: "\\scriptstyle")
            return (command == "underbrace" ? "{{\(main)} \\atop {\(annotation)}}"
                                            : "{{\(annotation)} \\atop {\(main)}}", label.end)
        case "underset", "overset":
            guard let annotation = argument(from: index, in: chars),
                  let body = argument(from: annotation.end, in: chars) else { return nil }
            let main = "\(style) " + rewriteCommands(body.content, style: style)
            let label = "\\scriptstyle " + rewriteCommands(annotation.content, style: "\\scriptstyle")
            return (command == "underset" ? "{{\(main)} \\atop {\(label)}}"
                                          : "{{\(label)} \\atop {\(main)}}", body.end)
        default:
            return nil
        }
    }

    /// `{...}` の引数、または1つのコマンドか1文字を読む。
    private static func argument(from index: Int, in chars: ArraySlice<Character>)
        -> (content: ArraySlice<Character>, end: Int)? {
        var cursor = index
        while cursor < chars.endIndex, chars[cursor].isWhitespace { cursor += 1 }
        guard cursor < chars.endIndex else { return nil }
        if chars[cursor] == "{" {
            var depth = 0
            var scan = cursor
            while scan < chars.endIndex {
                let char = chars[scan]
                if char == "\\" {
                    scan += 1 + commandLength(at: scan, in: chars)
                    continue
                }
                if char == "{" { depth += 1 }
                if char == "}" {
                    depth -= 1
                    if depth == 0 { return (chars[(cursor + 1)..<scan], scan + 1) }
                }
                scan += 1
            }
            return nil
        }
        if chars[cursor] == "\\" {
            let end = cursor + 1 + commandLength(at: cursor, in: chars)
            return (chars[cursor..<end], end)
        }
        return (chars[cursor..<(cursor + 1)], cursor + 1)
    }

    /// `\` に続くコマンド名の長さ。英字の並びはその長さ、`\\` や `\{` などの制御記号は1、末尾の `\` は0。
    private static func commandLength(at index: Int, in chars: ArraySlice<Character>) -> Int {
        let start = index + 1
        guard start < chars.endIndex else { return 0 }
        let letters = chars[start...].prefix(while: { $0.isLetter && $0.isASCII }).count
        return max(letters, 1)
    }
}
