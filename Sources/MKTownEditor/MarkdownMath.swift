import AppKit
import Foundation
import SwiftMath
import SwiftUI

/// Math follows the extended Markdown dialect: `$...$` stays on one line and
/// `$$...$$` forms a display block, on one or more lines. Escaped dollars and code spans are literal.
enum MarkdownMath {
    struct Formula: Hashable, Sendable {
        let source: String
        let latex: String
        let display: Bool
        /// SwiftMathが解釈できる形へ書き換えたLaTeX。描画と妥当性判定にはこちらを使い、
        /// 代替テキストや読み上げには元の `latex` を使う。
        let swiftMathLaTeX: String
        /// 数式ブロック（`$$...$$`）と同じ大きさで描くか。数式ブロックと、先頭で `\displaystyle` を指定した
        /// インライン数式（`$\displaystyle \frac{1}{k}$`）で真になる。
        let usesDisplaySize: Bool

        init(source: String, latex: String, display: Bool) {
            self.source = source
            self.latex = latex
            self.display = display
            swiftMathLaTeX = MarkdownMathCompatibility.normalize(latex, display: display)
            usesDisplaySize = display || Self.startsWithDisplayStyle(latex)
        }

        /// 先頭の空白の後、波括弧の外で `\displaystyle` コマンドから始まるか。
        /// 式全体の書体を指定した場合だけを対象にする。`\displaystylefoo` のような別名のコマンド、
        /// 途中の `\displaystyle`（式の一部だけの書体）、`\dfrac`（分数1つの書体）は対象にしない。
        static func startsWithDisplayStyle(_ latex: String) -> Bool {
            let command = "\\displaystyle"
            let body = latex.drop(while: \.isWhitespace)
            guard body.hasPrefix(command) else { return false }
            // TeXのコマンド名は英字の並びなので、直後が英字なら別のコマンドになる。
            guard let next = body.dropFirst(command.count).first else { return true }
            return !(next.isASCII && next.isLetter)
        }
    }

    enum Segment: Equatable {
        case text(String)
        case formula(Formula)
    }

    static func placeholders(in text: String) -> (text: String, formulas: [(String, Formula)]) {
        var output = ""
        var formulas: [(String, Formula)] = []
        for segment in segments(text) {
            switch segment {
            case let .text(value): output += value
            case let .formula(formula):
                let token = "MKTOWNMATHPLACEHOLDER\(formulas.count)END"
                output += token
                formulas.append((token, formula))
            }
        }
        return (output, formulas)
    }

    static func displayFormula(_ text: String) -> Formula? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count > 4 else { return nil }
        let chars = Array(trimmed)
        // Only the first unescaped closing delimiter can terminate this block.
        guard let closing = (2..<(chars.count - 1)).first(where: {
            chars[$0] == "$" && chars[$0 + 1] == "$" && !escaped(at: $0, in: chars)
        }), closing == chars.count - 2 else { return nil }
        let latex = String(chars[2..<closing]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !latex.isEmpty else { return nil }
        return Formula(source: text, latex: latex, display: true)
    }

    static func containsDisplayDelimiter(_ text: String) -> Bool {
        let chars = Array(text)
        guard chars.count >= 2 else { return false }
        return (0..<(chars.count - 1)).contains {
            chars[$0] == "$" && chars[$0 + 1] == "$" && !escaped(at: $0, in: chars)
        }
    }

    static func segments(_ text: String) -> [Segment] {
        let chars = Array(text)
        var parts: [Segment] = []
        var plain = ""
        var index = 0
        var codeFence = 0
        while index < chars.count {
            if chars[index] == "`" {
                let length = chars[index...].prefix(while: { $0 == "`" }).count
                if codeFence == 0 { codeFence = length }
                else if codeFence == length { codeFence = 0 }
                plain += String(chars[index..<(index + length)])
                index += length
                continue
            }
            if chars[index] == "$", codeFence == 0,
               !escaped(at: index, in: chars),
               (index == 0 || chars[index - 1] != "$"),
               index + 1 < chars.count, chars[index + 1] != "$",
               !chars[index + 1].isWhitespace {
                var end = index + 1
                while end < chars.count, !chars[end].isNewline {
                    if chars[end] == "`" { break }
                    if chars[end] == "$", !escaped(at: end, in: chars) {
                        guard end > index + 1, !chars[end - 1].isWhitespace,
                              end + 1 == chars.count || (!chars[end + 1].isNumber && chars[end + 1] != "$" ) else {
                            break
                        }
                        let latex = String(chars[(index + 1)..<end])
                        if !plain.isEmpty { parts.append(.text(plain)); plain = "" }
                        parts.append(.formula(Formula(source: String(chars[index...end]), latex: latex,
                                                      display: false)))
                        index = end + 1
                        break
                    }
                    end += 1
                }
                if index == end + 1 { continue }
            }
            plain.append(chars[index])
            index += 1
        }
        if !plain.isEmpty { parts.append(.text(plain)) }
        return parts
    }

