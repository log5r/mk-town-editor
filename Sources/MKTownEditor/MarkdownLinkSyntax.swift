import AppKit
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
    let labelRange: NSRange
    let destinationRange: NSRange
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
                                             labelRange: parsed.labelRange,
                                             destinationRange: parsed.destinationRange,
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
                          alt: String, destination: String, title: String,
                          width: Int? = nil) -> MarkdownEdit? {
        let source = text as NSString
        guard text == draft.originalDocumentText,
              draft.range.location <= source.length,
              NSMaxRange(draft.range) <= source.length,
              source.substring(with: draft.range) == draft.originalText,
              !alt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              width.map({ (1...9999).contains($0) }) ?? true else { return nil }
        let image = makeImage(alt: alt, destination: destination, title: title) +
            (width.map { "{width=\($0)}" } ?? "")
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
                                 label: selected.isEmpty ? String(localized: "リンク") : selected,
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

    static func referenceTarget(destination: String, title: String) -> String {
        let titlePart = title.isEmpty ? "" : " \"\(escapeTitle(title))\""
        return escapeDestination(destination) + titlePart
    }

    static func unescapedLabel(_ label: String) -> String { unescape(label) }

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
        let destinationRange: NSRange
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
        let destinationRange: NSRange
        if cursor < source.length && source.character(at: cursor) == 60 {
            cursor += 1
            let start = cursor
            while cursor < source.length && (source.character(at: cursor) != 62 || isEscaped(source, at: cursor)) {
                guard source.character(at: cursor) != 10 && source.character(at: cursor) != 13 else { return nil }
                cursor += 1
            }
            guard cursor < source.length else { return nil }
            destinationRange = NSRange(location: start, length: cursor - start)
            destination = source.substring(with: destinationRange)
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
            destinationRange = NSRange(location: start, length: cursor - start)
            destination = source.substring(with: destinationRange)
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
                          labelRange: labelRange, destinationRange: destinationRange,
                          destination: destination, title: title)
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

enum MarkdownReferenceConversion {
    private static let reference = try! NSRegularExpression(
        pattern: #"(?<!!)\[((?:\\.|[^\\\]\n])+)\](?:\[((?:\\.|[^\\\]\n])*)\])?"#)

    static func edit(in text: String, selection: NSRange, analysis: MarkdownAnalysis? = nil) -> MarkdownEdit? {
        let source = text as NSString
        guard selection.location >= 0, NSMaxRange(selection) <= source.length else { return nil }
        let analysis = analysis ?? MarkdownAnalysis(text)
        let code = analysis.blocks.filter { $0.kind == .codeBlock }.map(\.sourceRange) +
            MarkdownInlineSyntax.codeSpanRanges(in: text)
        func contains(_ range: NSRange) -> Bool {
            selection.length == 0
                ? selection.location >= range.location && selection.location < NSMaxRange(range)
                : selection.location >= range.location && NSMaxRange(selection) <= NSMaxRange(range)
        }
        if let link = MarkdownLinkSyntax.inlineLinks(in: text).first(where: { link in
            !link.isImage && contains(link.range) &&
                !code.contains(where: { NSLocationInRange(link.range.location, $0) })
        }) {
            let draft = MarkdownLinkSyntax.draft(in: text, selection: selection)
            guard draft.isExisting, draft.range == link.range else { return nil }
            let matching = analysis.references.keys.sorted().first { key in
                guard let value = analysis.references[key] else { return false }
                return value.destination.replacingOccurrences(of: "%20", with: " ") == draft.destination &&
                    (value.title ?? "") == draft.title
            }
            var id = matching ?? draft.label
                .replacingOccurrences(of: "[", with: "-")
                .replacingOccurrences(of: "]", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty { id = "link" }
            let needsDefinition = matching == nil
            if needsDefinition {
                let base = id
                var suffix = 2
                while analysis.references[MarkdownAnalysis.normalizedReferenceLabel(id)] != nil {
                    id = "\(base)-\(suffix)"
                    suffix += 1
                }
            }
            let newLink = "[\(draft.rawLabel ?? draft.label)][\(id)]"
            if !needsDefinition {
                return MarkdownEdit(range: link.range, replacement: newLink,
                    selection: NSRange(location: link.range.location + (newLink as NSString).length,
                                       length: 0))
            }
            let suffix = source.substring(from: NSMaxRange(link.range))
            let separator = text.hasSuffix("\n") ? "\n" : "\n\n"
            let target = MarkdownLinkSyntax.referenceTarget(
                destination: draft.destination, title: draft.title)
            let definition = "[\(id)]: \(target)"
            return MarkdownEdit(range: NSRange(location: link.range.location,
                                               length: source.length - link.range.location),
                replacement: newLink + suffix + separator + definition,
                selection: NSRange(location: link.range.location + (newLink as NSString).length,
                                   length: 0))
        }
        for match in reference.matches(in: text,
            range: NSRange(location: 0, length: source.length)) where contains(match.range) {
            if code.contains(where: { NSLocationInRange(match.range.location, $0) }) { continue }
            let end = NSMaxRange(match.range)
            if end < source.length && [40, 58].contains(source.character(at: end)) { continue }
            let label = source.substring(with: match.range(at: 1))
            let explicit = match.range(at: 2)
            let id = explicit.location == NSNotFound || explicit.length == 0
                ? label : source.substring(with: explicit)
            guard let definition = analysis.references[MarkdownAnalysis.normalizedReferenceLabel(id)]
            else { continue }
            let newLink = MarkdownLinkSyntax.makeLink(label: MarkdownLinkSyntax.unescapedLabel(label),
                destination: definition.destination, title: definition.title ?? "")
            return MarkdownEdit(range: match.range, replacement: newLink,
                selection: NSRange(location: match.range.location + (newLink as NSString).length,
                                   length: 0))
        }
        return nil
    }
}

@MainActor
enum MarkdownAutolink {
    private static let urlPattern = try! NSRegularExpression(
        pattern: #"(?:https?://|www\.)[^\s<>]+"#, options: [.caseInsensitive]
    )
    private static let emailPattern = try! NSRegularExpression(
        pattern: #"[A-Z0-9._+\-]+@[A-Z0-9_\-]+(?:\.[A-Z0-9_\-]+)+"#,
        options: [.caseInsensitive]
    )

    static func apply(to value: NSMutableAttributedString) {
        let source = value.string as NSString
        let full = NSRange(location: 0, length: source.length)
        var found: [(range: NSRange, url: URL)] = []
        for match in urlPattern.matches(in: value.string, range: full) {
            guard allowedStart(match.range.location, in: source) else { continue }
            let range = trimmedRange(match.range, in: source)
            guard range.length > 0, !hasExistingLinkOrCode(in: range, value: value) else { continue }
            let candidate = source.substring(with: range)
            let urlText = candidate.lowercased().hasPrefix("www.") ? "http://" + candidate : candidate
            guard let url = URL(string: urlText), let host = url.host,
                  validDomain(host) else { continue }
            found.append((range, url))
        }
        for match in emailPattern.matches(in: value.string, range: full) {
            let prefix = match.range.location >= 7
                ? source.substring(with: NSRange(location: match.range.location - 7, length: 7)) : ""
            let range = prefix.lowercased() == "mailto:"
                ? NSRange(location: match.range.location - 7, length: match.range.length + 7)
                : match.range
            guard !found.contains(where: { NSIntersectionRange($0.range, range).length > 0 }),
                  !hasExistingLinkOrCode(in: range, value: value) else { continue }
            let email = source.substring(with: match.range)
            let domain = String(email.split(separator: "@").last ?? "")
            guard validEmailDomain(domain), let url = URL(string: "mailto:" + email) else { continue }
            found.append((range, url))
        }
        for item in found {
            value.addAttribute(.link, value: item.url, range: item.range)
        }
    }

    private static func allowedStart(_ location: Int, in source: NSString) -> Bool {
        guard location > 0 else { return true }
        let previous = source.character(at: location - 1)
        return (UnicodeScalar(previous).map(CharacterSet.whitespacesAndNewlines.contains) ?? false) ||
            [42, 95, 126, 40].contains(Int(previous))
    }

    private static func trimmedRange(_ original: NSRange, in source: NSString) -> NSRange {
        var length = original.length
        while length > 0 {
            let candidate = source.substring(with: NSRange(location: original.location, length: length))
            guard let last = candidate.last else { break }
            if "?!.,:*_~;".contains(last) {
                length -= String(last).utf16.count
            } else if last == ")" && candidate.filter({ $0 == ")" }).count >
                        candidate.filter({ $0 == "(" }).count {
                length -= 1
            } else { break }
        }
        return NSRange(location: original.location, length: length)
    }

    private static func validDomain(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }),
              parts.suffix(2).allSatisfy({ !$0.contains("_") }) else { return false }
        return parts.allSatisfy { part in
            part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    private static func validEmailDomain(_ domain: String) -> Bool {
        let parts = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }),
              let last = domain.last, last != "-", last != "_" else { return false }
        return parts.allSatisfy { part in
            part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    private static func hasExistingLinkOrCode(in range: NSRange,
                                              value: NSAttributedString) -> Bool {
        var excluded = false
        value.enumerateAttributes(in: range) { attributes, _, stop in
            let intent = (attributes[.inlinePresentationIntent] as? InlinePresentationIntent)
                ?? (attributes[.inlinePresentationIntent] as? NSNumber)
                    .map { InlinePresentationIntent(rawValue: $0.uintValue) }
            if attributes[.link] != nil || attributes[.imageURL] != nil ||
                intent?.contains(.code) == true {
                excluded = true
                stop.pointee = true
            }
        }
        return excluded
    }
}
