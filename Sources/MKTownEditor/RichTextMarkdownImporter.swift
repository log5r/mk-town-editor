import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum RichTextImportFormat {
    case html
    case rtf

    init?(url: URL) {
        switch url.pathExtension.lowercased() {
        case "html", "htm": self = .html
        case "rtf": self = .rtf
        default: return nil
        }
    }

    var documentType: NSAttributedString.DocumentType {
        self == .html ? .html : .rtf
    }
}

struct RichTextImportResult {
    let markdown: String
    let warnings: [String]
}

enum RichTextImportError: LocalizedError {
    case unsupportedFormat
    case invalidDocument
    case documentTooLarge

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: String(localized: "HTMLまたはRTFファイルを選んでください。")
        case .invalidDocument: String(localized: "ファイルを読み取れませんでした。")
        case .documentTooLarge: String(localized: "取り込めるファイルは10MBまでです。")
        }
    }
}

@MainActor
enum RichTextMarkdownImporter {
    static func convert(_ data: Data, format: RichTextImportFormat) throws -> RichTextImportResult {
        guard data.count <= 10_000_000 else { throw RichTextImportError.documentTooLarge }
        var warnings: [String] = []
        var content = data
        if format == .html {
            let html = try decodeHTML(data)
            let sanitized = sanitizeHTML(html)
            content = Data(sanitized.html.utf8)
            if sanitized.images > 0 {
                warnings.append(String(localized: "画像\(sanitized.images)件は本文へコピーせず、位置をプレースホルダーで示します。"))
            }
            if html.range(of: "<table", options: .caseInsensitive) != nil {
                warnings.append(String(localized: "表のセル構造は保持されず、本文テキストに変換されます。"))
            }
            if html.range(of: "<style", options: .caseInsensitive) != nil ||
                html.range(of: "<link", options: .caseInsensitive) != nil {
                warnings.append(String(localized: "CSSによる配色・余白などは取り込みません。"))
            }
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: format.documentType,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let attributed = try? NSAttributedString(data: content, options: options,
                                                        documentAttributes: nil) else {
            throw RichTextImportError.invalidDocument
        }
        var hasAttachment = false
        var hasDecoration = false
        var hasRelativeLink = false
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attrs, _, _ in
            if attrs[.attachment] != nil { hasAttachment = true }
            if attrs[.underlineStyle] != nil || attrs[.strikethroughStyle] != nil ||
                attrs[.backgroundColor] != nil { hasDecoration = true }
            if let link = attrs[.link],
               let value = (link as? URL)?.absoluteString ?? link as? String,
               URL(string: value)?.scheme == nil { hasRelativeLink = true }
        }
        if hasAttachment && format == .rtf {
            warnings.append(String(localized: "RTF内の添付画像は本文へコピーせず、位置をプレースホルダーで示します。"))
        }
        if hasDecoration {
            warnings.append(String(localized: "下線・打ち消し線・背景色など一部の装飾は失われます。"))
        }
        if hasRelativeLink {
            warnings.append(String(localized: "相対リンクは移動先の基準が異なるため、リンク先を付けずに文字だけ取り込みます。"))
        }
        let markdown = markdown(from: attributed)
        guard !markdown.isEmpty else { throw RichTextImportError.invalidDocument }
        return RichTextImportResult(markdown: markdown, warnings: warnings)
    }