    private static func escaped(at index: Int, in chars: [Character]) -> Bool {
        var slashes = 0
        var cursor = index
        while cursor > 0, chars[cursor - 1] == "\\" { slashes += 1; cursor -= 1 }
        return slashes % 2 == 1
    }
}

@MainActor
enum MarkdownMathRenderer {
    /// 数式ブロック（`$$...$$`）の文字の大きさ。プレビュー、HTML、PDFで共通にする。
    nonisolated static let displayFontSize: CGFloat = 21

    /// 数式を描く文字の大きさ。`inlineSize` は周りの文字の大きさ（インライン数式の既定の大きさ）。
    /// 数式ブロックと同じ大きさで描く式（`usesDisplaySize`）は数式ブロックの大きさ（`displaySize`）にそろえる。
    /// 見出しのように周りの文字のほうが大きければ、周りの文字に合わせる。
    /// `displaySize` はプレビューでは `displayFontSize`。HTMLでは本文の大きさに比例させる（`MarkdownHTMLExporter`）。
    nonisolated static func fontSize(for formula: MarkdownMath.Formula, inlineSize: CGFloat,
                                     displaySize: CGFloat = displayFontSize) -> CGFloat {
        formula.usesDisplaySize ? max(displaySize, inlineSize) : inlineSize
    }

    /// 描いた数式の画像と、画像の下端から数式のベースラインまでの高さ。
    struct Rendered {
        let image: NSImage
        /// 画像の下端から数式のベースラインまでの高さ（ポイント）。分数の分母や `\lim` の下付きなど、
        /// ベースラインより下に出る部分の深さ（descent）に当たる。
        let baseline: CGFloat
    }

    static func label(_ formula: MarkdownMath.Formula, fontSize: CGFloat = 16) -> MTMathUILabel? {
        let label = MTMathUILabel(frame: .zero)
        label.latex = formula.swiftMathLaTeX
        guard label.error == nil else { return nil }
        label.fontSize = fontSize
        label.textColor = .labelColor
        label.labelMode = formula.display ? .display : .text
        return label
    }

    static func render(_ formula: MarkdownMath.Formula, fontSize: CGFloat = 16) -> Rendered? {
        guard let label = label(formula, fontSize: fontSize) else { return nil }
        let fitting = label.fittingSize
        guard fitting.width > 0, fitting.height > 0, fitting.width < 4000, fitting.height < 4000 else { return nil }
        // 大きさは整数に切り上げ、HTMLの `width`・`height` で拡大縮小されないようにする。
        // `MTMathUILabel` は式の高さを文字の大きさの半分以上として上下中央に置くため、
        // 低い式（`-` など）が画像の下にはみ出さないよう、高さもそれ以上にする。
        let size = NSSize(width: ceil(fitting.width), height: ceil(max(fitting.height, fontSize / 2)))
        label.frame = NSRect(origin: .zero, size: size)
        label.needsLayout = true
        label.layoutSubtreeIfNeeded()
        guard let display = label.displayList,
              let rep = label.bitmapImageRepForCachingDisplay(in: label.bounds) else { return nil }
        // 式を置いた位置（`MTDisplay.position`）は公開されていないため、`MTMathUILabel` の配置
        // （`_layoutSubviews`：高さを文字の大きさの半分以上として上下中央に置く。余白 `contentInsets` は0）を
        // 同じ式で求める。切り上げで空いた分も含めて、画像の下端から数式のベースラインまでの高さになる。
        let layoutHeight = max(display.ascent + display.descent, fontSize / 2)
        let baseline = (size.height - layoutHeight) / 2 + display.descent
        label.cacheDisplay(in: label.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return Rendered(image: image, baseline: baseline)
    }

    static func image(_ formula: MarkdownMath.Formula, fontSize: CGFloat = 16) -> NSImage? {
        render(formula, fontSize: fontSize)?.image
    }

    /// 本文に置く数式の添付。数式のベースラインを本文のベースラインに合わせるため、
    /// ベースラインより下の部分（`baseline`）だけ下げて置く。TextKitは添付の下げた分も行の高さに含める
    /// （docs/inline-math-baseline-and-display-size.md）。
    static func attachment(_ formula: MarkdownMath.Formula, fontSize: CGFloat = 16) -> NSAttributedString? {
        guard let rendered = render(formula, fontSize: fontSize) else { return nil }
        let attachment = NSTextAttachment()
        attachment.image = rendered.image
        attachment.bounds = NSRect(x: 0, y: -rendered.baseline,
                                   width: rendered.image.size.width, height: rendered.image.size.height)
        return NSAttributedString(attachment: attachment)
    }

    static func htmlImage(_ formula: MarkdownMath.Formula, fontSize: CGFloat = 16) -> String? {
        guard let rendered = render(formula, fontSize: fontSize),
              let tiff = rendered.image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            return nil
        }
        let alt = formula.latex.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        // インライン数式は画像の下端を本文のベースラインより `baseline` だけ下げ、数式のベースラインを本文にそろえる。
        // 下げ幅は画像の元の大きさでの値なので、書き出しのスタイルシートの `img { max-width: 100% }` で
        // 縮むと数式が本文より下がる。インライン数式の画像は縮めない（`max-width:none`。KaTeX・MathJaxと同じ）。
        // 数式ブロックはそろえるベースラインがないため、従来どおり幅に合わせて縮む。
        let style = formula.display ? "display:block;margin:1em auto"
            : "vertical-align:\(cssLength(-rendered.baseline));max-width:none"
        let size = rendered.image.size
        return "<img class=\"math\" src=\"data:image/png;base64,\(png.base64EncodedString())\" alt=\"\(alt)\" style=\"\(style)\" width=\"\(Int(size.width))\" height=\"\(Int(size.height))\">"
    }

