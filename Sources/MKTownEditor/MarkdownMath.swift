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
    static func label(_ formula: MarkdownMath.Formula, fontSize: CGFloat = 16) -> MTMathUILabel? {
        let label = MTMathUILabel(frame: .zero)
        label.latex = formula.latex
        guard label.error == nil else { return nil }
        label.fontSize = fontSize
        label.textColor = .labelColor
        label.labelMode = formula.display ? .display : .text
        return label
    }

    static func image(_ formula: MarkdownMath.Formula, fontSize: CGFloat = 16) -> NSImage? {
        guard let label = label(formula, fontSize: fontSize) else { return nil }
        let size = label.fittingSize
        guard size.width > 0, size.height > 0, size.width < 4000, size.height < 4000 else { return nil }
        label.frame = NSRect(origin: .zero, size: size)
        label.layoutSubtreeIfNeeded()
        guard let rep = label.bitmapImageRepForCachingDisplay(in: label.bounds) else { return nil }
        label.cacheDisplay(in: label.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    static func attachment(_ formula: MarkdownMath.Formula, fontSize: CGFloat = 16) -> NSAttributedString? {
        guard let image = image(formula, fontSize: fontSize) else { return nil }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: -2, width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }

    static func htmlImage(_ formula: MarkdownMath.Formula, fontSize: CGFloat = 16) -> String? {
        guard let image = image(formula, fontSize: fontSize),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            return nil
        }
        let alt = formula.latex.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let style = formula.display ? "display:block;margin:1em auto" : "vertical-align:middle"
        return "<img class=\"math\" src=\"data:image/png;base64,\(png.base64EncodedString())\" alt=\"\(alt)\" style=\"\(style)\" width=\"\(Int(ceil(image.size.width)))\" height=\"\(Int(ceil(image.size.height)))\">"
    }
}

struct MarkdownMathView: NSViewRepresentable {
    let formula: MarkdownMath.Formula

    func makeNSView(context: Context) -> MTMathUILabel {
        let view = MTMathUILabel(frame: .zero)
        view.setContentHuggingPriority(.required, for: .vertical)
        view.fontSize = 21
        view.labelMode = .display
        view.textColor = .labelColor
        return view
    }

    func updateNSView(_ view: MTMathUILabel, context: Context) {
        // latexの再設定は再解析を伴うため、式が変わった時だけ行う。
        guard view.latex != formula.latex else { return }
        view.latex = formula.latex
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MTMathUILabel, context: Context) -> CGSize? {
        nsView.fittingSize
    }
}
