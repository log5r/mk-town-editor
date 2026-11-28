import Foundation

struct SettingsArchive {
    enum Category: String, CaseIterable, Identifiable {
        case general, editor, preview, themes, snippets, terminology, shortcuts, exportPresets, extensions

        var id: Self { self }
    }

    struct Snapshot: Equatable {
        var app = AppEditorSettings()
        var encodingCandidates = MarkdownTextEncoding.defaultDetectionOrder
        var exportPresets: [MarkdownExportPreset] = []

        fileprivate var disabledLintRules: [MarkdownLintRule]? {
            get { app.disabledLintRules?.sorted { $0.rawValue < $1.rawValue } }
            set { app.disabledLintRules = newValue.map(Set.init) }
        }
    }

    private let contents: Contents

    var categories: Set<Category> { Set(contents.included.keys) }

    init(snapshot: Snapshot, categories: Set<Category>) throws {
        guard !categories.isEmpty else { throw ArchiveError.noSettings }
        contents = Contents(snapshot: snapshot, categories: categories)
    }

    @MainActor
    init(data: Data) throws {
        do {
            contents = try JSONDecoder().decode(Contents.self, from: data)
        } catch is DecodingError {
            throw ArchiveError.invalidFile
        }
        guard !contents.included.isEmpty else { throw ArchiveError.noSettings }
        try contents.validate()
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(contents)
    }

    func differences(from current: Snapshot) -> [Category: [String]] {
        var differences: [Category: [String]] = [:]
        for (category, fields) in contents.included {
            differences[category] = fields.flatMap { $0.difference(current, contents.snapshot) }
        }
        return differences
    }

    func merging(into current: Snapshot, categories: Set<Category>) -> Snapshot {
        copying(contents.snapshot, into: current, categories: categories)
    }

    func affectedSettingsMatch(_ before: Snapshot, _ current: Snapshot, categories: Set<Category>) -> Bool {
        copying(before, into: Snapshot(), categories: categories)
            == copying(current, into: Snapshot(), categories: categories)
    }

    private func copying(_ source: Snapshot, into destination: Snapshot, categories: Set<Category>) -> Snapshot {
        var merged = destination
        for category in categories {
            for field in contents.included[category] ?? [] {
                field.copy(source, &merged)
            }
        }
        return merged
    }

    enum ArchiveError: LocalizedError {
        case invalidFile, noSettings

        var errorDescription: String? {
            switch self {
            case .invalidFile: String(localized: "設定ファイルの形式や値を確認してください。")
            case .noSettings: String(localized: "読み書きできる設定項目がありません。")
            }
        }
    }
}

