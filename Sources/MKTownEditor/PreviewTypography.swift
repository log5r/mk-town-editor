import AppKit
import SwiftUI

@MainActor
enum PreviewTypography {
    /// プレビューの表示倍率 `zoom` で文字を拡大・縮小する。数式の添付（`MarkdownMathAttachment`）も同じ倍率で
    /// 大きさとベースラインの下げ幅を変え、周りの文字の1.2倍の大きさとベースラインの位置を保つ。
    /// 数式の添付は新しいものに置き換え、元の文字列（キャッシュしている場合がある）の添付は変えない。
    static func scaled(_ rendered: NSAttributedString, by zoom: Double) -> NSAttributedString {
        guard zoom != 1, rendered.length > 0 else { return rendered }
        let result = NSMutableAttributedString(attributedString: rendered)
        let whole = NSRange(location: 0, length: result.length)
        var fonts: [(NSRange, NSFont)] = []
        result.enumerateAttribute(.font, in: whole) { value, range, _ in
            if let font = value as? NSFont { fonts.append((range, font)) }
        }
        for (range, font) in fonts {
            result.addAttribute(.font,
                                value: NSFontManager.shared.convert(font, toSize: font.pointSize * zoom),
                                range: range)
        }
        var formulas: [(NSRange, MarkdownMathAttachment)] = []
        result.enumerateAttribute(.attachment, in: whole) { value, range, _ in
            if let formula = value as? MarkdownMathAttachment { formulas.append((range, formula)) }
        }
        for (range, formula) in formulas {
            result.addAttribute(.attachment, value: formula.scaled(by: CGFloat(zoom)), range: range)
        }
        return result
    }

    /// 複数のブロックを1つの `NSTextView` で描く文字列（文書全体を1つで描くプレビュー、埋め込み文書）を表示倍率で拡大・縮小し、
    /// リストの字下げも同じ倍率で整える。構造化プレビューのリスト項目（`PreviewAppKitIndent.aligned(_:indentScale:)`）と同じ扱い。
    static func scaledAndAligned(_ rendered: NSAttributedString, by zoom: Double) -> NSAttributedString {
        PreviewAppKitIndent.aligned(scaled(rendered, by: zoom), indentScale: CGFloat(zoom))
    }

    static func themed(_ rendered: NSAttributedString, kind: MarkdownBlock.Kind?,
                       theme: PreviewTheme) -> NSAttributedString {
        guard theme != .system, rendered.length > 0,
              let bodyColor = theme.bodyColor,
              let headingColor = theme.headingColor,
              let codeColor = theme.codeColor,
              let codeBackground = theme.codeBackground,
              let linkColor = theme.linkColor else { return rendered }
        let result = NSMutableAttributedString(attributedString: rendered)
        let range = NSRange(location: 0, length: result.length)
        let color: NSColor
        switch kind {
        case .heading: color = headingColor
        case .codeBlock: color = codeColor
        default: color = bodyColor
        }
        result.addAttribute(.foregroundColor, value: color, range: range)
        if kind == .codeBlock {
            // コードブロックの背景は文字ごとではなく、囲み枠（`PreviewCodeBlockFrame`）が受け持つ。
            // 字句の色は種類ごとに一度だけ求める。16進数のテーマでは、範囲ごとに解釈し直さない。
            var tokenColors: [CodeSyntaxToken: NSColor?] = [:]
            result.enumerateAttribute(.codeSyntaxToken, in: range) { value, subrange, _ in
                guard let token = (value as? String).flatMap(CodeSyntaxToken.init(rawValue:)) else { return }
                let tokenColor: NSColor?
                if let cached = tokenColors[token] {
                    tokenColor = cached
                } else {
                    tokenColor = CodeSyntaxPalette.color(for: token, theme: theme)
                    tokenColors[token] = tokenColor
                }
                if let tokenColor {
                    result.addAttribute(.foregroundColor, value: tokenColor, range: subrange)
                }
            }
        }
        result.enumerateAttribute(.link, in: range) { value, subrange, _ in
            if value != nil {
                result.addAttribute(.foregroundColor, value: linkColor, range: subrange)
            }
        }
        result.enumerateAttribute(.inlinePresentationIntent, in: range) { value, subrange, _ in
            let intent = (value as? InlinePresentationIntent) ??
                (value as? NSNumber).map { InlinePresentationIntent(rawValue: $0.uintValue) }
            if intent?.contains(.code) == true {
                result.addAttribute(.backgroundColor, value: codeBackground, range: subrange)
                result.addAttribute(.foregroundColor, value: codeColor, range: subrange)
            }
        }
        return result
    }

