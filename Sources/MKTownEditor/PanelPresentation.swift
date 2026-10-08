import AppKit

extension NSSavePanel {
    /// Attaches the panel to the active window as a sheet, as the HIG recommends for file panels,
    /// so other windows stay usable. Without a window it falls back to a modeless panel; neither
    /// path blocks the app the way `runModal()` does (#29).
    @MainActor
    func beginAttached(to window: NSWindow? = NSApp.keyWindow ?? NSApp.mainWindow,
                       completionHandler: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window, window.isVisible {
            beginSheetModal(for: window, completionHandler: completionHandler)
        } else {
            begin(completionHandler: completionHandler)
        }
    }
}