private extension SettingsArchive {
    struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    struct Contents: Codable {
        static let format = "MKTownEditor-settings"
        enum CodingKeys: String, CodingKey { case format, categories }

        var snapshot: Snapshot
        let included: [Category: [Field]]

        init(snapshot: Snapshot, categories: Set<Category>) {
            self.snapshot = snapshot
            included = Dictionary(uniqueKeysWithValues: categories.map { ($0, $0.fields) })
        }

        init(from decoder: Decoder) throws {
            let root = try decoder.container(keyedBy: CodingKeys.self)
            guard try root.decode(String.self, forKey: .format) == Self.format else {
                throw ArchiveError.invalidFile
            }
            let categories = try root.nestedContainer(keyedBy: Key.self, forKey: .categories)
            var snapshot = Snapshot()
            var included: [Category: [Field]] = [:]
            for category in Category.allCases {
                let key = Key(stringValue: category.rawValue)
                guard categories.contains(key) else { continue }
                let values = try categories.nestedContainer(keyedBy: Key.self, forKey: key)
                let fields = try category.fields.filter { field in
                    guard values.contains(field.key) else { return false }
                    return try field.decode(values, &snapshot)
                }
                guard !fields.isEmpty else { continue }
                included[category] = fields
            }
            snapshot.app.restoreNavyEditorThemes()
            self.snapshot = snapshot
            self.included = included
        }

        func encode(to encoder: Encoder) throws {
            var root = encoder.container(keyedBy: CodingKeys.self)
            try root.encode(Self.format, forKey: .format)
            var categories = root.nestedContainer(keyedBy: Key.self, forKey: .categories)
            for (category, fields) in included {
                var values = categories.nestedContainer(keyedBy: Key.self, forKey: Key(stringValue: category.rawValue))
                for field in fields { try field.encode(snapshot, &values) }
            }
        }

        @MainActor func validate() throws {
            let app = snapshot.app
            let extensions = app.extensionPackages ?? []
            guard Set(extensions.map(\.id)).count == extensions.count,
                  Set(snapshot.encodingCandidates).count == snapshot.encodingCandidates.count,
                  Set((app.terminologyEntries ?? []).map(\.id)).count == (app.terminologyEntries ?? []).count,
                  MarkdownExportPresetStore.validCustomPresets(snapshot.exportPresets) else {
                throw ArchiveError.invalidFile
            }
            for item in extensions { try item.validate() }
            let shorthandIdentifiers = (app.snippets ?? []).map(\.id) + extensions.flatMap { $0.snippets.map(\.id) }
            guard Set(shorthandIdentifiers).count == shorthandIdentifiers.count else { throw ArchiveError.invalidFile }
            if let overrides = app.shortcutOverrides {
                for command in EditorShortcutRegistry.commands {
                    guard let chord = overrides[command.toolbarIdentifier],
                          EditorShortcutRegistry.shortcut(for: command, overrides: overrides) != nil
                    else { continue }
                    try EditorShortcutRegistry.validate(chord, for: command, overrides: overrides)
                }
            }
            for target in ThemeTarget.allCases {
                for slot in ThemeSlot.allCases {
                    let choice = app[keyPath: target.keyPath(for: slot)]
                    if target == .preview, choice == .navy { throw ArchiveError.invalidFile }
                    if case .extensionTheme(let theme)? = choice {
                        try theme.validate()
                    }
                }
            }
        }
    }

    /// Each field opts in to transfer. Fields missing from the file keep their local values.
    struct Field {
        let key: Key
        let encode: (Snapshot, inout KeyedEncodingContainer<Key>) throws -> Void
        let decode: (KeyedDecodingContainer<Key>, inout Snapshot) throws -> Bool
        let copy: (Snapshot, inout Snapshot) -> Void
        let difference: (Snapshot, Snapshot) -> [String]

        init<Value: Codable & Equatable>(
            _ name: String, _ path: WritableKeyPath<Snapshot, Value>, _ label: LocalizedStringResource,
            validate: @escaping (Value) -> Bool = { _ in true },
            summarize: @escaping (Value) -> String? = { _ in nil },
            read: @escaping (KeyedDecodingContainer<Key>, Key) throws -> Value? = {
                .some(try $0.decode(Value.self, forKey: $1))
            },
            changes: ((Value, Value) -> [String])? = nil
        ) {
            let key = Key(stringValue: name)
            self.key = key
            encode = { snapshot, values in
                // Encoding the optional value itself preserves an explicit reset as JSON null.
                try values.encode(snapshot[keyPath: path], forKey: key)
            }
            decode = { values, snapshot in
                guard let value = try read(values, key) else { return false }
                guard validate(value) else { throw ArchiveError.invalidFile }
                snapshot[keyPath: path] = value
                return true
            }
            copy = { archived, current in current[keyPath: path] = archived[keyPath: path] }
            difference = { current, archived in
                let old = current[keyPath: path]
                let new = archived[keyPath: path]
                guard old != new else { return [] }
                let title = String(localized: label)
                if let items = changes?(old, new), !items.isEmpty { return items }
                guard let before = summarize(old), let after = summarize(new), before != after else { return [title] }
                return [changedValue(title, before: before, after: after)]
            }
        }

