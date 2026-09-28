import Foundation

struct MarkdownOutlineEntry: Identifiable, Equatable, Sendable {
    let id: Int
    let level: Int
    let title: String
    let sourceRange: NSRange
}

enum MarkdownOutline {
    static func entries(in analysis: MarkdownAnalysis) -> [MarkdownOutlineEntry] {
        analysis.blocks.compactMap { block in
            guard case let .heading(level) = block.kind else { return nil }
            let title = block.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return MarkdownOutlineEntry(id: block.id, level: level,
                                        title: title.isEmpty ? String(localized: "無題の見出し") : title,
                                        sourceRange: block.sourceRange)
        }
    }

    static func currentSection(at sourceLocation: Int,
                               in entries: [MarkdownOutlineEntry]) -> MarkdownOutlineEntry? {
        guard sourceLocation >= 0 else { return nil }
        return entries.last { $0.sourceRange.location <= sourceLocation }
    }

    static func search(_ query: String, in entries: [MarkdownOutlineEntry]) -> [MarkdownOutlineEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return entries }
        return entries.filter { $0.title.localizedStandardContains(term) }
    }
}

enum SectionMoveDirection { case up, down }

enum MarkdownSectionMove {
    static func edit(in text: String, headingLocation: Int,
                     direction: SectionMoveDirection) -> MarkdownEdit? {
        let source = text as NSString
        let headings = MarkdownOutline.entries(in: MarkdownAnalysis(text))
        guard let selected = headings.firstIndex(where: {
            $0.sourceRange.location == headingLocation
        }) else { return nil }
        var parents: [Int?] = []
        var stack: [Int] = []
        for index in headings.indices {
            while let last = stack.last, headings[last].level >= headings[index].level {
                stack.removeLast()
            }
            parents.append(stack.last)
            stack.append(index)
        }
        let siblings = headings.indices.filter {
            headings[$0].level == headings[selected].level && parents[$0] == parents[selected]
        }
        guard let position = siblings.firstIndex(of: selected) else { return nil }
        let other: Int
        switch direction {
        case .up:
            guard position > 0 else { return nil }
            other = siblings[position - 1]
        case .down:
            guard position + 1 < siblings.count else { return nil }
            other = siblings[position + 1]
        }
        func end(of index: Int) -> Int {
            headings.dropFirst(index + 1).first {
                $0.level <= headings[index].level
            }?.sourceRange.location ?? source.length
        }
        let first = min(selected, other)
        let second = max(selected, other)
        let firstStart = headings[first].sourceRange.location
        let secondStart = headings[second].sourceRange.location
        let lastEnd = end(of: second)
        guard end(of: first) == secondStart else { return nil }
        let firstText = source.substring(with: NSRange(location: firstStart,
            length: secondStart - firstStart))
        let secondText = source.substring(with: NSRange(location: secondStart,
            length: lastEnd - secondStart))
        func parts(_ value: String) -> (body: String, separator: String) {
            let raw = value as NSString
            let trailing = raw.range(of: "[\\r\\n]+$", options: .regularExpression)
            guard trailing.location != NSNotFound else { return (value, "") }
            return (raw.substring(to: trailing.location), raw.substring(with: trailing))
        }
        let firstParts = parts(firstText)
        let secondParts = parts(secondText)
        let replacement = secondParts.body + firstParts.separator +
            firstParts.body + secondParts.separator
        let movedStart = direction == .up ? firstStart :
            firstStart + (secondParts.body as NSString).length +
                (firstParts.separator as NSString).length
        return MarkdownEdit(range: NSRange(location: firstStart, length: lastEnd - firstStart),
            replacement: replacement,
            selection: NSRange(location: movedStart, length: 0))
    }
}

