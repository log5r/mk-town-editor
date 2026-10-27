import Foundation

enum MobileEditorPresentation: String, CaseIterable {
    case automatic
    case editor
    case preview
}

/// Keep search and presentation together so a find request always has a visible editor.
struct MobileEditorState {
    var presentation: MobileEditorPresentation = .automatic
    var compactPreview = false
    var showsFindNavigator = false
    private(set) var findRequested = false

    mutating func showFindNavigator() {
        if presentation == .preview { presentation = .editor }
        compactPreview = false
        findRequested = true
    }

    mutating func presentRequestedFindNavigator() {
        guard findRequested else { return }
        findRequested = false
        showsFindNavigator = true
    }

    mutating func dismissFindNavigator() {
        showsFindNavigator = false
        findRequested = false
    }

    mutating func togglePreview(showsEditor: Bool) {
        dismissFindNavigator()
        if presentation == .automatic {
            compactPreview.toggle()
        } else {
            presentation = showsEditor ? .preview : .editor
        }
    }
}

/// Two readable text columns need at least 360 points each. Use the current content width,
/// not a device model, orientation, or cached screen bounds. Accessibility text uses one column.
struct MobileEditorLayout {
    let showsEditor: Bool
    let showsPreview: Bool

    init(width: Double, accessibilityText: Bool, presentation: MobileEditorPresentation,
         compactPreview: Bool) {
        let split = width >= 720 && !accessibilityText
        switch presentation {
        case .automatic:
            showsEditor = split || !compactPreview
            showsPreview = split || compactPreview
        case .editor:
            showsEditor = true
            showsPreview = false
        case .preview:
            showsEditor = false
            showsPreview = true
        }
    }
}
