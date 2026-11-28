import AppKit
import Foundation

struct EditorWhitespaceOptions: Equatable {
    var showsCharacters = false
    var showsIndentGuides = false
}

struct InvisibleCharacterPlan: Equatable {
    enum Kind: Equatable {
        case space, trailingSpace, tab, newline, differentNewline
        case control(UInt16), zeroWidth
    }
    struct Mark: Equatable {
        let location: Int
        let kind: Kind
    }
    let marks: [Mark]
    let guides: [Int]

    init(source: String, tabWidth: Int, format: MarkdownTextFormat = MarkdownTextFormat(),
         showsCharacters: Bool = true) {
        let text = source as NSString
        let differentEndings = showsCharacters ? Set(format.newlineWarnings(in: source).map { $0.range.location }) : []
        var marks: [Mark] = []
        var guides: [Int] = []
        var cursor = 0
        while cursor < text.length {
            let lineRange = text.lineRange(for: NSRange(location: cursor, length: 0))
            var end = NSMaxRange(lineRange)
            if end > cursor, text.character(at: end - 1) == 10 { end -= 1 }
            if end > cursor, text.character(at: end - 1) == 13 { end -= 1 }
            var trailing = end
            while trailing > cursor && [32, 9].contains(text.character(at: trailing - 1)) {
                trailing -= 1
            }
            var indentColumns = 0
            var stillIndent = true
            for location in cursor..<end {
                let character = text.character(at: location)
                if character == 32 || character == 9 {
                    if showsCharacters {
                        marks.append(Mark(location: location, kind: character == 9 ? .tab
                            : location >= trailing ? .trailingSpace : .space))
                    }
                    if stillIndent {
                        indentColumns += character == 9 ? tabWidth - indentColumns % tabWidth : 1
                        if character == 9 || indentColumns % tabWidth == 0 {
                            guides.append(location)
                        }
                    }
                } else {
                    stillIndent = false
                    if showsCharacters, let kind = Self.hiddenKind(for: character, at: location, in: text) {
                        marks.append(Mark(location: location, kind: kind))
                    }
                }
            }
            if showsCharacters, end < NSMaxRange(lineRange) {
                marks.append(Mark(location: end, kind: differentEndings.contains(end) ? .differentNewline : .newline))
            }
            cursor = NSMaxRange(lineRange)
        }
        self.marks = marks
        self.guides = guides
    }

    private static func hiddenKind(for unit: UInt16, at location: Int, in text: NSString) -> Kind? {
        if unit < 0x20 || (0x7F...0x9F).contains(unit) { return .control(unit) }
        if unit == 0x2028 || unit == 0x2029 { return .newline }
        // The first default-ignorable scalar is U+00AD. A leading surrogate carries the mark.
        guard unit >= 0xAD, !(0xDC00...0xDFFF).contains(unit) else { return nil }
        let scalar: Unicode.Scalar?
        if (0xD800...0xDBFF).contains(unit), location + 1 < text.length {
            let following = text.character(at: location + 1)
            guard (0xDC00...0xDFFF).contains(following) else { return nil }
            scalar = Unicode.Scalar(0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(following) - 0xDC00))
        } else {
            scalar = Unicode.Scalar(unit)
        }
        guard let scalar, scalar.properties.isDefaultIgnorableCodePoint,
              !shapesVisibleCharacter(scalar, at: location, in: text) else { return nil }
        return .zeroWidth
    }

    private static func shapesVisibleCharacter(_ scalar: Unicode.Scalar, at location: Int, in text: NSString) -> Bool {
        let isSelector = scalar.properties.isVariationSelector
        let isJoiner = scalar.value == 0x200D
        let isTag = (0xE0020...0xE007F).contains(scalar.value)
        guard isSelector || isJoiner || isTag else { return false }
        let cluster = text.rangeOfComposedCharacterSequence(at: location)
        let prefix = text.substring(with: NSRange(location: cluster.location,
                                                  length: location - cluster.location)).unicodeScalars
        if isSelector {
            guard let base = prefix.last else { return false }
            return !base.properties.isWhitespace && !base.properties.isDefaultIgnorableCodePoint
        }
        if isTag {
            return prefix.first?.value == 0x1F3F4 && text.substring(with: cluster).unicodeScalars.last?.value == 0xE007F
        }
        let next = location + 1
        guard next < NSMaxRange(cluster) else { return false }
        let suffix = text.substring(with: NSRange(location: next, length: NSMaxRange(cluster) - next)).unicodeScalars
        // Keep a joiner between emoji bases unmarked, including an intervening skin tone or variation selector.
        let base = prefix.last { !$0.properties.isGraphemeExtend && !$0.properties.isEmojiModifier }
        return base?.properties.isEmoji == true && suffix.first?.properties.isEmoji == true
    }
}
