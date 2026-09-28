import AppKit

@MainActor
enum PreviewTypography {
    static func scaled(_ rendered: NSAttributedString, by zoom: Double) -> NSAttributedString {
        guard zoom != 1, rendered.length > 0 else { return rendered }
        let result = NSMutableAttributedString(attributedString: rendered)
        var fonts: [(NSRange, NSFont)] = []
        result.enumerateAttribute(.font, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            if let font = value as? NSFont { fonts.append((range, font)) }
        }
        for (range, font) in fonts {
            result.addAttribute(.font,
                                value: NSFontManager.shared.convert(font, toSize: font.pointSize * zoom),
                                range: range)
        }
        return result
    }
}