    /// HTMLから読み込んだ文字列（PDF書き出し）のインライン数式を、プレビューと同じ置き方にする。
    ///
    /// HTMLの読み込みは `vertical-align:-Npx` を画像の文字の `NSBaselineOffset`（-N）に変える。
    /// TextKitは下げた画像でも元の位置の高さを行の上側に取るため、行の上に画像の深さ分の空きができる。
    /// 下げた量を添付の `bounds.origin.y` に移すと、プレビュー（`attachment(_:fontSize:)`）と同じく、
    /// ベースラインの上下に画像が実際に占める分だけ行が広がる。
    /// `vertical-align` に負の長さを付けるのは数式の画像だけなので、ほかの画像は変えない。
    static func alignImportedMathAttachments(in text: NSMutableAttributedString) {
        let whole = NSRange(location: 0, length: text.length)
        var replacements: [(NSRange, NSTextAttachment)] = []
        text.enumerateAttribute(.attachment, in: whole) { value, range, _ in
            guard let attachment = value as? NSTextAttachment,
                  let offset = (text.attribute(.baselineOffset, at: range.location, effectiveRange: nil)
                                as? NSNumber).map({ CGFloat($0.doubleValue) }), offset < 0,
                  let image = (attachment.attachmentCell as? NSTextAttachmentCell)?.image ?? attachment.image
            else { return }
            let replacement = NSTextAttachment()
            replacement.image = image
            replacement.bounds = NSRect(x: 0, y: offset, width: image.size.width, height: image.size.height)
            replacements.append((range, replacement))
        }
        guard !replacements.isEmpty else { return }
        text.beginEditing()
        for (range, replacement) in replacements {
            text.addAttribute(.attachment, value: replacement, range: range)
            text.removeAttribute(.baselineOffset, range: range)
        }
        text.endEditing()
    }

    /// CSSの長さ（px）。小数第2位までにし、地域の設定によらず小数点を `.` にする。
    nonisolated static func cssLength(_ value: CGFloat) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == 0 { return "0" }
        return "\(Double(rounded))px".replacingOccurrences(of: ".0px", with: "px")
    }
}

struct MarkdownMathView: NSViewRepresentable {
    let formula: MarkdownMath.Formula

    func makeNSView(context: Context) -> MTMathUILabel {
        let view = MTMathUILabel(frame: .zero)
        view.setContentHuggingPriority(.required, for: .vertical)
        view.fontSize = MarkdownMathRenderer.displayFontSize
        view.labelMode = .display
        view.textColor = .labelColor
        return view
    }

    final class Coordinator {
        var colorScheme: ColorScheme?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ view: MTMathUILabel, context: Context) {
        // 文字色は設定時に解決されるため、外観が変わった時は設定し直す。
        if context.coordinator.colorScheme != context.environment.colorScheme {
            context.coordinator.colorScheme = context.environment.colorScheme
            view.effectiveAppearance.performAsCurrentDrawingAppearance { view.textColor = .labelColor }
        }
        // latexの再設定は再解析を伴うため、式が変わった時だけ行う。
        guard view.latex != formula.swiftMathLaTeX else { return }
        view.latex = formula.swiftMathLaTeX
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MTMathUILabel, context: Context) -> CGSize? {
        nsView.fittingSize
    }
}