        init<Value: Codable & Equatable & RawRepresentable>(
            _ name: String, enumPath path: WritableKeyPath<Snapshot, Value?>, _ label: LocalizedStringResource,
            summarize: @escaping (Value) -> String
        ) where Value.RawValue == String {
            self.init(name, path, label, summarize: optional(summarize), read: { values, key in
                guard let raw = try values.decode(String?.self, forKey: key) else { return .some(nil) }
                return Value(rawValue: raw).map(Optional.some)
            })
        }
    }
}

private extension SettingsArchive.Category {
    typealias Field = SettingsArchive.Field

    var fields: [Field] {
        switch self {
        case .general:
            [
                Field("defaultMode", \.app.defaultMode, "既定の表示モード", summarize: { $0.label },
                      read: { values, key in EditorMode(rawValue: try values.decode(String.self, forKey: key)) }),
                Field("documentOpeningMode", enumPath: \.app.documentOpeningMode, "書類を開いたときの表示",
                      summarize: { $0.title }),
                Field("attachmentDirectory", enumPath: \.app.attachmentDirectory, "添付ファイルの保存先",
                      summarize: { $0.title }),
                Field("imageImportMode", enumPath: \.app.imageImportMode, "画像の取り込み方法", summarize: { $0.title }),
                Field("markdownDialect", enumPath: \.app.markdownDialect, "Markdown構文", summarize: { $0.title }),
                Field("asksAboutMixedNewlines", \.app.asksAboutMixedNewlines, "混在する改行コードの確認",
                      summarize: { onOff($0 ?? true) }),
                Field("loadsRemoteImages", \.app.loadsRemoteImages, "リモート画像の読み込み",
                      summarize: { onOff($0 ?? false) }),
                Field("loadsExternalLinkPreviews", \.app.loadsExternalLinkPreviews, "外部リンクのページ情報の取得",
                      summarize: { onOff($0 ?? false) }),
                Field("encodingCandidates", \.encodingCandidates, "文字コードの自動判別",
                      summarize: { collection($0.map(\.title)) }, read: { values, key in
                          let names = try values.decode([String].self, forKey: key)
                          let encodings = names.compactMap(MarkdownTextEncoding.init(rawValue:))
                          return !names.isEmpty && encodings.isEmpty ? nil : encodings
                      }),
            ]
        case .editor:
            [
                Field("fontChoice", enumPath: \.app.fontChoice, "標準装備のフォント", summarize: { $0.title }),
                Field("fontFamily", \.app.fontFamily, "インストール済みのフォント", summarize: optional { $0 }),
                Field("fontSize", \.app.fontSize, "文字サイズ", validate: (10...32).contains,
                      summarize: { $0.formatted() }),
                Field("lineSpacing", \.app.lineSpacing, "行間", validate: (0...12).contains,
                      summarize: { $0.formatted() }),
                Field("horizontalMargin", \.app.horizontalMargin, "左右の余白",
                      validate: within(8...48), summarize: optional { $0.formatted() }),
                Field("verticalMargin", \.app.verticalMargin, "上下の余白",
                      validate: within(8...48), summarize: optional { $0.formatted() }),
                Field("editorZoom", \.app.editorZoom, "エディタの拡大率",
                      validate: within(0.5...2), summarize: optional { $0.formatted(.percent) }),
                Field("wrapsLines", \.app.wrapsLines, "行の折り返し", summarize: onOff),
                Field("showsLineNumbers", \.app.showsLineNumbers, "行番号", summarize: optional(onOff)),
                Field("showsInvisibleCharacters", \.app.showsInvisibleCharacters, "不可視文字",
                      summarize: optional(onOff)),
                Field("showsIndentGuides", \.app.showsIndentGuides, "インデントガイド", summarize: optional(onOff)),
                Field("showsMinimap", \.app.showsMinimap, "ミニマップ", summarize: optional(onOff)),
                Field("usesInlineLivePresentation", \.app.usesInlineLivePresentation, "Markdown記号の強調の抑制",
                      summarize: optional(onOff)),
                Field("usesTypewriterMode", \.app.usesTypewriterMode, "タイプライターモード", summarize: optional(onOff)),
                Field("indentationStyle", enumPath: \.app.indentationStyle, "字下げに使う文字", summarize: { $0.title }),
                Field("detectsIndentation", \.app.detectsIndentation, "字下げの自動検出", summarize: optional(onOff)),
                Field("tabWidth", \.app.tabWidth, "タブ幅", validate: within(2...8),
                      summarize: optional { $0.formatted() }),
                Field("listIndentWidth", \.app.listIndentWidth, "リストの字下げ", validate: within(2...8),
                      summarize: optional { $0.formatted() }),
                Field("codeIndentWidth", \.app.codeIndentWidth, "コードの字下げ", validate: within(2...8),
                      summarize: optional { $0.formatted() }),
                Field("tableAddsRowOnTab", \.app.tableAddsRowOnTab, "表の最後でTabを押したときの行追加",
                      summarize: optional(onOff)),
                Field("trimsTrailingWhitespaceOnSave", \.app.trimsTrailingWhitespaceOnSave, "保存時の行末の空白削除",
                      summarize: optional(onOff)),
                Field("trimsWhitespaceOnlyLines", \.app.trimsWhitespaceOnlyLines, "空白だけの行の空白削除",
                      summarize: optional(onOff)),
                Field("textTransformation", \.app.textTransformation, "字種とUnicodeの変換"),
                Field("wordCountMode", enumPath: \.app.wordCountMode, "語数の数え方", summarize: { $0.title }),
                Field("readingEstimate", \.app.readingEstimate, "読む時間と音読時間", validate: validReadingEstimate,
                      summarize: optional(readingEstimateSummary), read: { values, key in
                          try readLanguageSetting(ReadingEstimateSettings.self, language: ReadingLanguage.self, values, key)
                      }),
                Field("disabledLintRules", \.disabledLintRules, "無効にしたMarkdownの検査項目",
                      summarize: { collection(($0 ?? []).map(\.title)) }, read: { values, key in
                          guard let names = try values.decode([String]?.self, forKey: key) else { return .some(nil) }
                          let rules = names.compactMap(MarkdownLintRule.init(rawValue:))
                          return !names.isEmpty && rules.isEmpty ? nil : .some(rules)
                      }),
                Field("proofing", \.app.proofing, "スペルチェックと自動訂正",
                      summarize: optional(proofingSummary), read: { values, key in
                          try readLanguageSetting(EditorProofingSettings.self, language: ProofingLanguage.self, values, key)
                      }),
            ]
        case .preview:
            [
                Field("previewBodyWidth", \.app.previewBodyWidth, "本文の最大幅", validate: within(560...1200),
                      summarize: optional { $0.formatted() }),
                Field("previewZoom", \.app.previewZoom, "プレビューの拡大率",
                      validate: within(0.5...2), summarize: optional { $0.formatted(.percent) }),
                Field("preservesSoftLineBreaksInPreview", \.app.preservesSoftLineBreaksInPreview, "本文の改行の保持",
                      summarize: optional(onOff)),
                Field("showsFrontMatterInPreview", \.app.showsFrontMatterInPreview, "フロントマターの表示",
                      summarize: optional(onOff)),
                Field("formatsFrontMatterInPreview", \.app.formatsFrontMatterInPreview, "フロントマターの整形",
                      summarize: optional(onOff)),
            ]
        case .themes:
            [
                Field("editorTheme", \.app.editorTheme, "エディタの固定配色", summarize: optional { $0.title }, read: readTheme),
                Field("editorThemeFollowsAppearance", \.app.editorThemeFollowsAppearance, "エディタの配色の自動切り替え",
                      summarize: optional(onOff)),
                Field("editorLightTheme", \.app.editorLightTheme, "エディタのライト配色",
                      summarize: optional { $0.title }, read: readTheme),
                Field("editorDarkTheme", \.app.editorDarkTheme, "エディタのダーク配色",
                      summarize: optional { $0.title }, read: readTheme),
                Field("previewTheme", \.app.previewTheme, "プレビューの固定配色", summarize: optional { $0.title }, read: readTheme),
                Field("previewThemeFollowsAppearance", \.app.previewThemeFollowsAppearance, "プレビューの配色の自動切り替え",
                      summarize: optional(onOff)),
                Field("previewLightTheme", \.app.previewLightTheme, "プレビューのライト配色",
                      summarize: optional { $0.title }, read: readTheme),
                Field("previewDarkTheme", \.app.previewDarkTheme, "プレビューのダーク配色",
                      summarize: optional { $0.title }, read: readTheme),
            ]
        case .snippets:
            [Field("snippets", \.app.snippets, "スニペット",
                   changes: { collectionChanges($0 ?? [], $1 ?? [], name: \.trigger) })]
        case .terminology:
            [
                Field("entries", \.app.terminologyEntries, "登録した用語",
                      changes: { collectionChanges($0 ?? [], $1 ?? [], name: \.prohibited, summary: \.preferred) }),
                Field("options", \.app.terminologyOptions, "用語辞書の除外条件",
                      summarize: optional(terminologyOptionsSummary)),
            ]
        case .shortcuts:
            [Field("overrides", \.app.shortcutOverrides, "変更したショートカット",
                   read: readShortcutOverrides, changes: shortcutChanges)]
        case .exportPresets:
            [Field("presets", \.exportPresets, "ユーザの書き出しプリセット",
                   changes: { collectionChanges($0, $1, name: \.name) })]
        case .extensions:
            [Field("packages", \.app.extensionPackages, "追加した拡張",
                   changes: { collectionChanges($0 ?? [], $1 ?? [], name: \.name) })]
        }
    }
}