    /// プレビューのコードブロック本文から文字ごとの背景色を外す。
    /// 背景は囲み枠が塗るため、行の長さに沿った帯が枠の中に重ならないようにする。
    static func codeBlockBody(_ rendered: NSAttributedString) -> NSAttributedString {
        let range = NSRange(location: 0, length: rendered.length)
        var hasBackground = false
        rendered.enumerateAttribute(.backgroundColor, in: range) { value, _, stop in
            if value != nil { hasBackground = true; stop.pointee = true }
        }
        guard hasBackground else { return rendered }
        let result = NSMutableAttributedString(attributedString: rendered)
        result.removeAttribute(.backgroundColor, range: range)
        return result
    }

    static func contrastRatio(_ foreground: NSColor, _ background: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            let rgb = color.usingColorSpace(.sRGB)!
            let values = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { value -> Double in
                let component = Double(value)
                return component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * values[0] + 0.7152 * values[1] + 0.0722 * values[2]
        }
        let first = luminance(foreground)
        let second = luminance(background)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}

/// 構造化プレビュー（ブロックごとに描く `MarkdownPreview` の経路）でのリストの字下げ。
///
/// リスト項目は行頭記号と本文を1つの選択面に保つため、`PreviewAppKitIndent.aligned` で整えて `NSTextView` で描く。
/// それ以外の字下げした段落（項目の続きの段落）とタスクの本文は、字下げを除いて描き、行の余白で字下げする。
/// 文字の幅に合わせる `NSTextView`（`HoverLinkText` の `hugsContent`）に字下げを残すと、幅の計算に字下げが入るため。
enum PreviewListIndent {
    /// タスクのチェックボックスの位置。描画結果ではなく深さから求め、本文が空の項目でも兄弟とそろえる。
    static func taskCheckboxIndent(for block: MarkdownBlock) -> CGFloat {
        MarkdownRenderer.listMarkerIndent(depth: block.nestingDepth)
    }

    /// 最後の行の後ろに空くはずの間隔（行間と段落の間隔）。`NSTextView` は最後の行ではこれを高さに含めない。
    static func trailingSpacing(of text: NSAttributedString) -> CGFloat {
        guard text.length > 0, let style = text.attribute(.paragraphStyle, at: text.length - 1,
                                                          effectiveRange: nil) as? NSParagraphStyle else { return 0 }
        return style.lineSpacing + style.paragraphSpacing
    }

    /// 段落スタイルの字下げを除いた文字列。行の余白と二重にならないよう、`NSTextView` で描く場合も除く。
    static func withoutIndent(_ text: NSAttributedString) -> NSAttributedString {
        let range = NSRange(location: 0, length: text.length)
        var styles: [(NSRange, NSParagraphStyle)] = []
        text.enumerateAttribute(.paragraphStyle, in: range) { value, subrange, _ in
            guard let style = value as? NSParagraphStyle,
                  style.firstLineHeadIndent != 0 || style.headIndent != 0,
                  let copy = style.mutableCopy() as? NSMutableParagraphStyle else { return }
            copy.firstLineHeadIndent = 0
            copy.headIndent = 0
            styles.append((subrange, copy))
        }
        guard !styles.isEmpty else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        for (subrange, style) in styles {
            result.addAttribute(.paragraphStyle, value: style, range: subrange)
        }
        return result
    }
}

/// `NSTextView` で描く箇所（構造化プレビューのリスト項目、全体を1つで描くプレビュー、コールアウト、埋め込み文書）の字下げ。
///
/// `MarkdownRenderer` はリストの深さを段落スタイルで表し、引用では各行の先頭に引用記号（`│  `）を付ける。
/// そのまま `NSTextView` に渡すと、次の問題が起きる。
/// - 段落スタイルは段落の先頭の文字（引用記号）から取られるため、引用の中のリストの字下げが消える。
/// - 字下げを効かせると、引用記号ごと右へずれる。
/// - 行頭記号（`10.  ` など）が記号の列より広いと、1行目の本文だけが右へ押され、折り返した行や続きの段落とずれる。
///
/// ここでは段落ごとに、引用記号を行頭に固定し、リストの字下げをその内側に置く。行頭記号は列の中で左寄せし、
/// 列より広ければ左へはみ出させて、本文の左端を深さで決まる位置（`headIndent`）に保つ。位置は字間（`kern`）と
/// 段落スタイルで調整し、文字は変えない。範囲選択やコピーで得る文字列は描画結果と同じになる。
/// はみ出しは `maximumMarkerOverflow` までで、行頭より左にも出せない。それでも収まらない記号では本文を右へずらし、
/// 同じ項目の明示的な改行の後の行と続きの段落も同じ位置にそろえる。
@MainActor
enum PreviewAppKitIndent {
    private struct WidthKey: Hashable {
        let string: String
        let font: NSFont?
    }

