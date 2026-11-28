import Foundation

enum EditorTextTransformation: String, CaseIterable, Sendable {
    case uppercase
    case lowercase
    case capitalized
    case fullwidthToHalfwidth
    case halfwidthToFullwidth
    case hiraganaToKatakana
    case katakanaToHiragana
    case nfc
    case nfd
    case nfkc
    case nfkd

    struct WidthCharacters: OptionSet, Sendable {
        let rawValue: Int

        static let alphanumeric = Self(rawValue: 1 << 0)
        static let symbols = Self(rawValue: 1 << 1)
        static let kana = Self(rawValue: 1 << 2)
        static let all: Self = [.alphanumeric, .symbols, .kana]
    }

    private static let linkDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let angleURL = try! NSRegularExpression(
        pattern: #"<[A-Za-z][A-Za-z0-9+.-]{1,31}:[^\s<>]+>"#
    )
    private static let referenceLink = try! NSRegularExpression(
        pattern: #"!?(?:\[((?:\\.|[^\\\]\n])+)\])(?:\[((?:\\.|[^\\\]\n])*)\])?"#
    )

    func replacement(in source: String, range: NSRange, widthCharacters: WidthCharacters = .all,
                     protectsMarkdown: Bool = true, dialect: MarkdownDialect = .extended) -> String? {
        let text = source as NSString
        guard range.location >= 0, range.location < text.length, range.length > 0,
              range.length <= text.length - range.location,
              Self.isScalarBoundary(range.location, in: text),
              Self.isScalarBoundary(NSMaxRange(range), in: text) else { return nil }
        let original = text.substring(with: range)
        let result = protectsMarkdown
            ? replacingUnprotectedText(in: source, text: text, range: range,
                                       widthCharacters: widthCharacters, dialect: dialect)
            : transform(original, widthCharacters: widthCharacters)
        // Swift String equality treats both canonical forms as equal.
        return result.utf16.elementsEqual(original.utf16) ? nil : result
    }

    private static func isScalarBoundary(_ offset: Int, in text: NSString) -> Bool {
        offset == text.length || !(0xDC00...0xDFFF).contains(text.character(at: offset))
    }

    private func replacingUnprotectedText(in source: String, text: NSString, range: NSRange,
                                          widthCharacters: WidthCharacters, dialect: MarkdownDialect) -> String {
        let analysis = MarkdownAnalysis(source, dialect: dialect)
        var protectedRanges = analysis.references.values.map(\.sourceRange)
        var inlineScopes = analysis.footnotes.definitionRanges
        for block in analysis.blocks where NSIntersectionRange(block.sourceRange, range).length > 0 {
            switch block.kind {
            case .codeBlock:
                protectedRanges.append(block.sourceRange)
            case .paragraph, .heading, .unorderedList, .orderedList:
                inlineScopes.append(block.sourceRange)
            case .table:
                if let table = block.table {
                    inlineScopes += MarkdownTableEditing.cellSourceRanges(
                        in: text, table: table, startingAt: block.sourceRange.location)
                }
            case .quote, .horizontalRule, .blank:
                // A quote's child blocks are already in the analysis.
                break
            }
        }
        // Pair backticks only inside an inline block, never with those from a separate code block.
        for scope in inlineScopes where NSIntersectionRange(scope, range).length > 0 {
            let inline = Self.protectedInlineRanges(in: text.substring(with: scope), references: analysis.references)
            protectedRanges += inline.map { NSRange(location: scope.location + $0.location, length: $0.length) }
        }
        let full = NSRange(location: 0, length: text.length)
        protectedRanges += Self.linkDetector.matches(in: source, range: full).map(\.range)
        protectedRanges += Self.angleURL.matches(in: source, range: full).map(\.range)

        var protectedOffsets = IndexSet()
        for candidate in protectedRanges {
            let overlap = NSIntersectionRange(range, candidate)
            if overlap.length > 0 {
                protectedOffsets.insert(integersIn: overlap.location..<NSMaxRange(overlap))
            }
        }
        var result = ""
        var cursor = range.location
        for protected in protectedOffsets.rangeView {
            let unprotected = text.substring(with: NSRange(cursor..<protected.lowerBound))
            result += transform(unprotected, widthCharacters: widthCharacters)
            result += text.substring(with: NSRange(protected))
            cursor = protected.upperBound
        }
        let remainder = text.substring(with: NSRange(cursor..<NSMaxRange(range)))
        result += transform(remainder, widthCharacters: widthCharacters)
        return result
    }

