import Foundation

struct NavigationPoint: Equatable, Sendable {
    let documentURL: URL?
    let utf16Location: Int
}

struct NavigationHistory: Equatable {
    private(set) var back: [NavigationPoint] = []
    private(set) var forward: [NavigationPoint] = []
    private let capacity = 100

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    mutating func recordJump(from origin: NavigationPoint, to destination: NavigationPoint) {
        guard origin != destination else { return }
        back.append(origin)
        if back.count > capacity { back.removeFirst(back.count - capacity) }
        forward.removeAll()
    }

    mutating func goBack(from current: NavigationPoint) -> NavigationPoint? {
        guard let destination = back.popLast() else { return nil }
        forward.append(current)
        return destination
    }

    mutating func goForward(from current: NavigationPoint) -> NavigationPoint? {
        guard let destination = forward.popLast() else { return nil }
        back.append(current)
        if back.count > capacity { back.removeFirst(back.count - capacity) }
        return destination
    }

    mutating func moveDocument(from oldURL: URL?, to newURL: URL?) {
        guard oldURL != newURL else { return }
        back = back.map { point in
            point.documentURL == oldURL
                ? NavigationPoint(documentURL: newURL, utf16Location: point.utf16Location) : point
        }
        forward = forward.map { point in
            point.documentURL == oldURL
                ? NavigationPoint(documentURL: newURL, utf16Location: point.utf16Location) : point
        }
    }
}

struct DocumentBookmark: Codable, Equatable, Identifiable {
    var id = UUID()
    var documentURL: URL
    var title: String
    var utf16Location: Int
    var snippet: String
    var snippetOffset: Int
    var sectionSlug: String?
    var sectionOffset: Int?

    static func capture(in text: String, at location: Int, documentURL: URL) -> Self {
        let source = text as NSString
        let safe = min(max(location, 0), source.length)
        let start = max(0, safe - 24)
        let range = source.rangeOfComposedCharacterSequences(for: NSRange(
            location: start, length: min(source.length - start, 48)))
        let headings = MarkdownHeadingIndex(analysis: MarkdownAnalysis(text)).anchors
        let section = headings.last { $0.entry.sourceRange.location <= safe }
        let lineIndex = MarkdownLineIndex(text)
        let line = lineIndex.line(containingUTF16Offset: safe)
        let lineStart = lineIndex.starts[line - 1]
        let lineEnd = line < lineIndex.lineCount ? lineIndex.starts[line] - 1 : source.length
        let label = source.substring(with: NSRange(location: lineStart,
            length: max(0, lineEnd - lineStart)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(documentURL: documentURL.resolvingSymlinksInPath().standardizedFileURL,
            title: String(label.prefix(60)).isEmpty ? String(localized: "行 \(line)") : String(label.prefix(60)),
            utf16Location: safe, snippet: source.substring(with: range),
            snippetOffset: safe - range.location, sectionSlug: section?.slug,
            sectionOffset: section.map { safe - $0.entry.sourceRange.location })
    }

    func resolvedLocation(in text: String) -> Int {
        let source = text as NSString
        let headings = MarkdownHeadingIndex(analysis: MarkdownAnalysis(text)).anchors
        let sectionIndex = sectionSlug.flatMap { slug in
            headings.firstIndex { $0.slug == slug }
        }
        let heading = sectionIndex.map { headings[$0].entry }
        let sectionEnd = sectionIndex.flatMap { index in
            headings.dropFirst(index + 1).first {
                $0.entry.level <= headings[index].entry.level
            }?.entry.sourceRange.location
        } ?? source.length
        let preferred = heading.map { $0.sourceRange.location + (sectionOffset ?? 0) }
            ?? utf16Location
        if !snippet.isEmpty {
            var cursor = 0
            var best: Int?
            var bestDistance = Int.max
            while cursor <= source.length - (snippet as NSString).length {
                let found = source.range(of: snippet,
                    range: NSRange(location: cursor, length: source.length - cursor))
                if found.location == NSNotFound { break }
                let candidate = found.location + snippetOffset
                if let heading, (candidate < heading.sourceRange.location || candidate >= sectionEnd) {
                    cursor = found.location + max(found.length, 1)
                    continue
                }
                let distance = abs(candidate - preferred)
                if distance < bestDistance {
                    best = candidate
                    bestDistance = distance
                }
                cursor = found.location + max(found.length, 1)
            }
            if let best { return best }
        }
        return min(max(preferred, 0), source.length)
    }
}
