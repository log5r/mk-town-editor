import AppKit
import Combine
import Foundation
import SwiftUI

enum EditorFontChoice: String, Codable, CaseIterable {
    case monospacedSystem
    case system
    case menlo

    var title: String {
        switch self {
        case .monospacedSystem: String(localized: "システム等幅")
        case .system: String(localized: "システム")
        case .menlo: "Menlo"
        }
    }

    @MainActor
    func font(size: CGFloat) -> NSFont {
        switch self {
        case .monospacedSystem: .monospacedSystemFont(ofSize: size, weight: .regular)
        case .system: .systemFont(ofSize: size)
        case .menlo: NSFont(name: "Menlo-Regular", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }
}

enum ProofingLanguage: String, Codable, CaseIterable {
    case automatic
    case english
    case japanese

    var title: String {
        switch self {
        case .automatic: String(localized: "自動判定")
        case .english: String(localized: "英語")
        case .japanese: String(localized: "日本語")
        }
    }

    var spellCheckerIdentifier: String? {
        switch self {
        case .automatic: nil
        case .english: "en"
        case .japanese: "ja"
        }
    }
}

enum MarkdownDialect: String, Codable, CaseIterable, Sendable {
    case extended
    case basic

    var title: String {
        switch self {
        case .extended: String(localized: "拡張（表・脚注・フロントマター）")
        case .basic: String(localized: "基本（表・脚注・フロントマターなし）")
        }
    }
}

enum PreviewTheme: Codable, Hashable, Sendable {
    case system
    case paper
    case extensionTheme(DeclarativeExtension.Theme)

    static let allCases: [Self] = [.system, .paper]

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let name = try? value.decode(String.self) {
            switch name {
            case "system": self = .system
            case "paper": self = .paper
            default: throw DecodingError.dataCorruptedError(in: value, debugDescription: "Unknown theme")
            }
        } else {
            self = .extensionTheme(try value.decode(DeclarativeExtension.Theme.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .system: try value.encode("system")
        case .paper: try value.encode("paper")
        case .extensionTheme(let theme): try value.encode(theme)
        }
    }

    var title: String {
        switch self {
        case .system: String(localized: "システム")
        case .paper: String(localized: "紙色")
        case .extensionTheme(let theme): theme.name
        }
    }

    var background: NSColor? {
        switch self {
        case .system: nil
        case .paper: NSColor(srgbRed: 0.98, green: 0.965, blue: 0.93, alpha: 1)
        case .extensionTheme(let theme): theme.color(\.background)
        }
    }
    var bodyColor: NSColor? {
        switch self {
        case .system: nil
        case .paper: NSColor(srgbRed: 0.18, green: 0.16, blue: 0.13, alpha: 1)
        case .extensionTheme(let theme): theme.color(\.body)
        }
    }
    var headingColor: NSColor? {
        switch self {
        case .system: nil
        case .paper: NSColor(srgbRed: 0.31, green: 0.19, blue: 0.11, alpha: 1)
        case .extensionTheme(let theme): theme.color(\.heading)
        }
    }
    var codeColor: NSColor? {
        switch self {
        case .system: nil
        case .paper: NSColor(srgbRed: 0.34, green: 0.18, blue: 0.10, alpha: 1)
        case .extensionTheme(let theme): theme.color(\.code)
        }
    }
    var linkColor: NSColor? {
        switch self {
        case .system: nil
        case .paper: NSColor(srgbRed: 0.10, green: 0.22, blue: 0.38, alpha: 1)
        case .extensionTheme(let theme): theme.color(\.link)
        }
    }
    var codeBackground: NSColor? {
        switch self {
        case .system: nil
        case .paper: NSColor(srgbRed: 0.91, green: 0.87, blue: 0.79, alpha: 1)
        case .extensionTheme(let theme): theme.color(\.codeBackground)
        }
    }
    var colorScheme: ColorScheme? {
        guard let color = background?.usingColorSpace(.sRGB) else { return nil }
        let luminance = 0.2126 * color.redComponent +
            0.7152 * color.greenComponent + 0.0722 * color.blueComponent
        return luminance < 0.5 ? .dark : .light
    }
}

enum AttachmentDirectory: String, Codable, CaseIterable, Sendable {
    case assets
    case images

    var title: String { rawValue }
}

struct EditorProofingSettings: Codable, Equatable {
    var language: ProofingLanguage = .automatic
    var checksSpelling = true
    var correctsSpelling = true
}

struct EditorSnippet: Codable, Equatable, Identifiable {
    var id = UUID()
    var trigger: String
    var template: String
}

struct EditorTextStyle: Equatable {
    var fontChoice: EditorFontChoice = .monospacedSystem
    var fontSize: Double = 13
    var lineSpacing: Double = 3
    var horizontalMargin: Double = 18
    var verticalMargin: Double = 18
    var tabWidth: Int = 4

    @MainActor
    func apply(to textView: NSTextView) {
        let font = fontChoice.font(size: CGFloat(fontSize))
        textView.font = font
        textView.textContainerInset = NSSize(width: horizontalMargin, height: verticalMargin)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = CGFloat(lineSpacing)
        paragraph.tabStops = []
        paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: font]).width * CGFloat(tabWidth)
        textView.defaultParagraphStyle = paragraph
        var typing = textView.typingAttributes
        typing[.paragraphStyle] = paragraph
        textView.typingAttributes = typing
    }
}

struct EditorLayoutOptions: Equatable {
    var wrapsLines = true
    var listIndentWidth = 2
    var codeIndentWidth = 4

