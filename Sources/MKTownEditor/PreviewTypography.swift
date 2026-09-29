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

    static func themed(_ rendered: NSAttributedString, kind: MarkdownBlock.Kind?,
                       theme: PreviewTheme) -> NSAttributedString {
        guard theme != .system, rendered.length > 0,
              let bodyColor = theme.bodyColor,
              let headingColor = theme.headingColor,
              let codeColor = theme.codeColor,
              let codeBackground = theme.codeBackground,
              let linkColor = theme.linkColor else { return rendered }
        let result = NSMutableAttributedString(attributedString: rendered)
        let range = NSRange(location: 0, length: result.length)
        let color: NSColor
        switch kind {
        case .heading: color = headingColor
        case .codeBlock: color = codeColor
        default: color = bodyColor
        }
        result.addAttribute(.foregroundColor, value: color, range: range)
        if kind == .codeBlock {
            result.addAttribute(.backgroundColor, value: codeBackground, range: range)
        }
        result.enumerateAttribute(.link, in: range) { value, subrange, _ in
            if value != nil {
                result.addAttribute(.foregroundColor, value: linkColor, range: subrange)
            }
        }
        result.enumerateAttribute(.inlinePresentationIntent, in: range) { value, subrange, _ in
            let intent = (value as? InlinePresentationIntent) ??
                (value as? NSNumber).map { InlinePresentationIntent(rawValue: $0.uintValue) }
            if intent?.contains(.code) == true {
                result.addAttribute(.backgroundColor, value: codeBackground, range: subrange)
                result.addAttribute(.foregroundColor, value: codeColor, range: subrange)
            }
        }
        return result
    }

    static func contrastRatio(_ foreground: NSColor, _ background: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            let rgb = color.usingColorSpace(.sRGB)!
            let values = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { value -> Double in
                let component = Double(value)
                return component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * values[0] + 0.7152 * values[1] + 0.0722 * values[2]
        }
        let first = luminance(foreground)
        let second = luminance(background)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}
