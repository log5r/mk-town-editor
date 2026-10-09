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

    /// 分子・分母を持つコマンド。引数の書体は一段小さくなる。
    private static let fractionCommands: Set<String> = ["frac", "binom"]

    /// 書体を固定する分数。SwiftMathにはないので、書体命令を付けた `\frac`・`\binom` に置き換える。
    private static let forcedFractions: [String: (command: String, style: String)] = [
        "tfrac": ("frac", "\\textstyle"), "dfrac": ("frac", "\\displaystyle"),
        "tbinom": ("binom", "\\textstyle"), "dbinom": ("binom", "\\displaystyle"),
    ]

    /// 引数を取るコマンドとその数。添字や分数の引数に波括弧なしで置かれたとき、引数ごと同じ書体にする。
    /// SwiftMath 1.7.3 が解釈する引数付きコマンドをすべて載せる（アクセントと書体は `MTMathAtomFactory` の表と同じ）。
    private static let argumentCounts: [String: Int] = {
        var counts: [String: Int] = [
            "frac": 2, "tfrac": 2, "dfrac": 2, "binom": 2, "tbinom": 2, "dbinom": 2, "underset": 2, "overset": 2,
            "color": 2, "textcolor": 2, "colorbox": 2,
            "sqrt": 1, "underbrace": 1, "overbrace": 1, "overline": 1, "underline": 1,
        ]
        let accents = ["grave", "acute", "hat", "tilde", "bar", "breve", "dot", "ddot", "check", "vec",
                       "widehat", "widetilde"]
        let fontStyles = ["mathnormal", "mathrm", "textrm", "rm", "mathbf", "bf", "textbf", "mathcal", "cal",
                          "mathtt", "texttt", "mathit", "textit", "mit", "mathsf", "textsf", "mathfrak", "frak",
                          "mathbb", "mathbfit", "bm", "text"]
        for name in accents + fontStyles { counts[name] = 1 }
        return counts
    }()

    /// 別名を置き換え、上下に積む命令を `\atop` で組み立てる。
    /// `style` は現在の書体サイズ命令で、積む本体の大きさを元の式と揃えるために使う。
    /// 添字（`_`・`^`）の引数と分数の引数は、TeXの規則に従って一段小さい書体で再帰的に処理する。
    private static func rewriteCommands(_ chars: ArraySlice<Character>, style: String) -> String {
        var output = ""
        var style = style
        var index = chars.startIndex
        while index < chars.endIndex {
            let char = chars[index]
            if char == "{", let group = token(from: index, in: chars) {
                output += "{" + rewriteCommands(group.content, style: style) + "}"
                index = group.end
                continue
            }
            if char == "_" || char == "^" {
                output.append(char)
                index += 1
                if let script = token(from: index, in: chars) {
                    output += rewritten(script, style: scriptStyle(of: style))
                    index = script.end
                }
                continue
            }
            guard char == "\\" else {
                output.append(char)
                index += 1
                continue
            }
            let length = commandLength(at: index, in: chars)
            let name = String(chars[(index + 1)..<(index + 1 + length)])
            let next = index + 1 + length
            if name == "begin", let found = environmentRange(from: next, in: chars),
               let end = matchingEnd(for: found.name, after: found.end, in: chars) {
                // 環境の各セルは独立したスコープなので、中で宣言した書体を外へ漏らさない。
                output += String(chars[index..<found.end])
                output += rewriteCells(chars[found.end..<end.start], style: cellStyle(for: found.name, outer: style))
                output += String(chars[end.start..<end.end])
                index = end.end
                continue
            }
            if name == "left", let pair = pairedDelimiters(from: next, in: chars) {
                // `\left ... \right` の中も独立したスコープなので、中で宣言した書体を外へ漏らさない。
                output += String(chars[index..<pair.bodyStart])
                output += rewriteCommands(chars[pair.bodyStart..<pair.rightStart], style: style)
                output += String(chars[pair.rightStart..<pair.end])
                index = pair.end
                continue
            }
            if styleCommands.contains(name) {
                style = "\\" + name
            } else if let replacement = aliases[name] {
                output += replacement
                index = next
                continue
            } else if let stacked = stack(command: name, from: next, in: chars, style: style) {
                output += stacked.text
                index = stacked.end
                continue
            }
            if let forced = forcedFractions[name] {
                let (arguments, end) = fractionArguments(from: next, in: chars, style: forced.style)
                output += "{\(forced.style)\\\(forced.command)\(arguments)}"
                index = end
                continue
            }
            output += String(chars[index..<next])
            index = next
            if name == "sqrt", let root = rootIndex(from: index, in: chars) {
                // 根号の指数はTeXでは最小の書体になる。被開法数は現在の書体のまま続けて処理する。
                output += "[" + rewriteCommands(root.content, style: "\\scriptscriptstyle") + "]"
                index = root.end
            }
            if fractionCommands.contains(name) {
                let (arguments, end) = fractionArguments(from: index, in: chars, style: style)
                output += arguments
                index = end
            }
        }
        return output
    }

    /// 分数の2つの引数を、分数の書体 `style` から一段小さい書体で書き換える。
    private static func fractionArguments(from index: Int, in chars: ArraySlice<Character>, style: String)
        -> (text: String, end: Int) {
        var output = ""
        var index = index
        for _ in 0..<2 {
            guard let argument = token(from: index, in: chars) else { break }
            output += rewritten(argument, style: fractionStyle(of: style))
            index = argument.end
        }
        return (output, index)
    }

    /// `cases` と行列の各セルはSwiftMathが文字サイズで組むので、そのほかの環境だけ外側の書体を引き継ぐ。
    private static func cellStyle(for environment: String, outer: String) -> String {
        let textStyled: Set<String> = ["cases", "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix"]
        return textStyled.contains(environment) ? "\\textstyle" : outer
    }

    /// 環境の本体を `&` と `\\` で区切ったセルごとに書き換える。入れ子の環境は1つのセルの一部として扱う。
    private static func rewriteCells(_ chars: ArraySlice<Character>, style: String) -> String {
        var output = ""
        var cellStart = chars.startIndex
        var depth = 0
        var index = chars.startIndex
        func flush(upTo end: Int, separator: ArraySlice<Character>) {
            output += rewriteCommands(chars[cellStart..<end], style: style) + String(separator)
        }
        while index < chars.endIndex {
            let char = chars[index]
            if char == "\\" {
                let length = commandLength(at: index, in: chars)
                let name = String(chars[(index + 1)..<(index + 1 + length)])
                let next = index + 1 + length
                if name == "\\", depth == 0 {
                    flush(upTo: index, separator: chars[index..<next])
                    cellStart = next
                } else if name == "begin", let found = environmentRange(from: next, in: chars),
                          let end = matchingEnd(for: found.name, after: found.end, in: chars) {
                    index = end.end
                    continue
                }
                index = next
                continue
            }
            if char == "{" { depth += 1 } else if char == "}" { depth = max(0, depth - 1) }
            if char == "&", depth == 0 {
                flush(upTo: index, separator: chars[index..<(index + 1)])
                cellStart = index + 1
            }
            index += 1
        }
        flush(upTo: chars.endIndex, separator: [])
        return output
    }

    private static func rewritten(_ token: Token, style: String) -> String {
        let inner = rewriteCommands(token.content, style: style)
        return token.braced ? "{\(inner)}" : inner
    }

    /// 添字に入ったときの書体。
    private static func scriptStyle(of style: String) -> String {
        style == "\\scriptstyle" || style == "\\scriptscriptstyle" ? "\\scriptscriptstyle" : "\\scriptstyle"
    }

    /// 分子・分母に入ったときの書体。
    private static func fractionStyle(of style: String) -> String {
        switch style {
        case "\\displaystyle": return "\\textstyle"
        case "\\textstyle": return "\\scriptstyle"
        default: return "\\scriptscriptstyle"
        }
    }

    /// `\underbrace{式}_{注釈}`、`\overbrace{式}^{注釈}`、`\underset{下}{本体}`、`\overset{上}{本体}` を
    /// `\atop` による縦積みに置き換える。SwiftMathは括弧を横に伸ばせないので、括弧は下線・上線で代用する。
    private static func stack(command: String, from index: Int, in chars: ArraySlice<Character>, style: String)
        -> (text: String, end: Int)? {
        let small = scriptStyle(of: style)
        switch command {
        case "underbrace", "overbrace":
            guard let body = token(from: index, in: chars) else { return nil }
            let line = command == "underbrace" ? "\\underline" : "\\overline"
            let marker: Character = command == "underbrace" ? "_" : "^"
            let lined = "\(line){\(rewriteCommands(body.content, style: style))}"
            var cursor = body.end
            while cursor < chars.endIndex, chars[cursor].isWhitespace { cursor += 1 }
            guard cursor < chars.endIndex, chars[cursor] == marker,
                  let label = token(from: cursor + 1, in: chars) else {
                return (lined, body.end)
            }
            let main = style + lined
            let annotation = "\(small) " + rewriteCommands(label.content, style: small)
            return (command == "underbrace" ? "{{\(main)} \\atop {\(annotation)}}"
                                            : "{{\(annotation)} \\atop {\(main)}}", label.end)
        case "underset", "overset":
            guard let annotation = token(from: index, in: chars),
                  let body = token(from: annotation.end, in: chars) else { return nil }
            let main = "\(style) " + rewriteCommands(body.content, style: style)
            let label = "\(small) " + rewriteCommands(annotation.content, style: small)
            return (command == "underset" ? "{{\(main)} \\atop {\(label)}}"
                                          : "{{\(label)} \\atop {\(main)}}", body.end)
        default:
            return nil
        }
    }

    /// 引数として読めるひとまとまり。`{...}` の中身、引数を含めたコマンド、または1文字。
    private struct Token {
        let content: ArraySlice<Character>
        let end: Int
        let braced: Bool
    }

    /// `{...}`、引数を含めたコマンド（`\sqrt{x}`、`\underbrace{x}_{n}`）、または1文字を読む。
    private static func token(from index: Int, in chars: ArraySlice<Character>) -> Token? {
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
                    if depth == 0 { return Token(content: chars[(cursor + 1)..<scan], end: scan + 1, braced: true) }
                }
                scan += 1
            }
            return nil
        }
        if chars[cursor] == "\\" {
            let length = commandLength(at: cursor, in: chars)
            let name = String(chars[(cursor + 1)..<(cursor + 1 + length)])
            var end = cursor + 1 + length
            if name == "sqrt", let root = rootIndex(from: end, in: chars) {
                // `\sqrt[3]{x}` の任意引数は根号の一部なので、被開法数と一緒に読む。
                end = root.end
            }
            if name == "left" {
                // `\left( ... \right)` は対になる `\right` までが1つのまとまり。対がなければ括弧まで。
                end = pairedDelimiters(from: end, in: chars)?.end ?? delimiterEnd(from: end, in: chars)
            }
            if name == "begin", let found = environmentRange(from: end, in: chars),
               let close = matchingEnd(for: found.name, after: found.end, in: chars) {
                // 環境は `\end` までが1つのまとまり。
                end = close.end
            }
            for _ in 0..<(argumentCounts[name] ?? 0) {
                guard let argument = token(from: end, in: chars) else { break }
                end = argument.end
            }
            if name == "underbrace" || name == "overbrace" {
                var scan = end
                while scan < chars.endIndex, chars[scan].isWhitespace { scan += 1 }
                if scan < chars.endIndex, chars[scan] == (name == "underbrace" ? "_" : "^"),
                   let label = token(from: scan + 1, in: chars) {
                    end = label.end
                }
            }
            return Token(content: chars[cursor..<end], end: end, braced: false)
        }
        return Token(content: chars[cursor..<(cursor + 1)], end: cursor + 1, braced: false)
    }

    /// `\left` の直後から見た、括弧の次（中身の先頭）、対応する `\right` の位置、その括弧の直後。
    private static func pairedDelimiters(from index: Int, in chars: ArraySlice<Character>)
        -> (bodyStart: Int, rightStart: Int, end: Int)? {
        let bodyStart = delimiterEnd(from: index, in: chars)
        var cursor = bodyStart
        var nesting = 1
        while cursor < chars.endIndex {
            guard chars[cursor] == "\\" else { cursor += 1; continue }
            let length = commandLength(at: cursor, in: chars)
            let name = String(chars[(cursor + 1)..<(cursor + 1 + length)])
            let commandStart = cursor
            cursor += 1 + length
            if name == "left" {
                nesting += 1
                cursor = delimiterEnd(from: cursor, in: chars)
            } else if name == "right" {
                nesting -= 1
                cursor = delimiterEnd(from: cursor, in: chars)
                if nesting == 0 { return (bodyStart, commandStart, cursor) }
            }
        }
        return nil
    }

    /// `\left`・`\right` に続く括弧（1文字または `\{` などのコマンド）の終了位置。
    private static func delimiterEnd(from index: Int, in chars: ArraySlice<Character>) -> Int {
        var cursor = index
        while cursor < chars.endIndex, chars[cursor].isWhitespace { cursor += 1 }
        guard cursor < chars.endIndex else { return cursor }
        return chars[cursor] == "\\" ? cursor + 1 + commandLength(at: cursor, in: chars) : cursor + 1
    }

    /// `\sqrt` の直後にある任意引数 `[...]` の中身と終了位置。
    private static func rootIndex(from index: Int, in chars: ArraySlice<Character>)
        -> (content: ArraySlice<Character>, end: Int)? {
        var cursor = index
        while cursor < chars.endIndex, chars[cursor].isWhitespace { cursor += 1 }
        guard cursor < chars.endIndex, chars[cursor] == "[",
              let close = chars[cursor...].firstIndex(of: "]") else { return nil }
        return (chars[(cursor + 1)..<close], close + 1)
    }

    /// `\` に続くコマンド名の長さ。英字の並びはその長さ、`\\` や `\{` などの制御記号は1、末尾の `\` は0。
    private static func commandLength(at index: Int, in chars: ArraySlice<Character>) -> Int {
        let start = index + 1
        guard start < chars.endIndex else { return 0 }
        let letters = chars[start...].prefix(while: { $0.isLetter && $0.isASCII }).count
        return max(letters, 1)
    }
}