    @MainActor
    func apply(to textView: NSTextView, in scrollView: NSScrollView) {
        scrollView.hasHorizontalScroller = !wrapsLines
        textView.isHorizontallyResizable = !wrapsLines
        textView.autoresizingMask = wrapsLines ? [.width] : []
        textView.textContainer?.widthTracksTextView = wrapsLines
        textView.textContainer?.containerSize = NSSize(
            width: wrapsLines ? 0 : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        synchronizeWidth(of: textView, in: scrollView)
    }

    @MainActor
    func synchronizeWidth(of textView: NSTextView, in scrollView: NSScrollView) {
        let viewportWidth = scrollView.contentSize.width
        let requiredWidth: CGFloat
        if wrapsLines {
            requiredWidth = viewportWidth
        } else if let layoutManager = textView.layoutManager,
                  let container = textView.textContainer {
            layoutManager.ensureLayout(for: container)
            requiredWidth = max(viewportWidth, ceil(layoutManager.usedRect(for: container).maxX
                                                    + textView.textContainerInset.width * 2))
        } else {
            requiredWidth = viewportWidth
        }
        if abs(textView.frame.width - requiredWidth) > 0.5 {
            textView.frame.size.width = requiredWidth
        }
    }
}

struct AppEditorSettings: Codable, Equatable {
    var defaultMode: EditorMode = .split
    var fontSize: Double = 13
    var lineSpacing: Double = 3
    var wrapsLines = true
    var imageImportMode: ImageImportMode?
    var fontChoice: EditorFontChoice?
    var horizontalMargin: Double?
    var verticalMargin: Double?
    var tabWidth: Int?
    var listIndentWidth: Int?
    var codeIndentWidth: Int?
    var tableAddsRowOnTab: Bool?
    var editorZoom: Double?
    var previewZoom: Double?
    var wordCountMode: WordCountMode?
    var readingEstimate: ReadingEstimateSettings?
    var disabledLintRules: Set<MarkdownLintRule>?
    var proofing: EditorProofingSettings?
    var showsFrontMatterInPreview: Bool?
    var snippets: [EditorSnippet]?
    var loadsRemoteImages: Bool?
    var loadsExternalLinkPreviews: Bool?
    var showsMinimap: Bool?
    var usesInlineLivePresentation: Bool?
    var usesTypewriterMode: Bool?
    var terminologyEntries: [TerminologyEntry]?
    var terminologyOptions: TerminologyOptions?
    var attachmentDirectory: AttachmentDirectory?
    var markdownDialect: MarkdownDialect?
    var previewTheme: PreviewTheme?
    var extensionPackages: [DeclarativeExtension]?
    var previewBodyWidth: Int?
    var showsInvisibleCharacters: Bool?
    var showsIndentGuides: Bool?
    var shortcutOverrides: [String: ShortcutChord]?