enum MarkdownSectionLevel {
    static func edit(in text: String, headingLocation: Int, by delta: Int) -> MarkdownEdit? {
        guard delta == -1 || delta == 1 else { return nil }
        let source = text as NSString
        let entries = MarkdownOutline.entries(in: MarkdownAnalysis(text))
        guard let index = entries.firstIndex(where: {
            $0.sourceRange.location == headingLocation
        }) else { return nil }
        let end = entries.dropFirst(index + 1).first {
            $0.level <= entries[index].level
        }?.sourceRange.location ?? source.length
        let selected = entries.dropFirst(index).prefix { $0.sourceRange.location < end }
        guard selected.allSatisfy({ (1...6).contains($0.level + delta) }) else { return nil }
        let sectionStart = entries[index].sourceRange.location
        let range = NSRange(location: sectionStart, length: end - sectionStart)
        let replacement = NSMutableString(string: source.substring(with: range))
        for entry in selected.reversed() {
            let original = source.substring(with: entry.sourceRange)
            let lineEnding = original.hasSuffix("\r\n") ? "\r\n" :
                original.hasSuffix("\n") ? "\n" : original.hasSuffix("\r") ? "\r" : ""
            let prefix = String(repeating: "#", count: entry.level + delta) + " "
            let updated = prefix + entry.title + lineEnding
            replacement.replaceCharacters(in: NSRange(
                location: entry.sourceRange.location - sectionStart,
                length: entry.sourceRange.length), with: updated)
        }
        return MarkdownEdit(range: range, replacement: replacement as String,
            selection: NSRange(location: sectionStart, length: 0))
    }
}

enum MarkdownContentKind: String, CaseIterable {
    case task = "タスク"
    case link = "リンク"
    case image = "画像"

    var title: String {
        switch self {
        case .task: String(localized: "タスク")
        case .link: String(localized: "リンク")
        case .image: String(localized: "画像")
        }
    }
}

struct MarkdownContentItem: Identifiable, Equatable {
    let kind: MarkdownContentKind
    let label: String
    let destination: String?
    let sourceRange: NSRange

    var id: String { "\(kind.rawValue):\(sourceRange.location):\(sourceRange.length)" }
}

