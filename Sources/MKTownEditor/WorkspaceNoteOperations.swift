import Foundation

enum WorkspaceNoteOperationError: LocalizedError {
    case sourceChanged
    case editRejected
    case rollbackFailed
    case tooManyDocuments
    case unreadableDocument(URL)

    var errorDescription: String? {
        switch self {
        case .sourceChanged: String(localized: "分割前に元の書類が変更されました。もう一度確認してください。")
        case .editRejected: String(localized: "元の書類を編集できませんでした。")
        case .rollbackFailed: String(localized: "分割の復元に失敗しました。作成先の書類を確認してください。")
        case .tooManyDocuments: String(localized: "結合できる書類は一度に10件までです。")
        case let .unreadableDocument(url): String(localized: "書類を読み込めません: \(url.lastPathComponent)")
        }
    }
}

struct WorkspaceSectionSplit {
    let title: String
    let sourceEdit: MarkdownEdit
    let extractedText: String
}

struct WorkspaceMergeInput: Sendable {
    let url: URL
    let text: String
}

enum WorkspaceNoteOperations {
    static func applySplit(_ plan: WorkspaceSectionSplit,
                           destinationURL: URL, root: URL,
                           editSource: () -> Bool) throws -> URL {
        let created = try WorkspaceFileOperations.create(
            name: destinationURL.lastPathComponent,
            in: destinationURL.deletingLastPathComponent(), root: root,
            folder: false, contents: plan.extractedText)
        if editSource() { return created }
        guard let current = try? Data(contentsOf: created),
              current == Data(plan.extractedText.utf8),
              (try? FileManager.default.removeItem(at: created)) != nil else {
            throw WorkspaceNoteOperationError.rollbackFailed
        }
        throw WorkspaceNoteOperationError.editRejected
    }

    static func split(_ source: String, headingLocation: Int,
                      sourceURL: URL, destinationURL: URL,
                      workspaceDocuments: [URL]) -> WorkspaceSectionSplit? {
        let headings = MarkdownOutline.entries(in: MarkdownAnalysis(source))
        guard let selected = headings.first(where: { $0.sourceRange.location == headingLocation }) else {
            return nil
        }
        let end = headings.first(where: {
            $0.sourceRange.location > selected.sourceRange.location && $0.level <= selected.level
        })?.sourceRange.location ?? (source as NSString).length
        let range = NSRange(location: selected.sourceRange.location,
            length: end - selected.sourceRange.location)
        let raw = (source as NSString).substring(with: range)
        let rebased = rebaseLinks(raw, from: sourceURL, to: destinationURL,
            workspaceDocuments: workspaceDocuments, retainsLocalFragments: true)
        let normalized = shiftHeadings(rebased, by: 1 - selected.level)
        let path = encodedPath(WorkspaceWikiLinks.relativePath(
            from: sourceURL.deletingLastPathComponent(), to: destinationURL))
        let heading = String(repeating: "#", count: selected.level) + " " + selected.title
        let redirect = heading + "\n\n" +
            MarkdownLinkSyntax.makeLink(label: String(localized: "移動先の書類"),
                destination: path) + "\n\n"
        return WorkspaceSectionSplit(title: MarkdownHeadingIndex.visibleText(selected.title),
            sourceEdit: MarkdownEdit(range: range, replacement: redirect,
                selection: NSRange(location: range.location, length: 0)),
            extractedText: normalized)
    }

