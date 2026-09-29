import AppKit
import Foundation

enum MarkdownInlineLivePresentation {
    private static let headingMarker = try! NSRegularExpression(pattern: #"^[ \t]{0,3}#{1,6}(?=[ \t])"#)

    static func markerRanges(in text: String, spans: [MarkdownSyntaxSpan],
                             analysis: MarkdownAnalysis? = nil) -> [NSRange] {
        let source = text as NSString
        let codeBlocks = (analysis ?? MarkdownAnalysis(text)).blocks.filter { $0.kind == .codeBlock }
            .map(\.sourceRange)
        func inCodeBlock(_ range: NSRange) -> Bool {
            codeBlocks.contains { NSIntersectionRange($0, range).length > 0 }
        }
        var ranges = spans.compactMap { span -> NSRange? in
            switch span.role {
            case .marker, .quoteMarker, .listMarker, .taskMarker, .tableMarker:
                return span.range
            default:
                return nil
            }
        }
        for span in spans where span.role == .heading {
            let line = source.lineRange(for: NSRange(location: span.range.location, length: 0))
            let content = source.substring(with: line)
            let length = (content as NSString).length
            if let match = headingMarker.firstMatch(in: content,
                                                    range: NSRange(location: 0, length: length)) {
                ranges.append(NSRange(location: line.location + match.range.location,
                                      length: match.range.length))
            }
        }
        let codeSpans = MarkdownInlineSyntax.codeSpanRanges(in: text)
            .filter { !inCodeBlock($0) }
        for code in codeSpans where code.length >= 2 {
            var width = 0
            while width < code.length && source.character(at: code.location + width) == 96 {
                width += 1
            }
            guard width > 0, width * 2 <= code.length else { continue }
            ranges.append(NSRange(location: code.location, length: width))
            ranges.append(NSRange(location: NSMaxRange(code) - width, length: width))
        }
        for link in MarkdownLinkSyntax.inlineLinks(in: text)
        where !inCodeBlock(link.range) &&
              !codeSpans.contains(where: { NSIntersectionRange($0, link.range).length > 0 }) {
            let before = NSRange(location: link.range.location,
                                 length: link.labelRange.location - link.range.location)
            let after = NSRange(location: NSMaxRange(link.labelRange),
                                length: NSMaxRange(link.range) - NSMaxRange(link.labelRange))
            ranges.append(contentsOf: [before, after])
        }
        return Array(Set(ranges.filter { $0.length > 0 && $0.location >= 0 &&
            NSMaxRange($0) <= source.length }))
            .sorted { $0.location < $1.location }
    }

    static func activeLines(in text: String, selections: [NSRange]) -> [NSRange] {
        let source = text as NSString
        return selections.compactMap { selection in
            guard selection.location >= 0, NSMaxRange(selection) <= source.length else { return nil }
            return source.lineRange(for: selection)
        }
    }
}

@MainActor
final class MarkdownInlineLiveDisplay {
    private struct Marker {
        let range: NSRange
        let baseColor: NSColor?
    }

    private let markers: [Marker]
    private var previousActive: [NSRange] = []

    init(textView: NSTextView, ranges: [NSRange]) {
        guard let manager = textView.layoutManager else {
            markers = []
            return
        }
        markers = ranges.map { range in
            Marker(range: range,
                   baseColor: manager.temporaryAttribute(.foregroundColor,
                                                         atCharacterIndex: range.location,
                                                         effectiveRange: nil) as? NSColor)
        }
    }

    func update(in textView: NSTextView, activeLines: [NSRange], force: Bool = false) {
        guard !textView.hasMarkedText(), let manager = textView.layoutManager else { return }
        for marker in markers {
            let wasActive = previousActive.contains {
                NSIntersectionRange($0, marker.range).length > 0
            }
            let isActive = activeLines.contains {
                NSIntersectionRange($0, marker.range).length > 0
            }
            guard force || wasActive != isActive else { continue }
            if isActive {
                if let color = marker.baseColor {
                    manager.addTemporaryAttribute(.foregroundColor, value: color,
                                                  forCharacterRange: marker.range)
                } else {
                    manager.removeTemporaryAttribute(.foregroundColor,
                                                     forCharacterRange: marker.range)
                }
            } else {
                manager.addTemporaryAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor,
                                              forCharacterRange: marker.range)
            }
        }
        previousActive = activeLines
    }
}
