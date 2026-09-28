import Foundation

struct MarkdownLinkDiagnostic: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case missingFile, missingImage, missingHeading, missingReference, unreadableTarget
    }

    let kind: Kind
    let sourceRange: NSRange
    let detail: String

    var id: Int { sourceRange.location }

    var title: String {
        switch kind {
        case .missingFile: "ファイルが見つかりません"
        case .missingImage: "画像が見つかりません"
        case .missingHeading: "見出しが見つかりません"
        case .missingReference: "参照定義が見つかりません"
        case .unreadableTarget: "リンク先を読み取れません"
        }
    }
}

enum MarkdownLinkDiagnostics {
    private enum TargetState {
        case parsed(MarkdownAnalysis)
        case unreadable
    }

    private static let referencePattern = try! NSRegularExpression(
        pattern: #"(!?)\[([^\]\n]+)\]\[([^\]\n]*)\]"#
    )

    static func inspect(_ source: String, analysis: MarkdownAnalysis,
                        context: DocumentContext) -> [MarkdownLinkDiagnostic] {
        let excluded = analysis.blocks.filter { $0.kind == .codeBlock }.map(\.sourceRange) +
            MarkdownInlineSyntax.codeSpanRanges(in: source)
        func isExcluded(_ location: Int) -> Bool {
            excluded.contains { NSLocationInRange(location, $0) }
        }
        let headings = MarkdownHeadingIndex(analysis: analysis)
        var result: [MarkdownLinkDiagnostic] = []
        var targetCache: [URL: TargetState] = [:]
        for link in MarkdownLinkSyntax.inlineLinks(in: source) where !isExcluded(link.range.location) {
            guard let diagnostic = inspectDestination(link.destination, range: link.range,
                                                      isImage: link.isImage, headings: headings,
                                                      current: analysis, context: context,
                                                      targetCache: &targetCache) else { continue }
            result.append(diagnostic)
        }
        let text = source as NSString
        for match in referencePattern.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            guard !isExcluded(match.range.location), !isEscaped(text, at: match.range.location) else { continue }
            let label = text.substring(with: match.range(at: 2))
            let explicit = text.substring(with: match.range(at: 3))
            let key = MarkdownAnalysis.normalizedReferenceLabel(explicit.isEmpty ? label : explicit)
            if analysis.references[key] == nil {
                result.append(MarkdownLinkDiagnostic(kind: .missingReference,
                                                     sourceRange: match.range, detail: key))
            }
        }
        return result.sorted { $0.sourceRange.location < $1.sourceRange.location }
    }

    private static func inspectDestination(
        _ destination: String, range: NSRange, isImage: Bool,
        headings: MarkdownHeadingIndex, current: MarkdownAnalysis,
        context: DocumentContext, targetCache: inout [URL: TargetState]
    ) -> MarkdownLinkDiagnostic? {
        guard !destination.isEmpty else { return nil }
        let pieces = destination.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(pieces[0])
        let fragment = pieces.count > 1 ? String(pieces[1]) : nil
        if path.isEmpty {
            guard let fragment, !fragment.isEmpty,
                  headings.entry(forFragment: fragment) == nil else { return nil }
            return MarkdownLinkDiagnostic(kind: .missingHeading, sourceRange: range,
                                          detail: "#" + fragment)
        }
        guard let fileURL = context.resolveLocalResource(path) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return MarkdownLinkDiagnostic(kind: isImage ? .missingImage : .missingFile,
                                          sourceRange: range, detail: path)
        }
        guard let fragment, !fragment.isEmpty,
              ["md", "markdown"].contains(fileURL.pathExtension.lowercased()) else { return nil }
        let target: MarkdownAnalysis
        if fileURL.standardizedFileURL == context.fileURL?.standardizedFileURL {
            target = current
        } else {
            if let cached = targetCache[fileURL] {
                switch cached {
                case let .parsed(value): target = value
                case .unreadable:
                    return MarkdownLinkDiagnostic(kind: .unreadableTarget, sourceRange: range,
                                                  detail: path)
                }
            } else if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= 8_000_000,
                      let data = try? Data(contentsOf: fileURL),
                      let text = try? MarkdownDocument.decode(data) {
                target = MarkdownAnalysis(text)
                targetCache[fileURL] = .parsed(target)
            } else {
                targetCache[fileURL] = .unreadable
                return MarkdownLinkDiagnostic(kind: .unreadableTarget, sourceRange: range,
                                              detail: path)
            }
        }
        guard MarkdownHeadingIndex(analysis: target).entry(forFragment: fragment) == nil else { return nil }
        return MarkdownLinkDiagnostic(kind: .missingHeading, sourceRange: range,
                                      detail: path + "#" + fragment)
    }

    private static func isEscaped(_ source: NSString, at location: Int) -> Bool {
        var cursor = location - 1
        while cursor >= 0 && source.character(at: cursor) == 92 { cursor -= 1 }
        return (location - cursor - 1) % 2 == 1
    }
}
