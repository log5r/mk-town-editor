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
        case .missingFile: String(localized: "ファイルが見つかりません")
        case .missingImage: String(localized: "画像が見つかりません")
        case .missingHeading: String(localized: "見出しが見つかりません")
        case .missingReference: String(localized: "参照定義が見つかりません")
        case .unreadableTarget: String(localized: "リンク先を読み取れません")
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

enum MarkdownLintRule: String, Codable, CaseIterable, Sendable {
    case headingHierarchy
    case missingLink
    case listMarker

    var title: String {
        switch self {
        case .headingHierarchy: String(localized: "見出し階層")
        case .missingLink: String(localized: "リンク先")
        case .listMarker: String(localized: "箇条書き記号")
        }
    }
}

struct MarkdownLintDiagnostic: Identifiable, Equatable, Sendable {
    let rule: MarkdownLintRule
    let sourceRange: NSRange
    let detail: String

    var id: String { "\(rule.rawValue):\(sourceRange.location):\(detail)" }
}

enum MarkdownLint {
    private static let markerPattern = try! NSRegularExpression(pattern: #"^[ \t]*([-+*])[ \t]+"#)

    static func inspect(_ source: String, analysis: MarkdownAnalysis,
                        context: DocumentContext,
                        disabled: Set<MarkdownLintRule> = []) -> [MarkdownLintDiagnostic] {
        var result: [MarkdownLintDiagnostic] = []
        if !disabled.contains(.headingHierarchy) {
            var previousLevel = 0
            for block in analysis.blocks.sorted(by: { $0.sourceRange.location < $1.sourceRange.location }) {
                guard case let .heading(level) = block.kind else { continue }
                if level > previousLevel + 1 {
                    result.append(MarkdownLintDiagnostic(rule: .headingHierarchy,
                        sourceRange: block.sourceRange,
                        detail: previousLevel == 0
                            ? String(localized: "最初の見出しはレベル1を推奨します")
                            : String(localized: "見出しレベルが\(previousLevel)から\(level)へ飛んでいます")))
                }
                previousLevel = level
            }
        }
        if !disabled.contains(.missingLink) {
            result += MarkdownLinkDiagnostics.inspect(source, analysis: analysis, context: context)
                .map { MarkdownLintDiagnostic(rule: .missingLink,
                    sourceRange: $0.sourceRange, detail: "\($0.title): \($0.detail)") }
        }
        if !disabled.contains(.listMarker) {
            let text = source as NSString
            var firstMarker: String?
            for block in analysis.blocks.sorted(by: { $0.sourceRange.location < $1.sourceRange.location })
                where block.kind == .unorderedList {
                let line = text.substring(with: block.sourceRange)
                    .components(separatedBy: .newlines).first ?? ""
                let range = NSRange(location: 0, length: (line as NSString).length)
                guard let match = markerPattern.firstMatch(in: line, range: range) else { continue }
                let marker = (line as NSString).substring(with: match.range(at: 1))
                if let firstMarker, firstMarker != marker {
                    result.append(MarkdownLintDiagnostic(rule: .listMarker,
                        sourceRange: block.sourceRange,
                        detail: String(localized: "箇条書き記号を「\(firstMarker)」に揃えてください")))
                } else if firstMarker == nil {
                    firstMarker = marker
                }
            }
        }
        return result.sorted { $0.sourceRange.location < $1.sourceRange.location }
    }
}