    private static var widths: [WidthKey: CGFloat] = [:]

    /// 行頭記号を列より左へはみ出させる上限。これより広い記号（タスクの状態など）は本文を右へずらす。
    /// 1段浅い項目の記号より12pt以上右に置き、入れ子の深さが見分けられるようにする。
    static let maximumMarkerOverflow: CGFloat = 12

    /// - Parameter indentScale: 字下げの倍率。構造化プレビューでは文字と同じく表示倍率で広げる。
    static func aligned(_ text: NSAttributedString, indentScale: CGFloat = 1) -> NSAttributedString {
        guard needsAlignment(text) else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        let source = text.string as NSString
        // 名目上の本文の位置（`headIndent`）ごとの、直近の項目の実際の本文の位置。続きの段落をそろえるために使う。
        var itemBodies: [CGFloat: CGFloat] = [:]
        var lastItem: (first: CGFloat, head: CGFloat, body: CGFloat)?
        var location = 0
        while location < source.length {
            var start = 0, end = 0, contentsEnd = 0
            source.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd,
                                     for: NSRange(location: location, length: 0))
            location = end
            guard contentsEnd > start else { continue }
            let paragraph = NSRange(location: start, length: contentsEnd - start)
            var quoteRange = NSRange(location: start, length: 0)
            if text.attribute(.previewQuotePrefix, at: start, longestEffectiveRange: &quoteRange,
                              in: paragraph) == nil {
                quoteRange = NSRange(location: start, length: 0)
            }
            let content = NSRange(location: NSMaxRange(quoteRange), length: contentsEnd - NSMaxRange(quoteRange))
            let style = contentStyle(of: text, in: content)
            let first = (style?.firstLineHeadIndent ?? 0) * indentScale
            let head = (style?.headIndent ?? 0) * indentScale
            let lineStart: CGFloat
            let body: CGFloat
            if let marker = markerRange(in: text, within: content) {
                let width = layoutWidth(text.attributedSubstring(from:
                    NSRange(location: content.location, length: NSMaxRange(marker) - content.location)))
                (lineStart, body) = markerPlacement(first: first, head: head, markerWidth: width,
                                                    indentScale: indentScale)
                addKern(body - lineStart - width, to: result, at: NSMaxRange(marker) - 1)
                itemBodies[head] = body
                lastItem = (first, head, body)
            } else if first != head {
                // 明示的な改行の後の行。リスト項目と同じ段落スタイルを持ち、項目の本文にそろえる。
                body = lastItem.flatMap { $0.first == first && $0.head == head ? $0.body : nil } ?? head
                lineStart = body
            } else {
                body = itemBodies[head] ?? head
                lineStart = body
            }
            guard quoteRange.length > 0 || lineStart != 0 || body != 0 else { continue }
            let paragraphStyle = (style?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            if quoteRange.length > 0 {
                // 引用記号は常に行頭の左に置く。右から左の文字で始まる段落も左から右へ書き、
                // 縦線（`PreviewQuoteBars`）が深さごとに同じ位置に並び、折り返した行の本文と重ならないようにする。
                // 本文の中の右から左の文字は、その向きのまま表示される。
                paragraphStyle.baseWritingDirection = .leftToRight
                let quoteWidth = layoutWidth(text.attributedSubstring(from: quoteRange))
                addKern(lineStart, to: result, at: NSMaxRange(quoteRange) - 1)
                paragraphStyle.firstLineHeadIndent = 0
                paragraphStyle.headIndent = quoteWidth + body
            } else {
                paragraphStyle.firstLineHeadIndent = lineStart
                paragraphStyle.headIndent = body
            }
            result.addAttribute(.paragraphStyle, value: paragraphStyle,
                                range: NSRange(location: start, length: end - start))
        }
        return result
    }

