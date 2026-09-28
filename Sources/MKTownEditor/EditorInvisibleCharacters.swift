import AppKit
import Foundation

struct EditorWhitespaceOptions: Equatable {
    var showsCharacters = false
    var showsIndentGuides = false
}

struct InvisibleCharacterPlan: Equatable {
    enum Kind: Equatable { case space, trailingSpace, tab, newline }
    struct Mark: Equatable {
        let location: Int
        let kind: Kind
    }
    let marks: [Mark]
    let guides: [Int]

    init(source: String, tabWidth: Int) {
        let text = source as NSString
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
                    marks.append(Mark(location: location, kind: character == 9 ? .tab
                        : location >= trailing ? .trailingSpace : .space))
                    if stillIndent {
                        indentColumns += character == 9 ? tabWidth - indentColumns % tabWidth : 1
                        if character == 9 || indentColumns % tabWidth == 0 {
                            guides.append(location)
                        }
                    }
                } else {
                    stillIndent = false
                }
            }
            if end < NSMaxRange(lineRange) {
                marks.append(Mark(location: end, kind: .newline))
            }
            cursor = NSMaxRange(lineRange)
        }
        self.marks = marks
        self.guides = guides
    }
}