    var effectiveSnippets: [EditorSnippet] {
        (snippets ?? []) + (extensionPackages ?? []).flatMap { package in
            package.snippets.map { EditorSnippet(id: $0.id, trigger: $0.trigger, template: $0.template) }
        }
    }
}

enum EditorZoomSurface: CaseIterable {
    case editor, preview

    var title: String { self == .editor ? String(localized: "編集") : String(localized: "プレビュー") }
}

enum EditorSplitOrientation: String, Codable, CaseIterable {
    case sideBySide
    case stacked

    var title: String { self == .sideBySide ? String(localized: "左右") : String(localized: "上下") }

    /// Earlier versions stored the Japanese titles as raw values.
    init?(storedValue: String) {
        switch storedValue {
        case "左右": self = .sideBySide
        case "上下": self = .stacked
        default: self.init(rawValue: storedValue)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let orientation = Self(storedValue: value) else {
            throw DecodingError.dataCorruptedError(in: container,
                debugDescription: "Unknown split orientation \(value)")
        }
        self = orientation
    }
}

struct FocusModeState {
    private(set) var savedSidebarVisibility: NavigationSplitViewVisibility?
    var isActive: Bool { savedSidebarVisibility != nil }

    mutating func toggle(sidebarVisibility: NavigationSplitViewVisibility) -> NavigationSplitViewVisibility {
        if let savedSidebarVisibility {
            self.savedSidebarVisibility = nil
            return savedSidebarVisibility
        }
        savedSidebarVisibility = sidebarVisibility
        return .detailOnly
    }
}

enum EditorSplitSizing {
    static func editorExtent(total: CGFloat, ratio: Double, minimum: CGFloat) -> CGFloat {
        let available = max(1, total - 8)
        let effectiveMinimum = min(minimum, available / 2)
        return max(effectiveMinimum,
                   min(available - effectiveMinimum, available * ratio))
    }

    /// The ratio after dragging the divider `delta` points from where it was at `start`.
    /// `editorTrailing` is true when the editor follows the preview, so dragging toward the
    /// trailing edge shrinks it.
    static func draggedRatio(from start: Double, delta: CGFloat, total: CGFloat,
                             minimum: CGFloat, editorTrailing: Bool) -> Double {
        let available = max(1, total - SplitDividerHandle.thickness)
        let effectiveMinimum = Double(min(minimum, available / 2) / available)
        let proposed = start + Double((editorTrailing ? -delta : delta) / available)
        return max(effectiveMinimum, min(1 - effectiveMinimum, proposed))
    }

    /// Keyboard and VoiceOver adjustments move the divider in 5% steps within 20–80%.
    static func adjustedRatio(_ ratio: Double, increment: Bool) -> Double {
        increment ? min(0.8, ratio + 0.05) : max(0.2, ratio - 0.05)
    }
}

struct FolderEditorSettings: Codable, Equatable {
    var defaultMode: EditorMode?
    var fontSize: Double?
    var imageImportMode: ImageImportMode?
    var tabWidth: Int?
    var listIndentWidth: Int?
    var codeIndentWidth: Int?
    var attachmentDirectory: AttachmentDirectory?
    var markdownDialect: MarkdownDialect?
}

struct DocumentDisplayState: Codable, Equatable {
    var mode: EditorMode
    var selectionLocation: Int? = nil
    var selectionLength: Int? = nil
    var scrollY: Double? = nil
    var scrollX: Double? = nil
    var splitRatio: Double? = nil
    var splitOrientation: EditorSplitOrientation? = nil
    var previewFirst: Bool? = nil
    var sidebarTab: String? = nil
    var sidebarVisible: Bool? = nil
    var writingGoal: Int? = nil
    var sessionBaselineCharacters: Int? = nil
    /// 最後に書き込んだ日時。保持件数の上限を超えたとき、古いものから削除する。
    var lastUsed: Date? = nil
}

private struct StoredEditorSettings: Codable, Equatable {
    var app = AppEditorSettings()
    var folders: [String: FolderEditorSettings] = [:]
    var documents: [String: DocumentDisplayState] = [:]
    var bookmarks: [DocumentBookmark]? = nil
}

/// Persists shared settings while keeping document display state separate from Markdown source.
///
/// 書類ごとの表示状態は共有設定とは別のキーに保存し、件数に上限を設ける。表示位置の保存は
/// 画面に反映される値を変えないため、変更通知を送らず全ウインドウを再描画しない。
@MainActor
final class EditorSettingsStore: ObservableObject {
    static let documentStateLimit = 200