private func optional<Value>(_ summarize: @escaping (Value) -> String) -> (Value?) -> String? {
    { value in value.map(summarize) ?? String(localized: "既定値") }
}

private func within<Value: Comparable>(_ range: ClosedRange<Value>) -> (Value?) -> Bool {
    { value in value.map(range.contains) ?? true }
}

private func onOff(_ value: Bool) -> String {
    value ? String(localized: "オン") : String(localized: "オフ")
}

private func collection(_ names: [String]) -> String {
    let count = String(localized: "\(names.count)件")
    guard !names.isEmpty else { return count }
    let sample = names.prefix(3).map { String($0.prefix(36)) }.formatted(.list(type: .and))
    return String(localized: "\(count)（\(sample)）")
}

private func changedValue(_ title: String, before: String, after: String) -> String {
    String(localized: "\(title)（\(before) → \(after)）")
}

private func collectionChanges<Item: Identifiable & Equatable>(
    _ old: [Item], _ new: [Item], name: (Item) -> String, summary: ((Item) -> String)? = nil
) -> [String] {
    let oldItems = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let newItems = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var changes: [String] = []
    for item in old where newItems[item.id] == nil {
        changes.append(String(localized: "「\(name(item))」を削除"))
    }
    for item in new {
        let newName = name(item)
        guard let previous = oldItems[item.id] else {
            changes.append(String(localized: "「\(newName)」を追加"))
            continue
        }
        guard previous != item else { continue }
        let oldName = name(previous)
        if oldName != newName {
            changes.append(changedValue(oldName, before: oldName, after: newName))
        } else if let summary, summary(previous) != summary(item) {
            changes.append(changedValue(newName, before: summary(previous), after: summary(item)))
        } else {
            changes.append(String(localized: "「\(newName)」の内容を変更"))
        }
    }
    let oldOrder = old.map(\.id).filter { newItems[$0] != nil }
    let newOrder = new.map(\.id).filter { oldItems[$0] != nil }
    if oldOrder != newOrder { changes.append(String(localized: "順序を変更")) }
    return changes
}

