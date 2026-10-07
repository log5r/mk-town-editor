import Foundation

struct MarkdownExportPreset: Codable, Equatable, Identifiable, Sendable {
    enum Font: String, Codable, CaseIterable, Sendable {
        case system
        case serif
        case monospaced

        var title: String {
            switch self {
            case .system: String(localized: "システム")
            case .serif: String(localized: "明朝体")
            case .monospaced: String(localized: "等幅")
            }
        }

        var cssFamily: String {
            switch self {
            case .system: "-apple-system, BlinkMacSystemFont, sans-serif"
            case .serif: "'Hiragino Mincho ProN', 'YuMincho', serif"
            case .monospaced: "ui-monospace, SFMono-Regular, Menlo, monospace"
            }
        }
    }

    var id: UUID
    var name: String
    var bodyWidth: Int
    var fontSize: Int
    var font: Font
    var margin: Int
    var cover: Bool
    var tableOfContents: Bool

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (400...1200).contains(bodyWidth)
            && (12...24).contains(fontSize)
            && (24...96).contains(margin)
    }

    static let standard = MarkdownExportPreset(
        id: UUID(uuidString: "D253A65D-02C4-4077-9969-FBCF564E522D")!, name: "標準",
        bodyWidth: 800, fontSize: 16, font: .system, margin: 48,
        cover: false, tableOfContents: false
    )
}

struct MarkdownExportPresetStore {
    private let defaults: UserDefaults
    private let key = "markdownExportPresets"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> [MarkdownExportPreset] {
        guard let data = defaults.data(forKey: key),
              let presets = try? JSONDecoder().decode([MarkdownExportPreset].self, from: data) else {
            return [.standard]
        }
        return [.standard] + presets.filter { $0.id != MarkdownExportPreset.standard.id && $0.isValid }
    }

    @discardableResult
    func save(_ preset: MarkdownExportPreset) throws -> MarkdownExportPreset {
        guard preset.isValid else { throw PresetError.invalid }
        var presets = load().filter { $0.id != MarkdownExportPreset.standard.id }
        let saved = preset.id == MarkdownExportPreset.standard.id
            ? MarkdownExportPreset(id: UUID(),
                                   name: preset.name == MarkdownExportPreset.standard.name
                                        ? "標準のコピー" : preset.name,
                                   bodyWidth: preset.bodyWidth,
                                   fontSize: preset.fontSize, font: preset.font, margin: preset.margin,
                                   cover: preset.cover, tableOfContents: preset.tableOfContents)
            : preset
        presets.removeAll { $0.id == saved.id || $0.name == saved.name }
        presets.append(saved)
        defaults.set(try JSONEncoder().encode(presets), forKey: key)
        return saved
    }

    enum PresetError: LocalizedError {
        case invalid
        var errorDescription: String? { String(localized: "書き出し設定を確認してください。") }
    }
}
