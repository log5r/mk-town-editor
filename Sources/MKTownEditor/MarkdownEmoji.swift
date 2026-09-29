import Foundation

/// The app's offline shortcode vocabulary. Unknown names remain source text.
enum MarkdownEmoji {
    static let names: [String: String] = [
        "100": "💯", "alarm_clock": "⏰", "apple": "🍎", "arrow_down": "⬇️",
        "arrow_left": "⬅️", "arrow_right": "➡️", "arrow_up": "⬆️", "art": "🎨",
        "book": "📖", "bulb": "💡", "calendar": "📅", "camera": "📷",
        "cat": "🐱", "check": "✔️", "checkered_flag": "🏁", "clap": "👏",
        "cloud": "☁️", "coffee": "☕️", "computer": "💻", "construction": "🚧",
        "cry": "😢", "dog": "🐶", "email": "✉️", "eyes": "👀",
        "fire": "🔥", "globe_with_meridians": "🌐", "grin": "😁", "heart": "❤️",
        "heart_eyes": "😍", "hourglass": "⌛️", "information_source": "ℹ️", "key": "🔑",
        "link": "🔗", "lock": "🔒", "memo": "📝", "musical_note": "🎵",
        "ok_hand": "👌", "package": "📦", "pencil": "✏️", "question": "❓",
        "rocket": "🚀", "search": "🔎", "smile": "😄", "smiley": "😃",
        "sparkles": "✨", "star": "⭐️", "sunny": "☀️", "tada": "🎉",
        "thumbsdown": "👎", "thumbsup": "👍", "warning": "⚠️", "wave": "👋",
        "white_check_mark": "✅", "x": "❌", "zap": "⚡️"
    ]

    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_]):([a-z0-9_+-]+):"#)
    private static let linkDestination = try! NSRegularExpression(
        pattern: #"\]\(([^)\r\n]*)\)"#)
    private static let htmlTag = try! NSRegularExpression(pattern: #"<[^>\r\n]+>"#)

    static func replace(in source: String) -> String {
        let text = source as NSString
        let fullRange = NSRange(location: 0, length: text.length)
        let protected = MarkdownInlineSyntax.codeSpanRanges(in: source) +
            linkDestination.matches(in: source, range: fullRange).map { $0.range(at: 1) } +
            htmlTag.matches(in: source, range: fullRange).map(\.range)
        let output = NSMutableString(string: source)
        for match in pattern.matches(in: source, range: fullRange).reversed() {
            guard !protected.contains(where: { NSLocationInRange(match.range.location, $0) }),
                  !isEscaped(text, at: match.range.location),
                  let emoji = names[text.substring(with: match.range(at: 1))] else { continue }
            output.replaceCharacters(in: match.range, with: emoji)
        }
        return output as String
    }

    static func completions(in source: String, range: NSRange) -> [String] {
        let text = source as NSString
        guard range.location >= 0, NSMaxRange(range) <= text.length,
              range.length > 0 else { return [] }
        let prefix = text.substring(with: range)
        guard prefix.first == ":", prefix.count <= 33,
              prefix.dropFirst().allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "+" || $0 == "-") }),
              !isEscaped(text, at: range.location),
              !MarkdownInlineSyntax.codeSpanRanges(in: source).contains(where: {
                  NSLocationInRange(range.location, $0)
              }),
              !MarkdownAnalysis(source).blocks.contains(where: {
                  $0.kind == .codeBlock && NSLocationInRange(range.location, $0.sourceRange)
              }) else { return [] }
        let query = String(prefix.dropFirst())
        return names.keys.filter { $0.hasPrefix(query) }.sorted().prefix(30).map { ":\($0):" }
    }

    private static func isEscaped(_ source: NSString, at index: Int) -> Bool {
        var cursor = index - 1
        while cursor >= 0, source.character(at: cursor) == 92 { cursor -= 1 }
        return (index - cursor - 1) % 2 == 1
    }
}