private func readShortcutOverrides(
    _ values: KeyedDecodingContainer<SettingsArchive.Key>, _ key: SettingsArchive.Key
) throws -> [String: ShortcutChord]?? {
    guard !(try values.decodeNil(forKey: key)) else { return .some(nil) }
    let keys = try values.nestedContainer(keyedBy: SettingsArchive.Key.self, forKey: key)
    var overrides: [String: ShortcutChord] = [:]
    for command in EditorShortcutRegistry.commands {
        let identifier = command.toolbarIdentifier
        let commandKey = SettingsArchive.Key(stringValue: identifier)
        guard keys.contains(commandKey) else { continue }
        var chord = try keys.decode(ShortcutChord.self, forKey: commandKey)
        chord.key = chord.key.lowercased()
        overrides[identifier] = chord
    }
    return !keys.allKeys.isEmpty && overrides.isEmpty ? nil : .some(overrides)
}

private func shortcutChanges(_ old: [String: ShortcutChord]?, _ new: [String: ShortcutChord]?) -> [String] {
    EditorShortcutRegistry.commands.compactMap { command in
        let before = EditorShortcutRegistry.shortcut(for: command, overrides: old ?? [:])
        let after = EditorShortcutRegistry.shortcut(for: command, overrides: new ?? [:])
        guard before != after else { return nil }
        let unassigned = String(localized: "割り当てなし")
        return changedValue(command.title, before: before?.label ?? unassigned, after: after?.label ?? unassigned)
    }
}