    private static func protectedInlineRanges(in source: String, references: [String: MarkdownReference]) -> [NSRange] {
        let text = source as NSString
        let codeSpans = MarkdownInlineSyntax.codeSpanRanges(in: source)
        var result = codeSpans
        var scopes = [NSRange(location: 0, length: text.length)]
        while let scope = scopes.popLast() {
            guard text.range(of: "[", options: .literal, range: scope).location != NSNotFound else { continue }
            let inline = text.substring(with: scope)
            let links = MarkdownLinkSyntax.inlineLinks(in: inline)
            var inlineLinkOffsets = IndexSet()

            func offset(_ local: NSRange) -> NSRange {
                NSRange(location: scope.location + local.location, length: local.length)
            }

            func protectLink(_ link: NSRange, preservingLabel label: NSRange) {
                // Leave the label editable while keeping the Markdown delimiters and destination.
                result.append(offset(NSRange(link.location..<label.location)))
                result.append(offset(NSRange(NSMaxRange(label)..<NSMaxRange(link))))
            }

            for link in links {
                let location = scope.location + link.range.location
                let start = NSRange(location: location, length: 1)
                guard !MarkdownInlineSyntax.intersects(start, sortedRanges: codeSpans) else { continue }
                protectLink(link.range, preservingLabel: link.labelRange)
                inlineLinkOffsets.insert(integersIn: link.range.location..<NSMaxRange(link.range))
                // A link label may itself contain an image with a relative destination.
                scopes.append(offset(link.labelRange))
            }
            guard !references.isEmpty else { continue }
            let inlineText = inline as NSString
            for match in referenceLink.matches(in: inline, range: NSRange(location: 0, length: scope.length)) {
                let location = match.range.location
                let end = NSMaxRange(match.range)
                let start = NSRange(location: scope.location + location, length: 1)
                guard !inlineLinkOffsets.contains(location),
                      !MarkdownInlineSyntax.intersects(start, sortedRanges: codeSpans),
                      !MarkdownLinkSyntax.isEscaped(inlineText, at: location),
                      end == scope.length || ![40, 58].contains(inlineText.character(at: end)) else { continue }
                let label = match.range(at: 1)
                let identifier = match.range(at: 2)
                let key = inlineText.substring(with: identifier.length > 0 ? identifier : label)
                guard references[MarkdownAnalysis.normalizedReferenceLabel(key)] != nil else { continue }
                if identifier.length > 0 {
                    protectLink(match.range, preservingLabel: label)
                } else {
                    // A shortcut or collapsed reference uses its displayed label as the key.
                    result.append(offset(match.range))
                }
            }
        }
        return result
    }

    private func transform(_ text: String, widthCharacters: WidthCharacters) -> String {
        switch self {
        case .uppercase: return text.uppercased()
        case .lowercase: return text.lowercased()
        case .capitalized: return Self.capitalizeWordStarts(in: text)
        case .fullwidthToHalfwidth, .halfwidthToFullwidth:
            return Self.convertWidth(in: text, toFullwidth: self == .halfwidthToFullwidth, characters: widthCharacters)
        case .hiraganaToKatakana, .katakanaToHiragana:
            return Self.convertKana(in: text, toKatakana: self == .hiraganaToKatakana)
        case .nfc: return text.precomposedStringWithCanonicalMapping
        case .nfd: return text.decomposedStringWithCanonicalMapping
        case .nfkc:
            // Compose across scalars introduced by compatibility decomposition, such as ｶ + ﾞ.
            return text.decomposedStringWithCompatibilityMapping.precomposedStringWithCanonicalMapping
        case .nfkd: return text.decomposedStringWithCompatibilityMapping
        }
    }

