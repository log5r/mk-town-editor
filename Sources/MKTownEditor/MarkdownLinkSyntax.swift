import Foundation

struct MarkdownLinkDraft: Identifiable {
    let id = UUID()
    let range: NSRange
    let originalDocumentText: String
    let originalText: String
    let originalLabel: String?
    let rawLabel: String?
    let isExisting: Bool
    var label: String
    var destination: String
    var title: String
}

struct MarkdownImageDraft: Identifiable {
    let id = UUID()
    let range: NSRange
    let originalDocumentText: String
    let originalText: String
    let alt: String
}

struct MarkdownInlineLink: Equatable {
    let range: NSRange
    let destination: String
    let isImage: Bool
}

enum MarkdownLinkSyntax {
    static func inlineLinks(in text: String) -> [MarkdownInlineLink] {
        let source = text as NSString
        var result: [MarkdownInlineLink] = []
        var cursor = 0
        while cursor < source.length {
            guard source.character(at: cursor) == 91, !isEscaped(source, at: cursor),
                  let parsed = parseLink(source, opening: cursor) else {
                cursor += 1
                continue
            }
            let isImage = cursor > 0 && source.character(at: cursor - 1) == 33 &&
                !isEscaped(source, at: cursor - 1)
            let range = isImage
                ? NSRange(location: cursor - 1, length: parsed.range.length + 1) : parsed.range
            result.append(MarkdownInlineLink(range: range,
                                             destination: unescape(parsed.destination),
                                             isImage: isImage))
            cursor = NSMaxRange(parsed.range)
        }
        return result
    }

    static func imageDraft(in text: String, selection: NSRange) -> MarkdownImageDraft {
        let source = text as NSString
        let location = min(max(selection.location, 0), source.length)
        let range = NSRange(location: location,
                            length: min(max(selection.length, 0), source.length - location))
        let selected = source.substring(with: range)
        return MarkdownImageDraft(range: range, originalDocumentText: text,
                                  originalText: selected, alt: selected)
    }

    static func imageEdit(in text: String, draft: MarkdownImageDraft,
                          alt: String, destination: String, title: String) -> MarkdownEdit? {
        let source = text as NSString
        guard text == draft.originalDocumentText,
              draft.range.location <= source.length,
              NSMaxRange(draft.range) <= source.length,
              source.substring(with: draft.range) == draft.originalText,
              !alt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let image = makeImage(alt: alt, destination: destination, title: title)
        return MarkdownEdit(range: draft.range, replacement: image,
                            selection: NSRange(location: draft.range.location + (image as NSString).length, length: 0))
    }

    static func draft(in text: String, selection: NSRange) -> MarkdownLinkDraft {
        let source = text as NSString
        let location = min(max(selection.location, 0), source.length)
        let safeSelection = NSRange(location: location,
                                    length: min(max(selection.length, 0), source.length - location))
        if let link = existingLink(in: text, selection: safeSelection) {
            return link
        }
        let selected = source.substring(with: safeSelection)
        return MarkdownLinkDraft(range: safeSelection, originalDocumentText: text, originalText: selected,
                                 originalLabel: nil, rawLabel: nil, isExisting: false,
                                 label: selected.isEmpty ? "リンク" : selected,
                                 destination: "", title: "")
    }

    static func edit(in text: String, draft: MarkdownLinkDraft,
                     label: String, destination: String, title: String) -> MarkdownEdit? {
        let source = text as NSString
        guard text == draft.originalDocumentText,
              draft.range.location <= source.length,
              NSMaxRange(draft.range) <= source.length,
              source.substring(with: draft.range) == draft.originalText,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let link = makeLink(label: label, destination: destination, title: title,
                            rawLabel: label == draft.originalLabel ? draft.rawLabel : nil)
        return MarkdownEdit(range: draft.range, replacement: link,
                            selection: NSRange(location: draft.range.location + (link as NSString).length, length: 0))
    }