private func readLanguageSetting<Setting: Decodable, Language: RawRepresentable>(
    _ setting: Setting.Type, language: Language.Type,
    _ values: KeyedDecodingContainer<SettingsArchive.Key>, _ key: SettingsArchive.Key
) throws -> Setting?? where Language.RawValue == String {
    guard !(try values.decodeNil(forKey: key)) else { return .some(nil) }
    let details = try values.nestedContainer(keyedBy: SettingsArchive.Key.self, forKey: key)
    let rawLanguage = try details.decode(String.self, forKey: .init(stringValue: "language"))
    guard Language(rawValue: rawLanguage) != nil else { return nil }
    return .some(try values.decode(Setting.self, forKey: key))
}

private func readTheme(
    _ values: KeyedDecodingContainer<SettingsArchive.Key>, _ key: SettingsArchive.Key
) throws -> PreviewTheme?? {
    guard !(try values.decodeNil(forKey: key)) else { return .some(nil) }
    if let name = try? values.decode(String.self, forKey: key) {
        switch name {
        case "system": return .some(.system)
        case "navy": return .some(.navy)
        case "paper": return .some(.paper)
        default: return PreviewThemePreset(rawValue: name).map { .some(.preset($0)) }
        }
    }
    let theme = try values.decode(DeclarativeExtension.Theme.self, forKey: key)
    return .some(.extensionTheme(theme))
}

private func readingEstimateSummary(_ settings: ReadingEstimateSettings) -> String {
    String(localized: "\(settings.language.title)・日本語 \(settings.japaneseReadingRate)/\(settings.japaneseSpeakingRate)・英語 \(settings.englishReadingRate)/\(settings.englishSpeakingRate)")
}

private func proofingSummary(_ settings: EditorProofingSettings) -> String {
    String(localized: "\(settings.language.title)・スペルチェック \(onOff(settings.checksSpelling))・自動訂正 \(onOff(settings.correctsSpelling))")
}

private func terminologyOptionsSummary(_ options: TerminologyOptions) -> String {
    String(localized: "コード内を除外 \(onOff(options.excludesCode))・引用内を除外 \(onOff(options.excludesQuotes))")
}

private func validReadingEstimate(_ settings: ReadingEstimateSettings?) -> Bool {
    guard let settings else { return true }
    return (100...2000).contains(settings.japaneseReadingRate)
        && (100...2000).contains(settings.japaneseSpeakingRate)
        && (50...500).contains(settings.englishReadingRate)
        && (50...500).contains(settings.englishSpeakingRate)
}