enum MarkdownContentInspector {
    private static let reference = try! NSRegularExpression(
        pattern: #"(!?)\[([^\]\n]+)\](?:\[([^\]\n]*)\])?"#)

    static func items(in text: String, analysis: MarkdownAnalysis) -> [MarkdownContentItem] {
        let source = text as NSString
        let excluded = analysis.blocks.filter { $0.kind == .codeBlock }.map(\.sourceRange) +
            MarkdownInlineSyntax.codeSpanRanges(in: text)
        func isExcluded(_ range: NSRange) -> Bool {
            excluded.contains { NSIntersectionRange($0, range).length > 0 }
        }
        var items = analysis.blocks.compactMap { block -> MarkdownContentItem? in
            guard let task = block.task else { return nil }
            return MarkdownContentItem(kind: .task,
                label: (task.isChecked ? String(localized: "完了: ") : String(localized: "未完了: ")) + task.content,
                destination: nil, sourceRange: block.sourceRange)
        }
        let inline = MarkdownLinkSyntax.inlineLinks(in: text).filter {
            !isExcluded($0.range)
        }
        for link in inline {
            let label = source.substring(with: link.labelRange)
            items.append(MarkdownContentItem(kind: link.isImage ? .image : .link,
                label: label, destination: link.destination, sourceRange: link.range))
        }
        for match in reference.matches(in: text,
            range: NSRange(location: 0, length: source.length)) {
            if isExcluded(match.range) || inline.contains(where: {
                NSIntersectionRange($0.range, match.range).length > 0
            }) { continue }
            let end = NSMaxRange(match.range)
            if end < source.length && [40, 58].contains(source.character(at: end)) { continue }
            let label = source.substring(with: match.range(at: 2))
            let explicit = match.range(at: 3)
            let id = explicit.location == NSNotFound || explicit.length == 0
                ? label : source.substring(with: explicit)
            guard let definition = analysis.references[MarkdownAnalysis.normalizedReferenceLabel(id)]
            else { continue }
            let image = match.range(at: 1).length > 0
            items.append(MarkdownContentItem(kind: image ? .image : .link,
                label: label, destination: definition.destination, sourceRange: match.range))
        }
        return items.sorted { $0.sourceRange.location < $1.sourceRange.location }
    }
}

enum MarkdownSelectionExpansion {
    static func next(in text: String, selection: NSRange) -> NSRange? {
        let length = (text as NSString).length
        guard selection.location >= 0, NSMaxRange(selection) <= length else { return nil }
        let analysis = MarkdownAnalysis(text)
        let codeBlocks = analysis.blocks.filter { $0.kind == .codeBlock }.map(\.sourceRange)
        let codeSpans = MarkdownInlineSyntax.codeSpanRanges(in: text)
        var candidates = MarkdownLinkSyntax.inlineLinks(in: text).map(\.range).filter { link in
            !codeBlocks.contains { NSIntersectionRange($0, link).length > 0 } &&
                !codeSpans.contains { NSIntersectionRange($0, link).length > 0 }
        }
        for block in analysis.blocks {
            switch block.kind {
            case .paragraph, .codeBlock:
                candidates.append(block.sourceRange)
            case .unorderedList, .orderedList:
                var ids = Set([block.id])
                var end = NSMaxRange(block.sourceRange)
                for child in analysis.blocks where child.sourceRange.location >= block.sourceRange.location {
                    if let parent = child.parentID, ids.contains(parent) {
                        ids.insert(child.id)
                        end = max(end, NSMaxRange(child.sourceRange))
                    }
                }
                candidates.append(NSRange(location: block.sourceRange.location,
                    length: end - block.sourceRange.location))
            default: break
            }
        }
        if let section = DocumentStatistics.sectionRange(at: selection.location,
            in: analysis, documentLength: length) {
            candidates.append(section)
        }
        candidates.append(NSRange(location: 0, length: length))
        return candidates.filter { candidate in
            candidate != selection && candidate.length > selection.length &&
                candidate.location <= selection.location &&
                NSMaxRange(candidate) >= NSMaxRange(selection)
        }.min { $0.length < $1.length }
    }
}

struct MarkdownFoldPlan: Equatable {
    let headerLocation: Int
    let hiddenRange: NSRange

    static func at(_ location: Int, in text: String) -> MarkdownFoldPlan? {
        let source = text as NSString
        let analysis = MarkdownAnalysis(text)
        if let code = analysis.blocks.first(where: { block in
            block.kind == .codeBlock && location >= block.sourceRange.location &&
                location < NSMaxRange(block.sourceRange)
        }) {
            let hiddenStart = NSMaxRange(source.lineRange(for:
                NSRange(location: code.sourceRange.location, length: 0)))
            let end = NSMaxRange(code.sourceRange)
            guard hiddenStart < end else { return nil }
            return MarkdownFoldPlan(headerLocation: code.sourceRange.location,
                hiddenRange: NSRange(location: hiddenStart, length: end - hiddenStart))
        }
        guard let section = DocumentStatistics.sectionRange(at: location,
            in: analysis, documentLength: source.length),
              let heading = MarkdownOutline.currentSection(at: location,
                in: MarkdownOutline.entries(in: analysis)) else { return nil }
        let lastHeaderCharacter = max(heading.sourceRange.location,
            NSMaxRange(heading.sourceRange) - 1)
        let hiddenStart = NSMaxRange(source.lineRange(for:
            NSRange(location: lastHeaderCharacter, length: 0)))
        let end = NSMaxRange(section)
        guard hiddenStart < end else { return nil }
        return MarkdownFoldPlan(headerLocation: heading.sourceRange.location,
            hiddenRange: NSRange(location: hiddenStart, length: end - hiddenStart))
    }
}