    static func referenceEdit(in text: String, draft: MarkdownLinkDraft,
                              label: String, referenceID: String) -> MarkdownEdit? {
        let source = text as NSString
        guard text == draft.originalDocumentText,
              draft.range.location <= source.length,
              NSMaxRange(draft.range) <= source.length,
              source.substring(with: draft.range) == draft.originalText,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !referenceID.isEmpty else { return nil }
        let visible = label == draft.originalLabel ? draft.rawLabel ?? escapeLabel(label) : escapeLabel(label)
        let link = "[\(visible)][\(escapeLabel(referenceID))]"
        return MarkdownEdit(range: draft.range, replacement: link,
                            selection: NSRange(location: draft.range.location + (link as NSString).length, length: 0))
    }

    static func makeLink(label: String, destination: String, title: String = "",
                         rawLabel: String? = nil) -> String {
        makeInline(prefix: "", label: label, destination: destination, title: title,
                   rawLabel: rawLabel)
    }

    static func makeImage(alt: String, destination: String, title: String = "") -> String {
        makeInline(prefix: "!", label: alt, destination: destination, title: title)
    }

    private static func makeInline(prefix: String, label: String, destination: String,
                                   title: String, rawLabel: String? = nil) -> String {
        let linkLabel = rawLabel ?? escapeLabel(label)
        let escapedDestination = escapeDestination(destination)
        let titlePart = title.isEmpty ? "" : " \"\(escapeTitle(title))\""
        return "\(prefix)[\(linkLabel)](\(escapedDestination)\(titlePart))"
    }