    private static func capitalizeWordStarts(in text: String) -> String {
        var result = ""
        var cursor = text.startIndex
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                                 options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            // Foundation word boundaries can fall inside a Swift Character.
            let word = String(text[range])
            result += text[cursor..<range.lowerBound]
            if let initial = word.first {
                result += String(initial).capitalized
                result += word.dropFirst()
            }
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }

    private static func convertWidth(in text: String, toFullwidth: Bool, characters: WidthCharacters) -> String {
        var result = ""
        for character in text {
            let scalars = character.unicodeScalars
            guard let first = scalars.first,
                  let category = widthCategory(of: first),
                  characters.contains(category),
                  !scalars.contains(where: { $0.value == 0xFE0F || $0.value == 0x20E3 }) else {
                result.append(character)
                continue
            }
            if category == .kana {
                let original = String(character)
                let converted = original.applyingTransform(.fullwidthToHalfwidth, reverse: toFullwidth) ?? original
                result += toFullwidth && !converted.utf16.elementsEqual(original.utf16)
                    ? converted.precomposedStringWithCanonicalMapping : converted
            } else {
                result += convertWidth(of: first, toFullwidth: toFullwidth)
                result.unicodeScalars.append(contentsOf: scalars.dropFirst())
            }
        }
        return result
    }

    private static func convertWidth(of scalar: Unicode.Scalar, toFullwidth: Bool) -> String {
        switch (toFullwidth, scalar.value) {
        case (true, 0x21...0x7E): return String(Unicode.Scalar(scalar.value + 0xFEE0)!)
        case (false, 0xFF01...0xFF5E): return String(Unicode.Scalar(scalar.value - 0xFEE0)!)
        default:
            let original = String(scalar)
            return original.applyingTransform(.fullwidthToHalfwidth, reverse: toFullwidth) ?? original
        }
    }

    private static func widthCategory(of scalar: Unicode.Scalar) -> WidthCharacters? {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A,
             0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF41...0xFF5A:
            return .alphanumeric
        case 0x30A1...0x30FA, 0x30FC...0x30FE, 0xFF66...0xFF9F:
            return .kana
        case 0x20...0x7E, 0xA2, 0xA3, 0xA5, 0xA6, 0xAC, 0xAF, 0x20A9, 0x2985...0x2986,
             0x3000...0x3002, 0x300C, 0x300D, 0x30FB, 0xFF01...0xFF60,
             0xFF61...0xFF65, 0xFFE0...0xFFE6:
            return .symbols
        default: return nil
        }
    }

    private static func convertKana(in text: String, toKatakana: Bool) -> String {
        var result = ""
        for character in text {
            let original = String(character)
            guard let first = character.unicodeScalars.first else { continue }
            switch (toKatakana, first.value) {
            case (true, 0x3041...0x3094), (true, 0x309D...0x309F),
                 (false, 0x30A1...0x30F4), (false, 0x30F7...0x30FA),
                 (false, 0x30FD...0x30FF), (false, 0xFF66...0xFF9D):
                result += original.applyingTransform(.hiraganaToKatakana, reverse: !toKatakana) ?? original
            case (true, 0x3095...0x3096), (false, 0x30F5...0x30F6):
                // The two scripts have corresponding small ka and ke characters.
                let value = toKatakana ? first.value + 0x60 : first.value - 0x60
                result.unicodeScalars.append(Unicode.Scalar(value)!)
                result.unicodeScalars.append(contentsOf: character.unicodeScalars.dropFirst())
            default:
                result.append(character)
            }
        }
        return result
    }
}
