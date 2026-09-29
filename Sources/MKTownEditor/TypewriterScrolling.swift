import AppKit

enum TypewriterScrolling {
    static let manualScrollPause: TimeInterval = 1.5

    static func targetOrigin(lineMidY: CGFloat, visibleHeight: CGFloat,
                             documentHeight: CGFloat, currentOrigin: CGFloat,
                             secondsSinceManualScroll: TimeInterval,
                             isUserScrolling: Bool, isComposing: Bool) -> CGFloat? {
        guard visibleHeight > 0, documentHeight > visibleHeight,
              !isUserScrolling, !isComposing,
              secondsSinceManualScroll >= manualScrollPause else { return nil }
        let maximum = max(0, documentHeight - visibleHeight)
        let target = min(max(0, lineMidY - visibleHeight / 2), maximum)
        guard abs(target - currentOrigin) > visibleHeight * 0.1 else { return nil }
        return target
    }

    @MainActor
    static func lineMidY(for textView: NSTextView, at location: Int) -> CGFloat? {
        guard let manager = textView.layoutManager,
              textView.textContainer != nil else { return nil }
        let length = (textView.string as NSString).length
        guard length > 0, location >= 0, location <= length else { return nil }
        if location == length,
           let last = textView.string.utf16.last, last == 10 || last == 13,
           !manager.extraLineFragmentRect.isEmpty {
            return textView.textContainerOrigin.y + manager.extraLineFragmentRect.midY
        }
        let glyph = manager.glyphIndexForCharacter(at: min(location, length - 1))
        let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return textView.textContainerOrigin.y + rect.midY
    }
}
