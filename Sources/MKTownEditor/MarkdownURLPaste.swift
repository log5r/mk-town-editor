import Foundation

enum MarkdownURLPaste {
    static func edit(in text: String, selection: NSRange, pastedText: String) -> MarkdownEdit? {
        let source = text as NSString
        guard selection.location >= 0, selection.length > 0,
              selection.location <= source.length,
              selection.length <= source.length - selection.location,
              !MarkdownLinkSyntax.draft(in: text, selection: selection).isExisting,
              let destination = validURL(pastedText) else { return nil }
        let label = source.substring(with: selection)
        let link = MarkdownLinkSyntax.makeLink(label: label, destination: destination)
        return MarkdownEdit(range: selection, replacement: link,
                            selection: NSRange(location: selection.location + (link as NSString).length,
                                               length: 0))
    }

    static func validURL(_ pastedText: String) -> String? {
        let value = pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https":
            return components.host?.isEmpty == false ? value : nil
        case "mailto":
            return components.path.isEmpty ? nil : value
        default:
            return nil
        }
    }
}
