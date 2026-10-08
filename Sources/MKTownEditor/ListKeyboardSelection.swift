import AppKit
import SwiftUI

/// Selection handling shared by the sidebar lists and the palette sheets (#26).
///
/// Lists use `List(selection:)` so the arrow keys move the selection and VoiceOver reports the
/// selected row. Moving the selection with the keyboard only previews it; a click, Return or a
/// double-click activates the row, as the buttons these lists replaced did.
enum ListKeyboardSelection {
    /// The selection if it is still listed, otherwise the first row, so Return always has a target.
    static func resolved<ID: Equatable>(_ selection: ID?, in ids: [ID]) -> ID? {
        if let selection, ids.contains(selection) { return selection }
        return ids.first
    }

    /// The row `offset` rows away from the selection, clamped to the list. Palettes treat no
    /// selection as the first row. A list that shows nothing selected passes
    /// `startsUnselected`, so ↓ then selects the first row and ↑ the last (#60).
    static func moved<ID: Equatable>(_ selection: ID?, in ids: [ID], by offset: Int,
                                     startsUnselected: Bool = false) -> ID? {
        if startsUnselected, selection.map({ !ids.contains($0) }) ?? true {
            return offset < 0 ? ids.last : ids.first
        }
        guard let current = resolved(selection, in: ids),
              let index = ids.firstIndex(of: current) else { return nil }
        return ids[min(max(0, index + offset), ids.count - 1)]
    }

    /// False for the second and later clicks of a multiple click.
    static func isSingleClick(_ event: NSEvent?) -> Bool {
        guard let event, isPointerEvent(event) else { return true }
        return event.clickCount <= 1
    }

    /// True when a list's `primaryAction` comes from Return rather than a double-click. A click
    /// already activated the row through `activatesOnClick`, so a double-click must not run it again.
    @MainActor static var isKeyboardActivation: Bool { !isPointerEvent(NSApp.currentEvent) }

    /// True when `event` is a click. A click selects and activates a row through its tap
    /// gesture, so the selection binding leaves the activation to that gesture.
    static func isPointerEvent(_ event: NSEvent?) -> Bool {
        switch event?.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp: true
        default: false
        }
    }
}

extension View {
    /// Lets ↑ and ↓ in a palette's search field move the selection of the result list below it.
    func movesListSelection<ID: Hashable>(_ selection: Binding<ID?>, in ids: [ID],
                                          startsUnselected: Bool = false) -> some View {
        onKeyPress(.upArrow) {
            guard !ids.isEmpty else { return .ignored }
            selection.wrappedValue = ListKeyboardSelection.moved(selection.wrappedValue, in: ids, by: -1,
                                                                 startsUnselected: startsUnselected)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard !ids.isEmpty else { return .ignored }
            selection.wrappedValue = ListKeyboardSelection.moved(selection.wrappedValue, in: ids, by: 1,
                                                                 startsUnselected: startsUnselected)
            return .handled
        }
    }

    /// Activates a list row on a single click without taking over the list's own selection.
    /// The later clicks of a double-click are ignored, so the row is activated only once.
    func activatesOnClick(_ action: @escaping () -> Void) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                if ListKeyboardSelection.isSingleClick(NSApp.currentEvent) { action() }
            })
    }
}

extension View {
    /// Runs `action` for the selected row when Return is pressed in a `List(selection:)` (#60).
    /// A double-click also calls `primaryAction`, but `activatesOnClick` already handled the
    /// click, so only the keyboard activates here.
    func activatesSelectionOnReturn<ID: Hashable>(_ type: ID.Type,
                                                  perform action: @escaping (ID) -> Void) -> some View {
        contextMenu(forSelectionType: type) { _ in } primaryAction: { ids in
            guard ListKeyboardSelection.isKeyboardActivation, let id = ids.first else { return }
            action(id)
        }
    }
}
