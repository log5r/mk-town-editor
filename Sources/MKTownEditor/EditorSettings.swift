import Combine
import Foundation

struct AppEditorSettings: Codable, Equatable {
    var defaultMode: EditorMode = .split
    var fontSize: Double = 13
    var lineSpacing: Double = 3
    var wrapsLines = true
}

struct FolderEditorSettings: Codable, Equatable {
    var defaultMode: EditorMode?
    var fontSize: Double?
}

struct DocumentDisplayState: Codable, Equatable {
    var mode: EditorMode
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

    func setMode(_ mode: EditorMode, for documentURL: URL) {
        values.documents[Self.key(for: documentURL)] = DocumentDisplayState(mode: mode)
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