    private static func decodeHTML(_ data: Data) throws -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            guard let html = String(data: data, encoding: .utf16) else {
                throw RichTextImportError.invalidDocument
            }
            return html
        }
        let prefix = String(decoding: data.prefix(4096), as: UTF8.self)
        let pattern = try! NSRegularExpression(pattern: #"(?i)charset\s*=\s*["']?([a-z0-9_-]+)"#)
        let match = pattern.firstMatch(in: prefix,
            range: NSRange(location: 0, length: (prefix as NSString).length))
        let charset = match.map { (prefix as NSString).substring(with: $0.range(at: 1)).lowercased() }
        let encoding: String.Encoding
        switch charset {
        case "shift_jis", "shift-jis", "sjis": encoding = .shiftJIS
        case "windows-1252", "iso-8859-1": encoding = .windowsCP1252
        case "utf-16", "utf-16le", "utf-16be": encoding = .utf16
        default: encoding = .utf8
        }
        guard let html = String(data: data, encoding: encoding) else {
            throw RichTextImportError.invalidDocument
        }
        return html
    }

    private static func markdown(from attributed: NSAttributedString) -> String {
        let source = attributed.string as NSString
        var paragraphs: [String] = []
        var cursor = 0
        while cursor < source.length {
            var start = 0
            var end = 0
            var contentsEnd = 0
            source.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                                for: NSRange(location: cursor, length: 0))
            let content = attributed.attributedSubstring(
                from: NSRange(location: start, length: contentsEnd - start))
            let rendered = inline(content).trimmingCharacters(in: .whitespacesAndNewlines)
            if rendered.isEmpty {
                if paragraphs.last != "" { paragraphs.append("") }
            } else {
                let plain = content.string.trimmingCharacters(in: .whitespaces)
                let heading = (1...6).first { plain.hasPrefix("\u{E000}MKTOWN-H\($0)\u{E001}") }
                let prefix: String
                if let heading {
                    prefix = String(repeating: "#", count: heading) + " "
                } else if plain.hasPrefix("•") {
                    prefix = "- "
                } else if let font = firstFont(in: content),
                          NSFontManager.shared.traits(of: font).contains(.boldFontMask),
                          font.pointSize >= 22 {
                    prefix = font.pointSize >= 30 ? "# " : "## "
                } else {
                    prefix = ""
                }
                let withoutHeading = heading.map {
                    rendered.replacingOccurrences(of: "\u{E000}MKTOWN-H\($0)\u{E001}", with: "")
                } ?? rendered
                let line = plain.hasPrefix("•")
                    ? String(withoutHeading.drop(while: { $0 == "•" || $0 == " " || $0 == "\t" }))
                    : withoutHeading
                paragraphs.append(prefix + line)
            }
            cursor = end
        }
        let meaningful = paragraphs.filter { !$0.isEmpty }
        guard let first = meaningful.first else { return "" }
        var result = first
        for index in 1..<meaningful.count {
            let previous = meaningful[index - 1]
            let current = meaningful[index]
            result += previous.hasPrefix("- ") && current.hasPrefix("- ") ? "\n" : "\n\n"
            result += current
        }
        return result
    }

    private static func firstFont(in content: NSAttributedString) -> NSFont? {
        guard content.length > 0 else { return nil }
        return content.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    }

    private static func inline(_ content: NSAttributedString) -> String {
        var output = ""
        content.enumerateAttributes(in: NSRange(location: 0, length: content.length)) { attrs, range, _ in
            if attrs[.attachment] != nil {
                output += "[画像]"
                return
            }
            var text = (content.string as NSString).substring(with: range)
                .replacingOccurrences(of: "\u{FFFC}", with: "[画像]")
            text = text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "*", with: "\\*")
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
            if let font = attrs[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                if traits.contains(.fixedPitchFontMask) {
                    text = "`\(text.replacingOccurrences(of: "`", with: "\\`"))`"
                } else {
                    if traits.contains(.boldFontMask) { text = "**\(text)**" }
                    if traits.contains(.italicFontMask) { text = "*\(text)*" }
                }
            }
            if let value = attrs[.link],
               let url = (value as? URL)?.absoluteString ?? value as? String,
               ["http", "https", "mailto"].contains(URL(string: url)?.scheme?.lowercased() ?? "") {
                text = "[\(text)](\(MarkdownLinkSyntax.escapeDestination(url)))"
            }
            output += text
        }
        return output
    }

    private static func sanitizeHTML(_ html: String) -> (html: String, images: Int) {
        var result = html
        for pattern in [#"(?is)<script\b[^>]*>.*?</script>"#,
                        #"(?is)<style\b[^>]*>.*?</style>"#,
                        #"(?is)<link\b[^>]*>"#] {
            result = result.replacingOccurrences(of: pattern, with: "",
                                                 options: .regularExpression)
        }
        let imagePattern = try! NSRegularExpression(pattern: #"(?is)<img\b[^>]*>"#)
        let matches = imagePattern.matches(in: result,
            range: NSRange(location: 0, length: (result as NSString).length))
        for match in matches.reversed() {
            let tag = (result as NSString).substring(with: match.range)
            let altPattern = try! NSRegularExpression(pattern: #"(?i)\balt\s*=\s*["']([^"']*)["']"#)
            let altMatch = altPattern.firstMatch(in: tag,
                range: NSRange(location: 0, length: (tag as NSString).length))
            let alt = altMatch.map { (tag as NSString).substring(with: $0.range(at: 1)) } ?? "画像"
            let safe = alt.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            result = (result as NSString).replacingCharacters(in: match.range,
                with: "<span>[画像: \(safe)]</span>")
        }
        let headings = try! NSRegularExpression(pattern: #"(?i)<h([1-6])\b[^>]*>"#)
        let headingMatches = headings.matches(in: result,
            range: NSRange(location: 0, length: (result as NSString).length))
        for match in headingMatches.reversed() {
            let level = (result as NSString).substring(with: match.range(at: 1))
            result = (result as NSString).replacingCharacters(in: match.range,
                with: "<p>\u{E000}MKTOWN-H\(level)\u{E001}")
        }
        result = result.replacingOccurrences(of: #"(?i)</h[1-6]\s*>"#, with: "</p>",
                                             options: .regularExpression)
        return (result, matches.count)
    }
}

struct RichTextImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var currentText: String
    @State private var result: RichTextImportResult?
    @State private var sourceName: String?
    @State private var errorMessage: String?
    @State private var isWorking = false
    let onApply: (String, String) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HTML・RTFからMarkdownへ取り込む").font(.headline)
            Button("ファイルを選択…") { chooseFile() }.disabled(isWorking)
            if let sourceName { Text(sourceName).font(.caption).foregroundStyle(.secondary) }
            if isWorking { ProgressView("読み込み中") }
            if let result {
                Text("変換後のMarkdown（\(result.markdown.count)文字）")
                    .font(.subheadline.weight(.semibold))
                ScrollView {
                    Text(String(result.markdown.prefix(30_000)))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 300)
                .border(Color.secondary.opacity(0.3))
                if result.markdown.count > 30_000 {
                    Text("表示は先頭30,000文字までです。適用時は全文を取り込みます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(result.warnings, id: \.self) { warning in
                    Text(warning).font(.caption).foregroundStyle(.orange)
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("現在の書類へ適用") {
                    guard let result else { return }
                    if onApply(result.markdown, currentText) { dismiss() }
                    else { errorMessage = String(localized: "本文が変更されたか編集中のため、適用できませんでした。") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(result == nil || isWorking)
            }
        }
        .padding(20)
        .frame(width: 700)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html, .rtf]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let format = RichTextImportFormat(url: url) else {
                errorMessage = RichTextImportError.unsupportedFormat.localizedDescription
                return
            }
            isWorking = true
            result = nil
            errorMessage = nil
            Task {
                do {
                    let data = try await Task.detached(priority: .userInitiated) {
                        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                           size > 10_000_000 { throw RichTextImportError.documentTooLarge }
                        return try Data(contentsOf: url)
                    }.value
                    result = try RichTextMarkdownImporter.convert(data, format: format)
                    sourceName = url.lastPathComponent
                } catch { errorMessage = error.localizedDescription }
                isWorking = false
            }
        }
    }
}
