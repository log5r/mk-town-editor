import Foundation

enum EditorMode: String, CaseIterable, Identifiable, Codable {
    case editor
    case split
    case preview

    var id: Self { self }

    var label: String {
        switch self {
        case .editor: String(localized: "編集")
        case .split: String(localized: "分割")
        case .preview: String(localized: "プレビュー")
        }
    }

    var symbolName: String {
        switch self {
        case .editor: "square.and.pencil"
        case .split: "rectangle.split.2x1"
        case .preview: "eye"
        }
    }
}

/// How a saved document's new window starts. Untitled documents always use the app's default mode.
enum DocumentOpeningMode: String, Codable, CaseIterable {
    /// Start in the preview without changing the document's saved mode.
    case alwaysPreview
    /// Start in the mode saved for the document, its folder or the app.
    case lastUsed

    static let `default`: Self = .alwaysPreview

    var title: String {
        switch self {
        case .alwaysPreview: String(localized: "常にプレビュー")
        case .lastUsed: String(localized: "前回の表示")
        }
    }
}

/// The mode one window shows. With `DocumentOpeningMode.alwaysPreview`, a saved document starts
/// in the preview without replacing its saved mode; the first mode the person picks ends that
/// and is saved as before. See docs/hig-ux-decisions.md.
struct EditorSessionMode: Equatable {
    private(set) var override: EditorMode?
    private(set) var isOpened = false

    /// What the window shows. Before `open`, this is what `open` will choose, so the first
    /// frame already matches.
    /// - Parameters:
    ///   - opening: The setting for a saved document, or nil for an untitled one.
    ///   - usesSavedMode: The window was opened for something that decides the mode itself: a
    ///     request that switches to the editor right after it opens (a line from mktown-open, a
    ///     position from search, backlinks, tasks or bookmarks), or a named layout that has
    ///     saved its mode for the document.
    func resolve(saved: EditorMode, opening: DocumentOpeningMode?,
                 usesSavedMode: Bool = false) -> EditorMode {
        if let override { return override }
        guard !isOpened else { return saved }
        return Self.openingOverride(opening: opening, usesSavedMode: usesSavedMode) ?? saved
    }

    /// Runs once per window; later appearances of the same window keep its mode.
    mutating func open(opening: DocumentOpeningMode?, usesSavedMode: Bool = false) {
        guard !isOpened else { return }
        isOpened = true
        override = Self.openingOverride(opening: opening, usesSavedMode: usesSavedMode)
    }

    /// Called for every mode change made in the window; the caller saves the new mode as before.
    mutating func select() {
        isOpened = true
        override = nil
    }

    private static func openingOverride(opening: DocumentOpeningMode?,
                                        usesSavedMode: Bool) -> EditorMode? {
        opening == .alwaysPreview && !usesSavedMode ? .preview : nil
    }
}