    private var values: StoredEditorSettings {
        willSet { objectWillChange.send() }
    }
    private var documents: [String: DocumentDisplayState]
    private let defaults: UserDefaults
    private var savedSettingsData: Data?
    private var savedDocumentsData: Data?
    private(set) var settingsWriteCount = 0
    private(set) var documentWriteCount = 0
    private static let storageKey = "MKTownEditor.editorSettings.v1"
    private static let documentStorageKey = "MKTownEditor.documentDisplayStates.v1"
    /// 内容が同じなら同じバイト列になるようにし、変更のない保存を省けるようにする。
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    init(defaults: UserDefaults = .standard, prunesMissingDocuments: Bool = true) {
        self.defaults = defaults
        let storedData = defaults.data(forKey: Self.storageKey)
        var stored = storedData.flatMap { try? JSONDecoder().decode(StoredEditorSettings.self, from: $0) }
            ?? StoredEditorSettings()
        let documentData = defaults.data(forKey: Self.documentStorageKey)
        if let documentData,
           let decoded = try? JSONDecoder().decode([String: DocumentDisplayState].self, from: documentData) {
            documents = decoded
        } else {
            // 以前の版は共有設定と同じ値に書類の状態を含めていた。
            documents = stored.documents
        }
        let migrates = !stored.documents.isEmpty
        stored.documents = [:]
        values = stored
        savedSettingsData = migrates ? nil : storedData
        savedDocumentsData = documentData
        let loadedCount = documents.count
        trimDocuments()
        if migrates || documents.count != loadedCount {
            save()
            saveDocuments()
        }
        if prunesMissingDocuments { schedulePruningMissingDocuments() }
    }

    var app: AppEditorSettings { values.app }

    func shortcut(for command: EditorCommand) -> ShortcutChord? {
        EditorShortcutRegistry.shortcut(for: command,
                                        overrides: values.app.shortcutOverrides ?? [:])
    }

    func setShortcut(_ chord: ShortcutChord, for command: EditorCommand) throws {
        var normalized = chord
        normalized.key = chord.key.lowercased()
        try EditorShortcutRegistry.validate(normalized, for: command,
            overrides: values.app.shortcutOverrides ?? [:])
        values.app.shortcutOverrides = values.app.shortcutOverrides ?? [:]
        values.app.shortcutOverrides?[command.toolbarIdentifier] = normalized
        save()
    }

    func resetShortcut(for command: EditorCommand) throws {
        var remaining = values.app.shortcutOverrides ?? [:]
        remaining[command.toolbarIdentifier] = nil
        if let defaultShortcut = EditorShortcutRegistry.shortcut(for: command, overrides: [:]) {
            try EditorShortcutRegistry.validate(defaultShortcut, for: command,
                                                overrides: remaining)
        }
        values.app.shortcutOverrides = remaining
        save()
    }

    func setAppSettings(_ settings: AppEditorSettings) {
        values.app = settings
        save()
    }

    func setFolderSettings(_ settings: FolderEditorSettings?, for folderURL: URL) {
        let key = Self.key(for: folderURL)
        values.folders[key] = settings
        save()
    }

    func folderSettings(for folderURL: URL) -> FolderEditorSettings {
        values.folders[Self.key(for: folderURL)] ?? FolderEditorSettings()
    }

    func attachmentDirectory(for documentURL: URL?) -> AttachmentDirectory {
        guard let documentURL else { return values.app.attachmentDirectory ?? .assets }
        return nearestFolderValue(for: documentURL, \.attachmentDirectory)
            ?? values.app.attachmentDirectory ?? .assets
    }

    func markdownDialect(for documentURL: URL?) -> MarkdownDialect {
        guard let documentURL else { return values.app.markdownDialect ?? .extended }
        return nearestFolderValue(for: documentURL, \.markdownDialect)
            ?? values.app.markdownDialect ?? .extended
    }

