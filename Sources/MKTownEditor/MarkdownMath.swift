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

        init(source: String, latex: String, display: Bool) {
            self.source = source
            self.latex = latex
            self.display = display
            swiftMathLaTeX = MarkdownMathCompatibility.normalize(latex, display: display)
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
    /// 数式の文字の大きさの、周りの文字に対する倍率。数式用の書体は同じ大きさの本文の文字より小さく見えるため、
    /// KaTeXと同じく1.2倍で描く。インライン数式（`\displaystyle` の有無によらない）も数式ブロックもこの倍率だけで決め、
    /// `\displaystyle` は分数や極限の組み方（TeXの書体）だけを変える。
    nonisolated static let fontScale: CGFloat = 1.2

    /// 周りの文字の大きさ `surrounding` のところに置く数式の文字の大きさ。
    /// インライン数式は置く場所の文字、数式ブロックは本文の文字の大きさを渡す。
    nonisolated static func fontSize(surrounding: CGFloat) -> CGFloat {
        surrounding * fontScale
    }

    /// HTMLに埋め込むPNGの標準の画素密度（CSSの1pxあたりの画素数）。
    /// Retinaの画面（2倍）と印刷（PDF。3倍で約288dpi）でぼやけないよう3倍にする。
    /// 数式の画像は余白が多く、PNGの圧縮が効くため、1倍に比べたファイルの増え方は小さい
    /// （`ax+b` を19.2pxで描いた場合、1倍723バイト・2倍882バイト・3倍982バイト）。
    nonisolated static let htmlPixelDensity: CGFloat = 3

    /// 1つの数式に使う画素数の上限。8ビットRGBAの画素データで16 MiB。
    private nonisolated static let maximumPixelCount = 2048 * 2048

    /// 描いた数式の画像と、画像の下端から数式のベースラインまでの高さ。
    struct Rendered {
        let image: NSImage
        /// 画像の下端から数式のベースラインまでの高さ（ポイント）。分数の分母や `\lim` の下付きなど、
        /// ベースラインより下に出る部分の深さ（descent）に当たる。
        let baseline: CGFloat
    }

    static func label(_ formula: MarkdownMath.Formula, fontSize: CGFloat) -> MTMathUILabel? {
        let label = MTMathUILabel(frame: .zero)
        label.latex = formula.swiftMathLaTeX
        guard label.error == nil else { return nil }
        label.fontSize = fontSize
        // 既定の文字色は描くときに `MathDrawing` が外観に合わせて設定し直す。
        label.textColor = .labelColor
        label.labelMode = formula.display ? .display : .text
        return label
    }

    static func render(_ formula: MarkdownMath.Formula, fontSize: CGFloat) -> Rendered? {
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
        guard let display = label.displayList else { return nil }
        // 式を置いた位置（`MTDisplay.position`）は公開されていないため、`MTMathUILabel` の配置
        // （`_layoutSubviews`：高さを文字の大きさの半分以上として上下中央に置く。余白 `contentInsets` は0）を
        // 同じ式で求める。切り上げで空いた分も含めて、画像の下端から数式のベースラインまでの高さになる。
        let layoutHeight = max(display.ascent + display.descent, fontSize / 2)
        let baseline = (size.height - layoutHeight) / 2 + display.descent
        // 画素の画像にせず、描くたびに描く先の解像度と外観で式を描く画像にする（`MathDrawing`）。
        // 1倍の画素の画像は、Retinaの画面で引き伸ばされてぼやけ、置かれた位置の端数によって濃さも変わった。
        let drawing = MathDrawing(label: label)
        let image = NSImage(size: size, flipped: false) { rect in
            // 描画処理はビュー（`MTMathUILabel`）に触れるため、メインスレッドでだけ描く。
            // この画像を描くのは、プレビューの `NSTextView` の描画とコピー、HTML書き出しの `pngData` で、
            // いずれもメインスレッドから呼ばれる（PDFと印刷はHTMLから読み込んだPNGを描き、この画像は使わない）。
            guard Thread.isMainThread else {
                assertionFailure("数式の画像はメインスレッドで描く")
                return false
            }
            return MainActor.assumeIsolated { drawing.draw(in: rect) }
        }
        // 外観（ライト・ダーク）が変わったときに古い色で描かないよう、描いた結果を画像に残さない。
        image.cacheMode = .never
        return Rendered(image: image, baseline: baseline)
    }

    /// 数式を、描く先の解像度で描く処理。`NSImage` の描画処理から呼ばれる。
    ///
    /// 文字色は描くときの外観（`NSAppearance.currentDrawing()`、文字列を描くビューの外観）で `labelColor` を解決し、
    /// `MTMathUILabel.textColor` に設定する。SwiftMathはこの色を式の組版結果（`displayList`）へ伝えるとき、
    /// `\color`・`\textcolor` で色を指定した部分には指定の色を残し、`\colorbox` の背景色も変えない
    /// （構造化プレビューの `MarkdownMathView` と同じ描き方になる）。組版結果の色の設定は公開されていないため、
    /// ラベルを持ち続け、色が変わったときだけ設定し直す（設定すると色付きの文字列を作り直すため）。
    @MainActor
    private final class MathDrawing {
        private let label: MTMathUILabel
        private var color: CGColor?

        init(label: MTMathUILabel) {
            self.label = label
            // 式の誤りを表示する文字欄（`NSTextField`）は使わない。数式ごとに持ち続けないよう外す。
            label.errorLabel?.removeFromSuperview()
            label.errorLabel = nil
        }

        func draw(in rect: NSRect) -> Bool {
            guard let context = NSGraphicsContext.current?.cgContext, let display = label.displayList else {
                return false
            }
            let resolved = NSColor.labelColor.cgColor
            if color != resolved {
                label.textColor = NSColor(cgColor: resolved)
                color = resolved
            }
            context.saveGState()
            defer { context.restoreGState() }
            // 文字列を描くビューの文字の行列を引き継がないよう、Core Text の行列を初期値に戻す。
            context.textMatrix = .identity
            display.draw(context)
            return true
        }
    }

    static func image(_ formula: MarkdownMath.Formula, fontSize: CGFloat) -> NSImage? {
        render(formula, fontSize: fontSize)?.image
    }

    /// 本文に置く数式の添付。数式のベースラインを本文のベースラインに合わせるため、
    /// ベースラインより下の部分（`baseline`）だけ下げて置く。TextKitは添付の下げた分も行の高さに含める
    /// （docs/math-font-size-and-baseline.md）。
    static func attachment(_ formula: MarkdownMath.Formula, fontSize: CGFloat) -> NSAttributedString? {
        guard let rendered = render(formula, fontSize: fontSize) else { return nil }
        let attachment = MarkdownMathAttachment(image: rendered.image,
                                                bounds: NSRect(x: 0, y: -rendered.baseline,
                                                               width: rendered.image.size.width,
                                                               height: rendered.image.size.height))
        return NSAttributedString(attachment: attachment)
    }

    static func htmlImage(_ formula: MarkdownMath.Formula, fontSize: CGFloat) -> String? {
        guard let rendered = render(formula, fontSize: fontSize),
              let png = pngData(rendered.image, density: htmlPixelDensity) else {
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

    /// 指定した密度で描くと上限を超える場合は、幅と高さを同じ倍率で縮める。
    nonisolated static func bitmapDimensions(for size: NSSize, density: CGFloat) -> (width: Int, height: Int)? {
        let width = ceil(size.width * density)
        let height = ceil(size.height * density)
        let pixelCount = width * height
        guard density > 0, width >= 1, height >= 1, pixelCount.isFinite else { return nil }

        let limit = CGFloat(maximumPixelCount)
        // 短辺を最低1画素にしても上限に収まるよう、長辺も制限する。
        let scale = min(1, sqrt(limit / pixelCount), limit / max(width, height))
        return (max(1, Int(width * scale)), max(1, Int(height * scale)))
    }

    /// `image` を画素数の上限内で描いたPNG。画像の大きさ（`size`）はポイントのままにし、
    /// PNGの解像度の情報（3倍なら216dpi）から読み込み側が元の大きさを求められるようにする。
    /// 文字色は従来どおり、書き出すときのアプリの外観で決める。
    static func pngData(_ image: NSImage, density: CGFloat) -> Data? {
        let size = image.size
        guard let pixels = bitmapDimensions(for: size, density: density),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels.width,
                                         pixelsHigh: pixels.height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        // 描画の文脈は作った時点の `size` で倍率を決めるため、先に大きさ（ポイント）を設定する。
        // 後から設定すると1倍で描かれ、画像の左下の一部にだけ式が入る。
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSApplication.shared.effectiveAppearance.performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(origin: .zero, size: size))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
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
            // 大きさは読み込みが決めた枠（HTMLの `width`・`height`）を使う。
            // 読み込み方によっては画像の大きさがPNGの画素数になるため、画像の大きさは使わない。
            let size = (attachment.attachmentCell as? NSTextAttachmentCell)?.cellSize() ?? image.size
            let replacement = NSTextAttachment()
            replacement.image = image
            replacement.bounds = NSRect(x: 0, y: offset, width: size.width, height: size.height)
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

/// 本文に置いた数式の添付。プレビューの表示倍率（`PreviewTypography.scaled`）で、周りの文字と同じ倍率に
/// 大きさとベースラインの下げ幅（`bounds`）を広げるため、ほかの画像の添付と区別する。
/// 画像（`MarkdownMathRenderer.render`）は描く先の解像度で描くため、広げてもぼやけない。
final class MarkdownMathAttachment: NSTextAttachment {
    init(image: NSImage, bounds: NSRect) {
        super.init(data: nil, ofType: nil)
        self.image = image
        self.bounds = bounds
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    /// 大きさとベースラインの下げ幅を `scale` 倍にした新しい添付。キャッシュした文字列と添付を共有しないよう、
    /// 自身は変えない。画像は同じものを使う。
    func scaled(by scale: CGFloat) -> MarkdownMathAttachment {
        MarkdownMathAttachment(image: image ?? NSImage(),
                               bounds: NSRect(x: bounds.minX * scale, y: bounds.minY * scale,
                                              width: bounds.width * scale, height: bounds.height * scale))
    }
}

/// 構造化プレビューの数式ブロック。文字の大きさは本文の大きさに表示倍率（`zoom`）を掛けた文字の1.2倍で、
/// 本文に置いたインライン数式（`MarkdownMathAttachment`）と同じになる。
struct MarkdownMathView: NSViewRepresentable {
    let formula: MarkdownMath.Formula
    var zoom: Double = 1

    private var fontSize: CGFloat {
        MarkdownMathRenderer.fontSize(surrounding: MarkdownRenderer.bodyFontSize * CGFloat(zoom))
    }

    func makeNSView(context: Context) -> MTMathUILabel {
        let view = MTMathUILabel(frame: .zero)
        view.setContentHuggingPriority(.required, for: .vertical)
        view.fontSize = fontSize
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
        // 表示倍率が変わったら文字の大きさを変え、SwiftUI に大きさを測り直させる。
        if view.fontSize != fontSize {
            view.fontSize = fontSize
            view.invalidateIntrinsicContentSize()
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