    static func escapeDestination(_ destination: String) -> String {
        var result = ""
        for scalar in destination.unicodeScalars {
            switch scalar {
            case "(", ")", "\\":
                result += "\\" + String(scalar)
            default:
                if CharacterSet.whitespacesAndNewlines.contains(scalar) ||
                    CharacterSet.controlCharacters.contains(scalar) || scalar == "<" || scalar == ">" {
                    result += scalar.utf8.map { String(format: "%%%02X", $0) }.joined()
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    private static func escapeLabel(_ label: String) -> String {
        var result = ""
        for character in label {
            if "\\[]*_`<>".contains(character) { result += "\\" }
            result.append(character)
        }
        return result
    }

    private static func escapeTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static func existingLink(in text: String, selection: NSRange) -> MarkdownLinkDraft? {
        let source = text as NSString
        let codeSpans = MarkdownInlineSyntax.codeSpanRanges(in: text)
        var cursor = 0
        var found: MarkdownLinkDraft?
        while cursor < source.length {
            defer { cursor += 1 }
            guard source.character(at: cursor) == 91,
                  !isEscaped(source, at: cursor),
                  !(cursor > 0 && source.character(at: cursor - 1) == 33 &&
                    !isEscaped(source, at: cursor - 1)),
                  !codeSpans.contains(where: { NSLocationInRange(cursor, $0) }),
                  let parsed = parseLink(source, opening: cursor) else { continue }
            let range = parsed.range
            let containsSelection = selection.length == 0
                ? selection.location >= range.location && selection.location < NSMaxRange(range)
                : selection.location >= range.location && NSMaxRange(selection) <= NSMaxRange(range)
            guard containsSelection else { continue }
            let rawLabel = source.substring(with: parsed.labelRange)
            let draft = MarkdownLinkDraft(
                range: range, originalDocumentText: text, originalText: source.substring(with: range),
                originalLabel: unescape(rawLabel), rawLabel: rawLabel, isExisting: true,
                label: unescape(rawLabel), destination: unescape(parsed.destination)
                    .replacingOccurrences(of: "%20", with: " ", options: .caseInsensitive),
                title: unescape(parsed.title)
            )
            if found == nil || range.length < found!.range.length { found = draft }
        }
        return found
    }

    private struct ParsedLink {
        let range: NSRange
        let labelRange: NSRange
        let destination: String
        let title: String
    }

    private static func parseLink(_ source: NSString, opening: Int) -> ParsedLink? {
        var cursor = opening + 1
        var depth = 1
        while cursor < source.length && depth > 0 {
            if isEscaped(source, at: cursor) { cursor += 1; continue }
            switch source.character(at: cursor) {
            case 91: depth += 1
            case 93: depth -= 1
            default: break
            }
            cursor += 1
        }
        guard depth == 0, cursor < source.length, source.character(at: cursor) == 40 else { return nil }
        let labelRange = NSRange(location: opening + 1, length: cursor - opening - 2)
        cursor += 1
        skipSpaces(source, cursor: &cursor)
        let destination: String
        if cursor < source.length && source.character(at: cursor) == 60 {
            cursor += 1
            let start = cursor
            while cursor < source.length && (source.character(at: cursor) != 62 || isEscaped(source, at: cursor)) {
                guard source.character(at: cursor) != 10 && source.character(at: cursor) != 13 else { return nil }
                cursor += 1
            }
            guard cursor < source.length else { return nil }
            destination = source.substring(with: NSRange(location: start, length: cursor - start))
            cursor += 1
        } else {
            let start = cursor
            var parentheses = 0
            while cursor < source.length {
                let character = source.character(at: cursor)
                if isEscaped(source, at: cursor) { cursor += 1; continue }
                if character == 40 { parentheses += 1 }
                if character == 41 {
                    if parentheses == 0 { break }
                    parentheses -= 1
                }
                if character == 32 || character == 9 || character == 10 || character == 13 { break }
                cursor += 1
            }
            destination = source.substring(with: NSRange(location: start, length: cursor - start))
        }
        let beforeSpaces = cursor
        skipSpaces(source, cursor: &cursor)
        var title = ""
        if cursor > beforeSpaces && cursor < source.length {
            let delimiter = source.character(at: cursor)
            if delimiter == 34 || delimiter == 39 || delimiter == 40 {
                cursor += 1
                let start = cursor
                let closing: unichar = delimiter == 40 ? 41 : delimiter
                while cursor < source.length && (source.character(at: cursor) != closing || isEscaped(source, at: cursor)) {
                    cursor += 1
                }
                guard cursor < source.length else { return nil }
                title = source.substring(with: NSRange(location: start, length: cursor - start))
                cursor += 1
                skipSpaces(source, cursor: &cursor)
            }
        }
        guard cursor < source.length && source.character(at: cursor) == 41 else { return nil }
        return ParsedLink(range: NSRange(location: opening, length: cursor - opening + 1),
                          labelRange: labelRange, destination: destination, title: title)
    }

    private static func skipSpaces(_ source: NSString, cursor: inout Int) {
        while cursor < source.length && (source.character(at: cursor) == 32 || source.character(at: cursor) == 9) {
            cursor += 1
        }
    }

    private static func isEscaped(_ source: NSString, at location: Int) -> Bool {
        var cursor = location - 1
        while cursor >= 0 && source.character(at: cursor) == 92 { cursor -= 1 }
        return (location - cursor - 1) % 2 == 1
    }

    private static func unescape(_ text: String) -> String {
        let source = text as NSString
        var result = ""
        var cursor = 0
        while cursor < source.length {
            if source.character(at: cursor) == 92 && cursor + 1 < source.length &&
                isASCIIPunctuation(source.character(at: cursor + 1)) {
                cursor += 1
            }
            let range = source.rangeOfComposedCharacterSequence(at: cursor)
            result += source.substring(with: range)
            cursor = NSMaxRange(range)
        }
        return result
    }

    private static func isASCIIPunctuation(_ value: unichar) -> Bool {
        (33...47).contains(value) || (58...64).contains(value) ||
            (91...96).contains(value) || (123...126).contains(value)
    }
}