    /// 行頭記号の位置と本文の左端。記号は列（`first`〜`head`）の中で左寄せし、広ければ左へはみ出させる。
    private static func markerPlacement(first: CGFloat, head: CGFloat, markerWidth: CGFloat,
                                        indentScale: CGFloat) -> (lineStart: CGFloat, body: CGFloat) {
        let lineStart = max(0, first - maximumMarkerOverflow * indentScale, min(first, head - markerWidth))
        return (lineStart, max(head, lineStart + markerWidth))
    }

    /// 1つのリスト項目の描画結果を `aligned` で描いたときの本文の左端。行頭記号がなければ `nil`。
    /// 構造化プレビューは項目の続きの段落を別の行で描くため、これで項目の本文にそろえる。
    static func itemBodyIndent(_ rendered: NSAttributedString, indentScale: CGFloat = 1) -> CGFloat? {
        let range = NSRange(location: 0, length: rendered.length)
        guard let marker = markerRange(in: rendered, within: range) else { return nil }
        let style = contentStyle(of: rendered, in: range)
        let width = layoutWidth(rendered.attributedSubstring(from:
            NSRange(location: 0, length: NSMaxRange(marker))))
        return markerPlacement(first: (style?.firstLineHeadIndent ?? 0) * indentScale,
                               head: (style?.headIndent ?? 0) * indentScale,
                               markerWidth: width, indentScale: indentScale).body
    }

    /// 字下げ・行頭記号・引用記号のいずれかを含むか。
    nonisolated static func needsAlignment(_ text: NSAttributedString) -> Bool {
        var found = false
        let range = NSRange(location: 0, length: text.length)
        text.enumerateAttributes(in: range) { attributes, _, stop in
            if attributes[.previewListMarker] != nil || attributes[.previewQuotePrefix] != nil {
                found = true
            } else if let style = attributes[.paragraphStyle] as? NSParagraphStyle,
                      style.firstLineHeadIndent != 0 || style.headIndent != 0 {
                found = true
            }
            if found { stop.pointee = true }
        }
        return found
    }