    func mode(for documentURL: URL?) -> EditorMode {
        guard let documentURL else { return values.app.defaultMode }
        let path = Self.key(for: documentURL)
        if let state = documents[path] { return state.mode }
        return nearestFolderValue(for: documentURL, \.defaultMode) ?? values.app.defaultMode
    }

    func fontSize(for documentURL: URL?) -> Double {
        guard let documentURL else { return values.app.fontSize }
        return nearestFolderValue(for: documentURL, \.fontSize) ?? values.app.fontSize
    }

    func imageImportMode(for documentURL: URL?) -> ImageImportMode {
        guard let documentURL else { return values.app.imageImportMode ?? .managedCopy }
        return nearestFolderValue(for: documentURL, \.imageImportMode)
            ?? values.app.imageImportMode ?? .managedCopy
    }

    func textStyle(for documentURL: URL?) -> EditorTextStyle {
        EditorTextStyle(
            fontChoice: values.app.fontChoice ?? .monospacedSystem,
            fontSize: min(32, max(10, fontSize(for: documentURL))) * zoom(for: .editor),
            lineSpacing: min(12, max(0, values.app.lineSpacing)) * zoom(for: .editor),
            horizontalMargin: min(48, max(8, values.app.horizontalMargin ?? 18)),
            verticalMargin: min(48, max(8, values.app.verticalMargin ?? 18)),
            tabWidth: min(8, max(2,
                documentURL.flatMap { nearestFolderValue(for: $0, \.tabWidth) }
                    ?? values.app.tabWidth ?? 4))
        )
    }

    func zoom(for surface: EditorZoomSurface) -> Double {
        let value = surface == .editor ? values.app.editorZoom : values.app.previewZoom
        return min(2, max(0.5, value ?? 1))
    }

    func adjustZoom(for surface: EditorZoomSurface, by amount: Double) {
        let value = (zoom(for: surface) + amount) * 10
        setZoom(for: surface, to: (value.rounded() / 10))
    }

    func resetZoom(for surface: EditorZoomSurface) {
        setZoom(for: surface, to: 1)
    }

    private func setZoom(for surface: EditorZoomSurface, to value: Double) {
        let value = min(2, max(0.5, value))
        switch surface {
        case .editor: values.app.editorZoom = value
        case .preview: values.app.previewZoom = value
        }
        save()
    }

    func layoutOptions(for documentURL: URL? = nil) -> EditorLayoutOptions {
        EditorLayoutOptions(
            wrapsLines: values.app.wrapsLines,
            listIndentWidth: min(8, max(2,
                documentURL.flatMap { nearestFolderValue(for: $0, \.listIndentWidth) }
                    ?? values.app.listIndentWidth ?? 2)),
            codeIndentWidth: min(8, max(2,
                documentURL.flatMap { nearestFolderValue(for: $0, \.codeIndentWidth) }
                    ?? values.app.codeIndentWidth ?? 4))
        )
    }

    func adjustFontSize(by amount: Double) {
        values.app.fontSize = min(32, max(10, values.app.fontSize + amount))
        save()
    }

    func resetFontSize() {
        values.app.fontSize = 13
        save()
    }

    func setImageImportMode(_ mode: ImageImportMode) {
        values.app.imageImportMode = mode
        save()
    }

    func setMode(_ mode: EditorMode, for documentURL: URL) {
        let key = Self.key(for: documentURL)
        var state = documents[key] ?? DocumentDisplayState(mode: mode)
        state.mode = mode
        storeDocumentState(state, for: key)
    }

    func applyWorkspaceLayout(_ layout: WorkspaceNamedLayout, to documentURL: URL) {
        let key = Self.key(for: documentURL)
        var state = documents[key] ?? DocumentDisplayState(mode: layout.mode)
        state.mode = layout.mode
        state.sidebarTab = layout.sidebarTab
        state.sidebarVisible = layout.sidebarVisible
        state.splitRatio = min(0.8, max(0.2, layout.splitRatio))
        state.splitOrientation = layout.splitOrientation
        state.previewFirst = layout.previewFirst
        storeDocumentState(state, for: key)
    }

    func displayState(for documentURL: URL) -> DocumentDisplayState? {
        documents[Self.key(for: documentURL)]
    }