    static func merge(_ inputs: [WorkspaceMergeInput], destinationURL: URL,
                      workspaceDocuments: [URL]) -> String? {
        guard inputs.count >= 2 else { return nil }
        return inputs.map { input in
            let title = input.url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "\n", with: " ")
            let body: String
            if let frontMatter = MarkdownFrontMatter(source: input.text) {
                let rest = (input.text as NSString).substring(from: NSMaxRange(frontMatter.sourceRange))
                body = "```yaml\n" + frontMatter.content.trimmingCharacters(in: .newlines) +
                    "\n```\n\n" + rest
            } else {
                body = input.text
            }
            let rebased = rebaseLinks(body, from: input.url, to: destinationURL,
                workspaceDocuments: workspaceDocuments, retainsLocalFragments: false)
            return "# \(title)\n\n" + shiftHeadings(rebased, by: 1)
                .trimmingCharacters(in: .newlines)
        }.joined(separator: "\n\n---\n\n") + "\n"
    }

    static func shiftHeadings(_ source: String, by delta: Int) -> String {
        guard delta != 0 else { return source }
        let analysis = MarkdownAnalysis(source)
        let result = NSMutableString(string: source)
        let text = source as NSString
        for block in analysis.blocks.reversed() {
            guard case let .heading(level) = block.kind else { continue }
            let newLevel = min(6, max(1, level + delta))
            guard newLevel != level else { continue }
            let original = text.substring(with: block.sourceRange)
            let trailing = original.reversed().prefix(while: { $0 == "\n" || $0 == "\r" })
            let replacement = String(repeating: "#", count: newLevel) + " " +
                block.content.replacingOccurrences(of: "\n", with: " ") +
                String(trailing.reversed())
            result.replaceCharacters(in: block.sourceRange, with: replacement)
        }
        return result as String
    }

    static func rebaseLinks(_ source: String, from sourceURL: URL, to destinationURL: URL,
                            workspaceDocuments: [URL], retainsLocalFragments: Bool) -> String {
        let analysis = MarkdownAnalysis(source)
        let excluded = analysis.blocks.filter { $0.kind == .codeBlock }.map(\.sourceRange)
            + MarkdownInlineSyntax.codeSpanRanges(in: source)
            + (analysis.frontMatter.map { [$0.sourceRange] } ?? [])
        let context = DocumentContext(fileURL: sourceURL)
        let headingIndex = retainsLocalFragments ? MarkdownHeadingIndex(analysis: analysis) : nil
        let sourceText = source as NSString
        var edits: [(NSRange, String)] = []
        func rebased(_ value: String) -> String? {
            let pieces = value.split(separator: "#", maxSplits: 1,
                omittingEmptySubsequences: false)
            let path = String(pieces[0])
            let fragment = pieces.count == 2 ? "#" + pieces[1] : ""
            let target: URL
            if path.isEmpty {
                guard !fragment.isEmpty else { return nil }
                if headingIndex?.entry(forFragment: fragment) != nil {
                    return nil
                }
                target = sourceURL
            } else {
                guard let resolved = context.resolveLocalResource(path) else { return nil }
                target = resolved
            }
            let relative = WorkspaceWikiLinks.relativePath(
                from: destinationURL.deletingLastPathComponent(), to: target)
            return MarkdownLinkSyntax.escapeDestination(encodedPath(relative) + fragment)
        }
        for link in MarkdownLinkSyntax.inlineLinks(in: source) {
            guard !excluded.contains(where: { NSLocationInRange(link.range.location, $0) }),
                  let replacement = rebased(link.destination) else { continue }
            edits.append((link.destinationRange, replacement))
        }
        for reference in analysis.references.values {
            guard !excluded.contains(where: {
                NSLocationInRange(reference.sourceRange.location, $0)
            }), let replacement = rebased(reference.destination) else { continue }
            let line = sourceText.substring(with: reference.sourceRange)
            guard let separator = line.range(of: "]:"),
                  let target = line[separator.upperBound...].range(of: reference.destination) else {
                continue
            }
            let local = NSRange(target, in: line)
            edits.append((NSRange(location: reference.sourceRange.location + local.location,
                length: local.length), replacement))
        }
        let documentIndex = WorkspaceDocumentIndex(documents: workspaceDocuments)
        let futureIndex = WorkspaceDocumentIndex(documents: workspaceDocuments + [destinationURL])
        for wiki in WorkspaceWikiLinks.links(in: source) {
            guard let target = WorkspaceWikiLinks.resolve(wiki.target, from: sourceURL,
                index: documentIndex) else { continue }
            let replacement = WorkspaceWikiLinks.target(for: target,
                from: destinationURL, index: futureIndex)
            if replacement != wiki.target { edits.append((wiki.targetRange, replacement)) }
        }
        for embed in WorkspaceDocumentEmbed.links(in: source) {
            guard let target = WorkspaceWikiLinks.resolve(embed.target, from: sourceURL,
                index: documentIndex) else { continue }
            let replacement = WorkspaceWikiLinks.target(for: target,
                from: destinationURL, index: futureIndex)
            if replacement != embed.target { edits.append((embed.targetRange, replacement)) }
        }
        let result = NSMutableString(string: source)
        for (range, value) in edits.sorted(by: { $0.0.location > $1.0.location }) {
            result.replaceCharacters(in: range, with: value)
        }
        return result as String
    }

    private static func encodedPath(_ path: String) -> String {
        path.replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "#", with: "%23")
            .replacingOccurrences(of: "?", with: "%3F")
    }
}
