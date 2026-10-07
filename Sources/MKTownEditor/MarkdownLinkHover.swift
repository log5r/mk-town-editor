import AppKit
import Foundation
import SwiftUI

struct MarkdownHoverLink: Equatable, Sendable {
    let url: URL
    let sourceRange: NSRange
}

enum MarkdownLinkHover {
    private static let referencePattern = try! NSRegularExpression(
        pattern: #"(!?)\[([^\]\n]+)\]\[([^\]\n]*)\]"#
    )

    static func links(in source: String, analysis: MarkdownAnalysis? = nil) -> [MarkdownHoverLink] {
        let analysis = analysis ?? MarkdownAnalysis(source)
        let excluded = analysis.blocks.filter { $0.kind == .codeBlock }.map(\.sourceRange) +
            MarkdownInlineSyntax.codeSpanRanges(in: source)
        func isExcluded(_ range: NSRange) -> Bool {
            excluded.contains { NSLocationInRange(range.location, $0) }
        }
        var result = MarkdownLinkSyntax.inlineLinks(in: source).compactMap { link -> MarkdownHoverLink? in
            guard !link.isImage, !isExcluded(link.range),
                  let url = URL(string: link.destination) else { return nil }
            return MarkdownHoverLink(url: url, sourceRange: link.range)
        }
        let text = source as NSString
        for match in referencePattern.matches(in: source,
                                              range: NSRange(location: 0, length: text.length)) {
            guard !isExcluded(match.range), match.range(at: 1).length == 0,
                  !isEscaped(text, at: match.range.location) else { continue }
            let label = text.substring(with: match.range(at: 2))
            let explicit = text.substring(with: match.range(at: 3))
            let key = MarkdownAnalysis.normalizedReferenceLabel(explicit.isEmpty ? label : explicit)
            guard let destination = analysis.references[key]?.destination,
                  let url = URL(string: destination) else { continue }
            result.append(MarkdownHoverLink(url: url, sourceRange: match.range))
        }
        return result.sorted { $0.sourceRange.location < $1.sourceRange.location }
    }

    private static func isEscaped(_ source: NSString, at location: Int) -> Bool {
        var cursor = location - 1
        while cursor >= 0 && source.character(at: cursor) == 92 { cursor -= 1 }
        return (location - cursor - 1) % 2 == 1
    }
}

struct MarkdownLinkHoverContent: Equatable, Sendable {
    let title: String
    let excerpt: String
    let destination: String
}

enum MarkdownLinkHoverContentLoader {
    static func preview(for url: URL, context: DocumentContext, currentSource: String,
                        loadsExternalPages: Bool,
                        fetchExternal: @escaping @Sendable (URL) async throws -> String = fetchPageTitle)
        async -> MarkdownLinkHoverContent {
        if let fragment = MarkdownHeadingIndex.localFragment(in: url) {
            return localContent(currentSource, title: context.fileURL?.lastPathComponent ?? "",
                                fragment: fragment, destination: url.absoluteString)
        }
        if let link = MarkdownDocumentLink(url: url, context: context) {
            let file = link.fileURL
            if file == context.fileURL {
                return localContent(currentSource, title: file.lastPathComponent,
                                    fragment: link.fragment, destination: url.relativeString)
            }
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size <= 1_000_000,
               let data = try? Data(contentsOf: file),
               let text = try? MarkdownDocument.decode(data) {
                return localContent(text, title: file.lastPathComponent,
                                    fragment: link.fragment, destination: url.relativeString)
            }
            return MarkdownLinkHoverContent(title: file.lastPathComponent,
                                            excerpt: String(localized: "文書の抜粋を読み込めません"),
                                            destination: url.relativeString)
        }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return MarkdownLinkHoverContent(title: url.lastPathComponent,
                                            excerpt: "", destination: url.absoluteString)
        }
        let title: String
        if loadsExternalPages {
            title = (try? await fetchExternal(url)) ?? url.host ?? url.absoluteString
        } else {
            title = url.host ?? url.absoluteString
        }
        return MarkdownLinkHoverContent(title: title, excerpt: "", destination: url.absoluteString)
    }

    private static func localContent(_ text: String, title: String, fragment: String?,
                                     destination: String) -> MarkdownLinkHoverContent {
        let analysis = MarkdownAnalysis(text)
        let headings = MarkdownOutline.entries(in: analysis)
        let entry = fragment.flatMap { MarkdownHeadingIndex(analysis: analysis).entry(forFragment: $0) }
        if fragment != nil && entry == nil {
            return MarkdownLinkHoverContent(title: title,
                                            excerpt: String(localized: "見出しが見つかりません"),
                                            destination: destination)
        }
        let start = entry?.sourceRange.location ?? 0
        let end = entry.flatMap { selected in
            headings.first(where: {
                $0.sourceRange.location > selected.sourceRange.location && $0.level <= selected.level
            })?.sourceRange.location
        } ?? (text as NSString).length
        let blocks = analysis.blocks.filter { block in
            guard block.sourceRange.location >= start && block.sourceRange.location < end else { return false }
            if block.kind == .paragraph { return true }
            if case .heading = block.kind { return true }
            return false
        }
        let heading = entry?.title ?? blocks.first(where: {
            if case .heading = $0.kind { return true }
            return false
        })?.content ?? title
        let excerpt = blocks.first(where: { $0.kind == .paragraph })?.content ?? ""
        return MarkdownLinkHoverContent(
            title: String(heading.prefix(120)),
            excerpt: String(excerpt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240)),
            destination: destination)
    }

    private static func fetchPageTitle(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue("bytes=0-8191", forHTTPHeaderField: "Range")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<400).contains(http.statusCode),
              http.mimeType?.lowercased().contains("html") == true else {
            throw URLError(.badServerResponse)
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= 8192 { break }
        }
        let html = String(decoding: data, as: UTF8.self)
        guard let range = html.range(of: #"<title[^>]*>(.*?)</title>"#,
                                    options: [.regularExpression, .caseInsensitive]),
              let opening = html[range].range(of: ">"),
              let closing = html[range].range(of: "</title>", options: .caseInsensitive) else {
            throw URLError(.cannotParseResponse)
        }
        let title = html[opening.upperBound..<closing.lowerBound]
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw URLError(.cannotParseResponse) }
        return String(title.prefix(120))
    }
}

@MainActor
final class MarkdownLinkHoverPopover {
    private let popover = NSPopover()
    private var task: Task<Void, Never>?
    private var currentURL: URL?

    func show(_ url: URL?, relativeTo rect: NSRect, of view: NSView,
              context: DocumentContext, source: String, loadsExternalPages: Bool) {
        guard currentURL != url else { return }
        cancel()
        guard let url else { return }
        currentURL = url
        task = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            let content = await MarkdownLinkHoverContentLoader.preview(
                for: url, context: context, currentSource: source,
                loadsExternalPages: loadsExternalPages)
            guard !Task.isCancelled, currentURL == url, view.window != nil else { return }
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: HoverCard(content: content))
            popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        }
    }

    func cancel() {
        guard currentURL != nil || task != nil || popover.isShown else { return }
        task?.cancel()
        task = nil
        currentURL = nil
        popover.close()
    }
}

private struct HoverCard: View {
    let content: MarkdownLinkHoverContent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(content.title).font(.headline).lineLimit(2)
            if !content.excerpt.isEmpty {
                Text(content.excerpt).font(.body).lineLimit(5)
            }
            Text(content.destination)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(width: 320, alignment: .leading)
        .padding(12)
    }
}