    /// 段落スタイルの字下げ（リストの深さ）を含むか。
    nonisolated static func containsListIndent(_ text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if let style = value as? NSParagraphStyle, style.firstLineHeadIndent != 0 || style.headIndent != 0 {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// 引用記号（`│  `）を含むか。
    nonisolated static func containsQuotePrefix(_ text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttribute(.previewQuotePrefix, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// 段落の本文側の段落スタイル。字下げの最も深いものを使う。
    nonisolated static func contentStyle(of text: NSAttributedString, in range: NSRange) -> NSParagraphStyle? {
        var result: NSParagraphStyle?
        guard range.length > 0 else { return nil }
        text.enumerateAttribute(.paragraphStyle, in: range) { value, _, _ in
            guard let style = value as? NSParagraphStyle else { return }
            if let current = result, style.headIndent < current.headIndent ||
                (style.headIndent == current.headIndent &&
                 style.firstLineHeadIndent <= current.firstLineHeadIndent) { return }
            result = style
        }
        return result
    }

    /// 段落の中の最初の行頭記号の範囲。
    nonisolated static func markerRange(in text: NSAttributedString, within range: NSRange) -> NSRange? {
        var found: NSRange?
        guard range.length > 0 else { return nil }
        text.enumerateAttribute(.previewListMarker, in: range) { value, subrange, stop in
            guard value != nil else { return }
            found = subrange
            stop.pointee = true
        }
        return found
    }

    /// 末尾の空白を含む、`NSTextView` に置いたときの文字列の送り幅。
    /// Core Text で直接測ると、`☐` や日本語の代替フォントの選び方が TextKit と異なり、幅がずれる。
    /// 行頭記号と引用記号は種類が少ないため、文字列とフォントごとに覚えておく。
    static func layoutWidth(_ text: NSAttributedString) -> CGFloat {
        guard text.length > 0 else { return 0 }
        let key = WidthKey(string: text.string,
                           font: text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        if let cached = widths[key] { return cached }
        // 末尾の空白の幅も含めるため、同じ属性の文字を1つ足し、その文字の位置を幅とする。
        let probe = NSMutableAttributedString(attributedString: text)
        probe.append(NSAttributedString(string: "x", attributes: text.attributes(at: text.length - 1,
                                                                                 effectiveRange: nil)))
        // 段落スタイルの字下げを幅に含めない。
        probe.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: probe.length))
        let storage = NSTextStorage(attributedString: probe)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let glyph = manager.glyphIndexForCharacter(at: text.length)
        let width = manager.location(forGlyphAt: glyph).x
        if widths.count >= 256 { widths.removeAll(keepingCapacity: true) }
        widths[key] = width
        return width
    }

    nonisolated private static func addKern(_ amount: CGFloat, to text: NSMutableAttributedString, at location: Int) {
        guard amount != 0, location >= 0, location < text.length else { return }
        let current = (text.attribute(.kern, at: location, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
        text.addAttribute(.kern, value: current + Double(amount), range: NSRange(location: location, length: 1))
    }
}

/// `NSTextView` で描く文字列の中の、引用の縦線。
///
/// `MarkdownRenderer.quote` は引用の各行の先頭に引用記号（`│  `）を文字として付ける。文字の高さは行の高さより短く、
/// そのまま描くと行間と段落の間隔で線が途切れ、破線に見える。折り返した行には記号がなく、線が欠ける。
/// `HoverPreviewTextView` は記号の縦線の文字を `NSLayoutManager` の一時属性で透明にし（`hideGlyphs`）、
/// 同じ位置に段落の高さいっぱいの線を図形で描く。文字列（`NSTextStorage`）は変えないため、位置合わせ、範囲選択、
/// コピーで得る文字列とリッチテキストの文字色は変わらない。
@MainActor
enum PreviewQuoteBars {
    static let lineWidth: CGFloat = 1
    nonisolated static let barCharacter: unichar = 0x2502

    struct Bar: Equatable {
        var rect: NSRect
        var color: NSColor
    }

    /// 段落の先頭の引用記号に含まれる縦線の文字の位置。数が引用の深さになる。
    /// 属性と文字だけから求め、レイアウトを起こさない。
    nonisolated static func barCharacters(in text: NSAttributedString, paragraph: NSRange) -> [Int] {
        guard paragraph.length > 0, NSMaxRange(paragraph) <= text.length else { return [] }
        var prefix = NSRange(location: paragraph.location, length: 0)
        guard text.attribute(.previewQuotePrefix, at: paragraph.location, longestEffectiveRange: &prefix,
                             in: paragraph) != nil else { return [] }
        let source = text.string as NSString
        return (prefix.location..<NSMaxRange(prefix)).filter { source.character(at: $0) == barCharacter }
    }

    /// 引用記号の縦線の文字を含むか。
    nonisolated static func containsBars(_ text: NSAttributedString) -> Bool {
        let source = text.string as NSString
        var found = false
        text.enumerateAttribute(.previewQuotePrefix, in: NSRange(location: 0, length: text.length)) { value, range, stop in
            guard value != nil else { return }
            if source.range(of: "\u{2502}", options: .literal, range: range).location != NSNotFound {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// 引用記号の縦線の文字を、表示のときだけ透明にする。前に付けた一時属性は外してから付け直す。
    /// 文字列の文字色は変えないため、リッチテキストのコピーでは記号がもとの色で出る。
    static func hideGlyphs(in layoutManager: NSLayoutManager) {
        guard let storage = layoutManager.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
        let source = storage.string as NSString
        storage.enumerateAttribute(.previewQuotePrefix, in: whole) { value, range, _ in
            guard value != nil else { return }
            for index in range.location..<NSMaxRange(range) where source.character(at: index) == barCharacter {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: NSColor.clear,
                                                    forCharacterRange: NSRange(location: index, length: 1))
            }
        }
    }

    /// `characterRange` にかかる段落の縦線。位置はテキストコンテナの座標系で返す。
    /// 線は段落のすべての行（折り返した行と、後ろの行間・段落の間隔を含む）を通し、続く段落の線とつながる。
    /// 引用の最後の段落では、後ろの段落の間隔へはみ出さないよう、文字のある高さで止める。
    /// 色は記号の文字色（文字列の属性）を使う。
    static func bars(in storage: NSTextStorage, layoutManager: NSLayoutManager, container: NSTextContainer,
                     characterRange: NSRange) -> [Bar] {
        guard storage.length > 0 else { return [] }
        let source = storage.string as NSString
        let clamped = NSIntersectionRange(characterRange, NSRange(location: 0, length: storage.length))
        let scope = source.paragraphRange(for: clamped)
        var result: [Bar] = []
        var location = scope.location
        while location < NSMaxRange(scope) {
            let paragraph = source.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            let characters = barCharacters(in: storage, paragraph: paragraph)
            guard !characters.isEmpty else { continue }
            // 次の段落の引用の深さだけで、線が続くかが決まる。次の段落はレイアウトしない。
            let following = location < source.length
                ? barCharacters(in: storage, paragraph: source.paragraphRange(
                    for: NSRange(location: location, length: 0))).count
                : 0
            var top = CGFloat.greatestFiniteMagnitude, bottom: CGFloat = 0, usedBottom: CGFloat = 0
            let glyphs = layoutManager.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, used, _, _, _ in
                top = min(top, rect.minY)
                bottom = max(bottom, rect.maxY)
                usedBottom = max(usedBottom, used.maxY)
            }
            guard top < bottom else { continue }
            for (depth, index) in characters.enumerated() {
                let color = storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
                let end = depth < following ? bottom : usedBottom
                result.append(Bar(rect: NSRect(x: barX(at: index, in: paragraph, layoutManager: layoutManager),
                                               y: top, width: lineWidth, height: end - top),
                                  color: color ?? .tertiaryLabelColor))
            }
        }
        return result
    }

    /// 縦線の文字の幅の中央。記号の後ろには必ず空白が続き、その文字の位置を右端とする。
    /// 引用記号を持つ段落は左から右へ書く（`PreviewAppKitIndent.aligned`）ため、深さが同じなら段落によらず同じ位置になる。
    private static func barX(at index: Int, in paragraph: NSRange, layoutManager: NSLayoutManager) -> CGFloat {
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let start = layoutManager.location(forGlyphAt: glyph).x
        let end = index + 1 < NSMaxRange(paragraph)
            ? layoutManager.location(forGlyphAt: layoutManager.glyphIndexForCharacter(at: index + 1)).x : start
        let center = line.minX + start + max(0, end - start) / 2
        return (center - lineWidth / 2).rounded()
    }
}

/// 構造化プレビューで SwiftUI の `Text` が描く補助の文字（脚注と参考文献の見出し・番号、コールアウトの記号、
/// 埋め込み文書の見出し、相互参照のラベル）の大きさ。
/// 倍率1では従来の文字スタイル（`body`・`headline` は13pt、`caption` は10pt）と同じ大きさにし、表示倍率で拡大・縮小する。
/// 文字スタイルのままでは、`MarkdownRenderer` が描く本文だけが表示倍率で変わり、隣の補助の文字が取り残される。
enum PreviewSupplementaryFont {
    static let bodySize: CGFloat = 13
    static let captionSize: CGFloat = 10

    static func body(zoom: Double) -> Font { .system(size: bodySize * zoom) }
    static func headline(zoom: Double) -> Font { .system(size: bodySize * zoom, weight: .bold) }
    static func caption(zoom: Double, weight: Font.Weight = .regular) -> Font {
        .system(size: captionSize * zoom, weight: weight)
    }
}
