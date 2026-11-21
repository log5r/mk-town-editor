import AppKit

@MainActor
enum PreviewTypography {
    static func scaled(_ rendered: NSAttributedString, by zoom: Double) -> NSAttributedString {
        guard zoom != 1, rendered.length > 0 else { return rendered }
        let result = NSMutableAttributedString(attributedString: rendered)
        var fonts: [(NSRange, NSFont)] = []
        result.enumerateAttribute(.font, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            if let font = value as? NSFont { fonts.append((range, font)) }
        }
        for (range, font) in fonts {
            result.addAttribute(.font,
                                value: NSFontManager.shared.convert(font, toSize: font.pointSize * zoom),
                                range: range)
        }
        return result
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

/// 1ブロックの描画結果を、SwiftUI で配置できる形に分けたもの。
///
/// SwiftUI の `Text` は `NSParagraphStyle` の字下げ（`firstLineHeadIndent`・`headIndent`）を無視する。
/// 描画結果をそのまま `Text` に渡すと、入れ子のリストがすべて同じ位置に並ぶ。
/// 構造化プレビューはブロックごとに字下げを文字列から取り出し、行頭の余白と行頭記号の列で表す
/// （`PreviewIndentedLayout`）。AppKit の `NSTextView` で描く本文にも字下げを残さず、余白と二重にならないようにする。
/// 複数のブロックを1つの文字列で描く箇所は、範囲選択とコピーを保つため `PreviewAppKitIndent` で `NSTextView` に描く。
struct PreviewIndentedText: Equatable {
    /// 行頭記号を置く位置。
    let markerIndent: CGFloat
    /// 本文の左端。折り返した行もここから始まる。
    let bodyIndent: CGFloat
    /// リストの行頭記号（`•  `、`1.  ` など）。字下げは取り除いてある。
    let marker: NSAttributedString?
    /// 字下げを取り除いた本文。
    let body: NSAttributedString

    /// 行頭記号の列の幅。記号がこれより広い場合は左へはみ出させ、本文の左端は動かさない。
    var markerWidth: CGFloat { max(0, bodyIndent - markerIndent) }

    /// 行頭記号と本文をつないだ文字列。
    var string: String { (marker?.string ?? "") + body.string }

    /// 1ブロックの描画結果を、字下げと行頭記号と本文に分ける。
    static func make(_ rendered: NSAttributedString) -> PreviewIndentedText {
        guard rendered.length > 0 else {
            return PreviewIndentedText(markerIndent: 0, bodyIndent: 0, marker: nil, body: rendered)
        }
        let style = PreviewAppKitIndent.contentStyle(of: rendered,
                                                     in: NSRange(location: 0, length: rendered.length))
        let first = style?.firstLineHeadIndent ?? 0
        let head = style?.headIndent ?? 0
        guard let markerRange = PreviewAppKitIndent.markerRange(in: rendered,
                                                                 within: NSRange(location: 0, length: rendered.length)) else {
            return PreviewIndentedText(markerIndent: first, bodyIndent: head, marker: nil,
                                       body: withoutIndent(rendered))
        }
        let markerEnd = NSMaxRange(markerRange)
        return PreviewIndentedText(
            markerIndent: first, bodyIndent: head,
            marker: withoutIndent(rendered.attributedSubstring(from: NSRange(location: 0, length: markerEnd))),
            body: withoutIndent(rendered.attributedSubstring(from:
                NSRange(location: markerEnd, length: rendered.length - markerEnd))))
    }

    /// タスクのチェックボックスの位置。描画結果ではなく深さから求め、本文が空の項目でも兄弟とそろえる。
    static func taskCheckboxIndent(for block: MarkdownBlock) -> CGFloat {
        MarkdownRenderer.listMarkerIndent(depth: block.nestingDepth)
    }

    private static func withoutIndent(_ text: NSAttributedString) -> NSAttributedString {
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

/// 複数のブロックを1つの `NSTextView` で描く箇所（全体を1つで描くプレビュー、コールアウト、埋め込み文書）の字下げ。
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

    static func aligned(_ text: NSAttributedString) -> NSAttributedString {
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
            let first = style?.firstLineHeadIndent ?? 0
            let head = style?.headIndent ?? 0
            let lineStart: CGFloat
            let body: CGFloat
            if let marker = markerRange(in: text, within: content) {
                let width = layoutWidth(text.attributedSubstring(from:
                    NSRange(location: content.location, length: NSMaxRange(marker) - content.location)))
                lineStart = max(0, first - maximumMarkerOverflow, min(first, head - width))
                body = max(head, lineStart + width)
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

    /// 段落スタイルの字下げ（リストの深さ）を含むか。`PreviewIndentedText.make` で分けた記号と本文は含まない。
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