    func setWritingGoal(_ goal: Int?, for documentURL: URL) {
        let key = Self.key(for: documentURL)
        var state = documents[key] ?? DocumentDisplayState(mode: mode(for: documentURL))
        state.writingGoal = goal.flatMap { $0 > 0 ? $0 : nil }
        storeDocumentState(state, for: key)
    }

    /// Capture the opening text before asynchronous analysis has produced statistics.
    func ensureWritingSession(for documentURL: URL, initialText: String) {
        guard documents[Self.key(for: documentURL)]?.sessionBaselineCharacters == nil else { return }
        ensureWritingSession(for: documentURL, baseline: WritingSessionBaseline(text: initialText))
    }

    func ensureWritingSession(for documentURL: URL, baseline: WritingSessionBaseline) {
        let key = Self.key(for: documentURL)
        var state = documents[key] ?? DocumentDisplayState(mode: mode(for: documentURL))
        guard state.sessionBaselineCharacters == nil else { return }
        state.sessionBaselineCharacters = baseline.characters
        storeDocumentState(state, for: key)
    }

    func resetWritingSession(for documentURL: URL, baseline: WritingSessionBaseline) {
        let key = Self.key(for: documentURL)
        var state = documents[key] ?? DocumentDisplayState(mode: mode(for: documentURL))
        state.sessionBaselineCharacters = baseline.characters
        storeDocumentState(state, for: key)
    }

    func savePosition(for documentURL: URL, selection: NSRange, scrollX: Double, scrollY: Double,
                      splitRatio: Double, sidebarTab: String, sidebarVisible: Bool,
                      splitOrientation: EditorSplitOrientation = .sideBySide,
                      previewFirst: Bool = false) {
        let key = Self.key(for: documentURL)
        var state = documents[key] ?? DocumentDisplayState(mode: mode(for: documentURL))
        state.selectionLocation = max(0, selection.location)
        state.selectionLength = max(0, selection.length)
        state.scrollY = max(0, scrollY)
        state.scrollX = max(0, scrollX)
        state.splitRatio = min(0.8, max(0.2, splitRatio))
        state.splitOrientation = splitOrientation
        state.previewFirst = previewFirst
        state.sidebarTab = sidebarTab
        state.sidebarVisible = sidebarVisible
        guard documents[key] != state else { return }
        storeDocumentState(state, for: key, publishes: false)
    }

    func hasDocumentState(for documentURL: URL) -> Bool {
        documents[Self.key(for: documentURL)] != nil
    }

    func moveDocumentState(from oldURL: URL, to newURL: URL) {
        let oldKey = Self.key(for: oldURL)
        let newKey = Self.key(for: newURL)
        guard oldKey != newKey else { return }
        if let state = documents[oldKey] {
            objectWillChange.send()
            documents[oldKey] = nil
            documents[newKey] = state
            saveDocuments()
        }
        values.bookmarks = (values.bookmarks ?? []).map { bookmark in
            guard Self.key(for: bookmark.documentURL) == oldKey else { return bookmark }
            var moved = bookmark
            moved.documentURL = newURL.resolvingSymlinksInPath().standardizedFileURL
            return moved
        }
        save()
    }

    var bookmarks: [DocumentBookmark] { values.bookmarks ?? [] }

    func addBookmark(_ bookmark: DocumentBookmark) {
        var items = values.bookmarks ?? []
        items.append(bookmark)
        if items.count > 500 { items.removeFirst(items.count - 500) }
        values.bookmarks = items
        save()
    }

    func removeBookmark(_ id: UUID) {
        values.bookmarks?.removeAll { $0.id == id }
        save()
    }

    func moveBookmarks(under oldURL: URL, to newURL: URL) {
        let oldPath = Self.key(for: oldURL)
        let prefix = oldPath.hasSuffix("/") ? oldPath : oldPath + "/"
        let newBase = newURL.resolvingSymlinksInPath().standardizedFileURL
        values.bookmarks = (values.bookmarks ?? []).map { bookmark in
            let path = Self.key(for: bookmark.documentURL)
            guard path == oldPath || path.hasPrefix(prefix) else { return bookmark }
            var moved = bookmark
            let remainder = String(path.dropFirst(oldPath.count))
            moved.documentURL = URL(fileURLWithPath: newBase.path + remainder)
            return moved
        }
        save()
    }

