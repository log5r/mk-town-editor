import Foundation

enum MobileEditorPresentation: String, CaseIterable {
    case automatic
    case editor
    case preview
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
