import AppKit
import Foundation

/// A JSON-only extension. Its data is copied into app settings; no code is loaded.
struct DeclarativeExtension: Codable, Equatable, Identifiable {
    struct Theme: Codable, Equatable, Hashable, Sendable {
        var name: String
        var background: String
        var body: String
        var heading: String
        var code: String
        var link: String
        var codeBackground: String

        func color(_ keyPath: KeyPath<Self, String>) -> NSColor? {
            Self.parse(self[keyPath: keyPath])
        }

        static func parse(_ value: String) -> NSColor? {
            let characters = Array(value)
            guard characters.count == 7, characters.first == "#",
                  let red = UInt8(String(characters[1...2]), radix: 16),
                  let green = UInt8(String(characters[3...4]), radix: 16),
                  let blue = UInt8(String(characters[5...6]), radix: 16) else { return nil }
            return NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255,
                           blue: CGFloat(blue) / 255, alpha: 1)
        }

        @MainActor func validate() throws {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name.count <= 80 else { throw ExtensionError.invalidTheme }
            let background = try Self.parse(background).unwrap(or: ExtensionError.invalidTheme)
            for value in [body, heading, code, link] {
                let color = try Self.parse(value).unwrap(or: ExtensionError.invalidTheme)
                guard PreviewTypography.contrastRatio(color, background) >= 7 else {
                    throw ExtensionError.lowContrast
                }
            }
            let codeBackground = try Self.parse(codeBackground).unwrap(or: ExtensionError.invalidTheme)
            let codeColor = try Self.parse(code).unwrap(or: ExtensionError.invalidTheme)
            guard PreviewTypography.contrastRatio(codeColor, codeBackground) >= 7 else {
                throw ExtensionError.lowContrast
            }
        }
    }

    struct Snippet: Codable, Equatable, Identifiable {
        var id: UUID
        var trigger: String
        var template: String

        init(id: UUID = UUID(), trigger: String, template: String) {
            self.id = id
            self.trigger = trigger
            self.template = template
        }

        enum CodingKeys: CodingKey { case id, trigger, template }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            trigger = try values.decode(String.self, forKey: .trigger)
            template = try values.decode(String.self, forKey: .template)
        }
    }

    var schemaVersion: Int
    var id: String
    var name: String
    var theme: Theme?
    var snippets: [Snippet]

    enum CodingKeys: CodingKey { case schemaVersion, id, name, theme, snippets }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        theme = try values.decodeIfPresent(Theme.self, forKey: .theme)
        snippets = try values.decodeIfPresent([Snippet].self, forKey: .snippets) ?? []
    }

    enum ExtensionError: LocalizedError {
        case tooLarge, invalidManifest, invalidTheme, lowContrast, invalidSnippet

        var errorDescription: String? {
            switch self {
            case .tooLarge: String(localized: "拡張ファイルは100KB以下にしてください。")
            case .invalidManifest: String(localized: "拡張ファイルの形式を確認してください。")
            case .invalidTheme: String(localized: "テーマの色指定を確認してください。")
            case .lowContrast: String(localized: "テーマの文字色と背景色のコントラストを高くしてください。")
            case .invalidSnippet: String(localized: "スニペットの短縮語と本文を確認してください。")
            }
        }
    }

    @MainActor static func load(from url: URL) throws -> Self {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= 100_000 else { throw ExtensionError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= 100_000 else { throw ExtensionError.tooLarge }
        let package = try JSONDecoder().decode(Self.self, from: data)
        try package.validate()
        return package
    }

    @MainActor func validate() throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard schemaVersion == 1, !id.isEmpty, id.count <= 100,
              id.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 80, theme != nil || !snippets.isEmpty else {
            throw ExtensionError.invalidManifest
        }
        try theme?.validate()
        guard snippets.count <= 100,
              Set(snippets.map(\.trigger)).count == snippets.count,
              snippets.allSatisfy({ !$0.trigger.isEmpty && $0.trigger.count <= 40 &&
                  !$0.trigger.contains(where: \.isWhitespace) &&
                  !$0.template.isEmpty && $0.template.count <= 4_000 &&
                  !$0.template.contains("\0") }) else { throw ExtensionError.invalidSnippet }
    }
}

private extension Optional {
    func unwrap(or error: Error) throws -> Wrapped {
        guard let self else { throw error }
        return self
    }
}
