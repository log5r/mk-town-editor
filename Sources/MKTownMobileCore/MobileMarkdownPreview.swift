import Foundation
#if SWIFT_PACKAGE
import MKTownMarkdownCore
#endif

/// Foundation parses Markdown; the UI supplies standard SwiftUI text styles for block semantics.
/// This model never rewrites the source document and has no dependency on AppKit or UIKit.
struct MobileMarkdownPreview: Sendable {
    struct Block: Identifiable, Sendable {
        let id: Int
        var text: AttributedString
        let headingLevel: Int?
        let isCode: Bool
        let isQuote: Bool
        let listMarker: String?
        let indentation: Int
        let isRule: Bool
    }

    let blocks: [Block]
    let frontMatter: MarkdownFrontMatter?
    let frontMatterRows: [FrontMatterPreviewProperties.Row]?

    init(_ source: String) {
        let frontMatter = MarkdownFrontMatter(source: source)
        self.frontMatter = frontMatter
        frontMatterRows = frontMatter.flatMap { FrontMatterPreviewProperties.rows(in: $0) }
        let body = frontMatter.map { (source as NSString).substring(from: NSMaxRange($0.sourceRange)) } ?? source
        guard let parsed = try? AttributedString(markdown: body, options: .init(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)) else {
            blocks = [Block(id: 0, text: AttributedString(body), headingLevel: nil,
                            isCode: false, isQuote: false, listMarker: nil,
                            indentation: 0, isRule: false)]
            return
        }
        var result: [Block] = []
        var markedListItems = Set<Int>()
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let identity = components.first?.identity ?? 0
            var text = AttributedString(parsed[run.range])
            // SwiftUI handles inline attributes, while the enclosing view handles block layout.
            text.presentationIntent = nil
            if result.last?.id == identity {
                result[result.count - 1].text.append(text)
                continue
            }
            var heading: Int?
            var code = false
            var quote = false
            var ordinal: Int?
            var listItemID: Int?
            var ordered: Bool?
            var depth = 0
            var rule = false
            for component in components {
                switch component.kind {
                case .header(let level): heading = level
                case .codeBlock: code = true
                case .blockQuote: quote = true
                case .listItem(let value):
                    if ordinal == nil { ordinal = value; listItemID = component.identity }
                case .orderedList: if ordered == nil { ordered = true }; depth += 1
                case .unorderedList: if ordered == nil { ordered = false }; depth += 1
                case .thematicBreak: rule = true
                default: break
                }
            }
            let isFirstParagraph = listItemID.map { markedListItems.insert($0).inserted } ?? false
            let marker = isFirstParagraph ? ordinal.map { ordered == true ? "\($0)." : "•" } : nil
            result.append(Block(id: identity, text: text, headingLevel: heading,
                                isCode: code, isQuote: quote, listMarker: marker,
                                indentation: max(0, depth - 1), isRule: rule))
        }
        blocks = result
    }
}
