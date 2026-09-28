import AppKit
import Combine
import Foundation

enum EditorFontChoice: String, Codable, CaseIterable {
    case monospacedSystem
    case system
    case menlo

    var title: String {
        switch self {
        case .monospacedSystem: "システム等幅"
        case .system: "システム"
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
}

enum EditorZoomSurface: CaseIterable {
    case editor, preview

    var title: String { self == .editor ? "編集" : "プレビュー" }
}

struct FolderEditorSettings: Codable, Equatable {
    var defaultMode: EditorMode?
    var fontSize: Double?
    var imageImportMode: ImageImportMode?
}

struct DocumentDisplayState: Codable, Equatable {
    var mode: EditorMode
    var selectionLocation: Int? = nil
    var selectionLength: Int? = nil
    var scrollY: Double? = nil
    var scrollX: Double? = nil
    var splitRatio: Double? = nil
    var sidebarTab: String? = nil
    var sidebarVisible: Bool? = nil
    var writingGoal: Int? = nil
    var sessionBaselineCharacters: Int? = nil
}

private struct StoredEditorSettings: Codable, Equatable {
    var app = AppEditorSettings()
    var folders: [String: FolderEditorSettings] = [:]
    var documents: [String: DocumentDisplayState] = [:]
}

/// Persists shared settings while keeping document display state separate from Markdown source.
@MainActor
final class EditorSettingsStore: ObservableObject {
    @Published private var values: StoredEditorSettings
    private let defaults: UserDefaults
    private static let storageKey = "MKTownEditor.editorSettings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(StoredEditorSettings.self, from: data) {
            values = decoded
        } else {
            values = StoredEditorSettings()
        }
    }

    var app: AppEditorSettings { values.app }

    func setAppSettings(_ settings: AppEditorSettings) {
        values.app = settings
        save()
    }

    func setFolderSettings(_ settings: FolderEditorSettings?, for folderURL: URL) {
        let key = Self.key(for: folderURL)
        values.folders[key] = settings
        save()
    }

    func mode(for documentURL: URL?) -> EditorMode {
        guard let documentURL else { return values.app.defaultMode }
        let path = Self.key(for: documentURL)
        if let state = values.documents[path] { return state.mode }
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
            tabWidth: min(8, max(2, values.app.tabWidth ?? 4))
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

    func layoutOptions() -> EditorLayoutOptions {
        EditorLayoutOptions(
            wrapsLines: values.app.wrapsLines,
            listIndentWidth: min(8, max(2, values.app.listIndentWidth ?? 2)),
            codeIndentWidth: min(8, max(2, values.app.codeIndentWidth ?? 4))
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
        var state = values.documents[key] ?? DocumentDisplayState(mode: mode)
        state.mode = mode
        values.documents[key] = state
        save()
    }

    func displayState(for documentURL: URL) -> DocumentDisplayState? {
        values.documents[Self.key(for: documentURL)]
    }

    func setWritingGoal(_ goal: Int?, for documentURL: URL) {
        let key = Self.key(for: documentURL)
        var state = values.documents[key] ?? DocumentDisplayState(mode: mode(for: documentURL))
        state.writingGoal = goal.flatMap { $0 > 0 ? $0 : nil }
        values.documents[key] = state
        save()
    }

    func ensureWritingSession(for documentURL: URL, initialCharacters: Int) {
        let key = Self.key(for: documentURL)
        var state = values.documents[key] ?? DocumentDisplayState(mode: mode(for: documentURL))
        guard state.sessionBaselineCharacters == nil else { return }
        state.sessionBaselineCharacters = max(0, initialCharacters)
        values.documents[key] = state
        save()
    }

    func resetWritingSession(for documentURL: URL, currentCharacters: Int) {
        let key = Self.key(for: documentURL)
        var state = values.documents[key] ?? DocumentDisplayState(mode: mode(for: documentURL))
        state.sessionBaselineCharacters = max(0, currentCharacters)
        values.documents[key] = state
        save()
    }

    func savePosition(for documentURL: URL, selection: NSRange, scrollX: Double, scrollY: Double,
                      splitRatio: Double, sidebarTab: String, sidebarVisible: Bool) {
        let key = Self.key(for: documentURL)
        var state = values.documents[key] ?? DocumentDisplayState(mode: mode(for: documentURL))
        state.selectionLocation = max(0, selection.location)
        state.selectionLength = max(0, selection.length)
        state.scrollY = max(0, scrollY)
        state.scrollX = max(0, scrollX)
        state.splitRatio = min(0.8, max(0.2, splitRatio))
        state.sidebarTab = sidebarTab
        state.sidebarVisible = sidebarVisible
        guard values.documents[key] != state else { return }
        values.documents[key] = state
        save()
    }

    func hasDocumentState(for documentURL: URL) -> Bool {
        values.documents[Self.key(for: documentURL)] != nil
    }

    func moveDocumentState(from oldURL: URL, to newURL: URL) {
        let oldKey = Self.key(for: oldURL)
        let newKey = Self.key(for: newURL)
        guard oldKey != newKey, let state = values.documents.removeValue(forKey: oldKey) else { return }
        values.documents[newKey] = state
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
        var folder = documentURL.standardizedFileURL.deletingLastPathComponent()
        while true {
            if let setting = values.folders[Self.key(for: folder)]?[keyPath: keyPath] { return setting }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { return nil }
            folder = parent
        }
    }

    private static func key(for url: URL) -> String { url.standardizedFileURL.path }

    private func save() {
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