    /// Imports the old SceneStorage value once, without replacing an existing document preference.
    func migrateLegacyMode(_ rawValue: String?, for documentURL: URL) {
        guard let rawValue, let mode = EditorMode(rawValue: rawValue),
              !hasDocumentState(for: documentURL) else { return }
        setMode(mode, for: documentURL)
    }

    private func nearestFolderValue<Value>(
        for documentURL: URL,
        _ keyPath: KeyPath<FolderEditorSettings, Value?>
    ) -> Value? {
        var folderPath = (documentURL.standardizedFileURL.path as NSString).deletingLastPathComponent
        while !folderPath.isEmpty {
            if let setting = values.folders[folderPath]?[keyPath: keyPath] { return setting }
            if folderPath == "/" { break }
            let parent = (folderPath as NSString).deletingLastPathComponent
            guard parent != folderPath else { break }
            folderPath = parent
        }
        return nil
    }

    private static func key(for url: URL) -> String { url.standardizedFileURL.path }

    private func save() {
        guard let data = try? Self.encoder.encode(values), data != savedSettingsData else { return }
        defaults.set(data, forKey: Self.storageKey)
        savedSettingsData = data
        settingsWriteCount += 1
    }

    private func saveDocuments() {
        guard let data = try? Self.encoder.encode(documents), data != savedDocumentsData else { return }
        defaults.set(data, forKey: Self.documentStorageKey)
        savedDocumentsData = data
        documentWriteCount += 1
    }

    /// 書類の状態を書き込み、上限を超えた分を古い順に除いて保存する。
    private func storeDocumentState(_ state: DocumentDisplayState, for key: String, publishes: Bool = true) {
        var state = state
        state.lastUsed = Date()
        if publishes { objectWillChange.send() }
        documents[key] = state
        trimDocuments()
        saveDocuments()
    }

    /// 書き込み日時のある状態を、新しい順に上限まで残す。以前の版から移行した日時のない状態は
    /// 使われた順序が分からないため、上限では削除せず、ファイルが消えた時か書き込み時に整理する。
    private func trimDocuments() {
        let dated = documents.filter { $0.value.lastUsed != nil }
        let excess = dated.count - Self.documentStateLimit
        guard excess > 0 else { return }
        let oldest = dated.sorted { ($0.value.lastUsed!, $0.key) < ($1.value.lastUsed!, $1.key) }.prefix(excess)
        for (key, _) in oldest { documents[key] = nil }
    }

    var documentStateCount: Int { documents.count }

    private func schedulePruningMissingDocuments() {
        let paths = Array(documents.keys)
        guard !paths.isEmpty else { return }
        Task { [weak self] in
            let missing = await Self.missingDocumentPaths(paths)
            self?.removeDocumentStates(missing)
        }
    }

    /// 存在しない書類の状態を探す。フォルダごと見つからない書類は、取り外したボリュームなどの
    /// 一時的な不在の可能性があるため残す。
    nonisolated static func missingDocumentPaths(_ paths: [String]) async -> Set<String> {
        await Task.detached(priority: .utility) {
            let manager = FileManager.default
            return Set(paths.filter { path in
                let folder = (path as NSString).deletingLastPathComponent
                var isDirectory: ObjCBool = false
                return manager.fileExists(atPath: folder, isDirectory: &isDirectory) && isDirectory.boolValue &&
                    !manager.fileExists(atPath: path)
            })
        }.value
    }

    func pruneMissingDocuments() async {
        removeDocumentStates(await Self.missingDocumentPaths(Array(documents.keys)))
    }

    private func removeDocumentStates(_ paths: Set<String>) {
        let removable = paths.filter { documents[$0] != nil }
        guard !removable.isEmpty else { return }
        objectWillChange.send()
        for path in removable { documents[path] = nil }
        saveDocuments()
    }
}

/// The character count a writing session starts from. It can only be made from the document
/// text itself: the background analysis snapshot is empty until it finishes, and recording
/// that as the start would count the whole existing document as newly written.
struct WritingSessionBaseline: Equatable, Sendable {
    let characters: Int

    init(text: String) { characters = text.count }
}
