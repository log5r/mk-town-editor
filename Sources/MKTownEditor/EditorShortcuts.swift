import AppKit
import SwiftUI

struct ShortcutChord: Codable, Hashable, Sendable {
    var key: String
    var command = true
    var option = false
    var shift = false
    var control = false

    init(key: String, command: Bool = true, option: Bool = false,
         shift: Bool = false, control: Bool = false) {
        self.key = key.lowercased()
        self.command = command
        self.option = option
        self.shift = shift
        self.control = control
    }

    init(key: KeyEquivalent, modifiers: EventModifiers) {
        self.init(key: String(key.character), command: modifiers.contains(.command),
                  option: modifiers.contains(.option), shift: modifiers.contains(.shift),
                  control: modifiers.contains(.control))
    }

    var modifiers: EventModifiers {
        var result: EventModifiers = []
        if command { result.insert(.command) }
        if option { result.insert(.option) }
        if shift { result.insert(.shift) }
        if control { result.insert(.control) }
        return result
    }

    var keyEquivalent: KeyEquivalent? { key.count == 1 ? KeyEquivalent(Character(key)) : nil }

    var label: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") +
        (shift ? "⇧" : "") + (command ? "⌘" : "") + key.uppercased()
    }
}

enum ShortcutError: LocalizedError, Equatable {
    case invalidKey
    case modifierRequired
    case reserved
    case duplicate(String)

    var errorDescription: String? {
        switch self {
        case .invalidKey: String(localized: "キーは印字可能な1文字を指定してください。")
        case .modifierRequired: String(localized: "CommandまたはControlを含めてください。")
        case .reserved: String(localized: "macOSまたはアプリの標準操作に使われています。")
        case let .duplicate(title): String(localized: "「\(title)」と重複しています。")
        }
    }
}

enum EditorShortcutRegistry {
    static let commands: [EditorCommand] = EditorCommand.palette

    static func shortcut(for command: EditorCommand,
                         overrides: [String: ShortcutChord]) -> ShortcutChord? {
        let ownDefault = command.shortcut.map { ShortcutChord(key: $0.key, modifiers: $0.modifiers) }
        if let override = overrides[command.toolbarIdentifier] {
            // An override with an empty key records that the user removed the shortcut. A key
            // saved before a later version reserved it for a fixed menu item gives way to it.
            guard !override.key.isEmpty, !reserved.contains(override) || override == ownDefault
            else { return nil }
            return override
        }
        guard let chord = ownDefault else { return nil }
        // A default added in a later version gives way to a key the user already assigned elsewhere.
        return overrides.contains { $0.key != command.toolbarIdentifier && $0.value == chord } ? nil : chord
    }

    static func validate(_ chord: ShortcutChord, for command: EditorCommand,
                         overrides: [String: ShortcutChord]) throws {
        guard chord.key.count == 1, let character = chord.key.first,
              !character.isWhitespace, !character.isNewline,
              character.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              // AppKit reports arrow, function and navigation keys as private-use characters.
              !character.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) })
        else { throw ShortcutError.invalidKey }
        guard chord.command || chord.control else { throw ShortcutError.modifierRequired }
        let ownDefault = command.shortcut.map { ShortcutChord(key: $0.key, modifiers: $0.modifiers) }
        if reserved.contains(chord) && chord != ownDefault { throw ShortcutError.reserved }
        if let collision = commands.first(where: { other in
            other != command && shortcut(for: other, overrides: overrides) == chord
        }) {
            throw ShortcutError.duplicate(collision.title)
        }
    }

    /// System shortcuts and every fixed shortcut in the app's own menus. A palette command may
    /// still keep its own default here, as Find does with ⌘F shared by the preview search.
    static let reserved: Set<ShortcutChord> = [
        ShortcutChord(key: "q"), ShortcutChord(key: "w"), ShortcutChord(key: "h"),
        ShortcutChord(key: "m"), ShortcutChord(key: "n"), ShortcutChord(key: "o"),
        ShortcutChord(key: "s"), ShortcutChord(key: ","), ShortcutChord(key: "p"),
        ShortcutChord(key: "a"), ShortcutChord(key: "c"), ShortcutChord(key: "v"),
        ShortcutChord(key: "x"), ShortcutChord(key: "z"), ShortcutChord(key: "t"),
        ShortcutChord(key: "z", shift: true), ShortcutChord(key: "q", shift: true),
        ShortcutChord(key: "q", control: true),
        ShortcutChord(key: "3", shift: true), ShortcutChord(key: "4", shift: true),
        ShortcutChord(key: "5", shift: true),
        ShortcutChord(key: "h", option: true), ShortcutChord(key: "m", option: true),
        ShortcutChord(key: "f", control: true),
        ShortcutChord(key: "j", shift: true),
        ShortcutChord(key: "f", option: true),
        ShortcutChord(key: "f", option: true, shift: true),
        ShortcutChord(key: "f", shift: true),
        ShortcutChord(key: "g"), ShortcutChord(key: "g", shift: true),
        ShortcutChord(key: "r", option: true, shift: true), ShortcutChord(key: "r", option: true),
        ShortcutChord(key: "l"), ShortcutChord(key: "p", option: true),
        ShortcutChord(key: "o", option: true), ShortcutChord(key: "o", shift: true),
        ShortcutChord(key: "+"), ShortcutChord(key: "-"), ShortcutChord(key: "0"),
        ShortcutChord(key: "+", option: true), ShortcutChord(key: "-", option: true),
        ShortcutChord(key: "0", option: true, shift: true),
        // Window cycling, toolbar visibility, navigation history and Find.
        ShortcutChord(key: "`"), ShortcutChord(key: "`", shift: true),
        ShortcutChord(key: "t", option: true),
        ShortcutChord(key: "[", option: true), ShortcutChord(key: "]", option: true),
        ShortcutChord(key: "f")
    ]
}

extension ShortcutChord {
    /// The chord for a recorded key press. `unshifted` and `shifted` are the characters the key
    /// produces without modifiers and with only Shift. Letters and digits keep Shift as a
    /// modifier, as the defaults do (⇧⌘8). For other keys AppKit matches the shifted
    /// character, so Shift becomes part of the key instead (">" rather than ⇧".").
    init?(recordedKey unshifted: String, shifted: String, modifiers: NSEvent.ModifierFlags) {
        guard unshifted.count == 1, let character = unshifted.first else { return nil }
        let usesShiftedCharacter = modifiers.contains(.shift) && !character.isLetter &&
            !character.isNumber && shifted.count == 1 && shifted != unshifted
        self.init(key: usesShiftedCharacter ? shifted : unshifted,
                  command: modifiers.contains(.command), option: modifiers.contains(.option),
                  shift: modifiers.contains(.shift) && !usesShiftedCharacter,
                  control: modifiers.contains(.control))
    }

    init?(recording event: NSEvent) {
        self.init(recordedKey: event.characters(byApplyingModifiers: []) ?? "",
                  shifted: event.characters(byApplyingModifiers: .shift) ?? "",
                  modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
    }
}

/// A field that records the next key combination pressed while it has focus, like the
/// shortcut fields in System Settings. The combination is applied once its keys are released,
/// so a wrong key can still be replaced while the modifiers are held (#52, #62).
struct ShortcutRecorder: NSViewRepresentable {
    let label: String
    let accessibilityTitle: String
    let onRecord: (ShortcutChord) -> Void
    let onClear: () -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.label = label
        view.setAccessibilityLabel(accessibilityTitle)
        view.onRecord = onRecord
        view.onClear = onClear
    }
}

final class ShortcutRecorderView: NSView {
    static let recordedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var label = "" {
        didSet { if label != oldValue { refresh() } }
    }
    var onRecord: ((ShortcutChord) -> Void)?
    var onClear: (() -> Void)?
    private(set) var isRecording = false {
        didSet { if isRecording != oldValue { refresh() } }
    }
    /// The combination pressed so far. It is applied when every key is released.
    private(set) var pendingChord: ShortcutChord? {
        didSet { if pendingChord != oldValue { refresh() } }
    }
    /// The modifier keys held while recording, shown before a key is pressed.
    private(set) var heldModifiers: NSEvent.ModifierFlags = [] {
        didSet { if heldModifiers != oldValue { refresh() } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityHelp(String(localized: "クリックしてからキーの組み合わせを押して離すと割り当てます。Deleteで解除、Escで中止します。"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 120, height: 22) }
    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }

    /// The text in the field: the shortcut, or while recording what has been pressed so far.
    var displayText: String {
        guard isRecording else { return label }
        if let pendingChord { return pendingChord.label }
        if !heldModifiers.isEmpty {
            return ShortcutChord(key: "", command: heldModifiers.contains(.command),
                                 option: heldModifiers.contains(.option),
                                 shift: heldModifiers.contains(.shift),
                                 control: heldModifiers.contains(.control)).label + "…"
        }
        return String(localized: "キーを入力…")
    }

    private func refresh() {
        needsDisplay = true
        setAccessibilityValue(displayText)
    }

    override func becomeFirstResponder() -> Bool {
        isRecording = true
        heldModifiers = NSEvent.modifierFlags.intersection(Self.recordedModifiers)
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        discardPendingKeys()
        return true
    }

    // The release of a modifier held while leaving the window never reaches this view, so a
    // combination pressed before switching away is dropped instead of applied later.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        }
        if let newWindow {
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey),
                                                   name: NSWindow.didResignKeyNotification, object: newWindow)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        discardPendingKeys()
    }

    private func discardPendingKeys() {
        pendingChord = nil
        heldModifiers = []
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self) ?? false
    }

    // ⌘ combinations arrive here before the menu bar sees them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return false }
        press(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        let modifiers = event.modifierFlags.intersection(Self.recordedModifiers)
        // A plain Tab still moves the keyboard focus.
        if event.keyCode == 48, modifiers.isEmpty || modifiers == .shift {
            return super.keyDown(with: event)
        }
        press(event)
    }

    // AppKit does not send key-up events for ⌘ combinations, so those are applied when the
    // modifiers are released instead.
    override func keyUp(with event: NSEvent) {
        guard isRecording else { return super.keyUp(with: event) }
        if heldModifiers.isEmpty { commit() }
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }
        modifiersChanged(event.modifierFlags)
    }

    /// Shows the held modifiers, and applies the pending combination once all are released.
    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        heldModifiers = flags.intersection(Self.recordedModifiers)
        if heldModifiers.isEmpty { commit() }
    }

    /// Escape and Delete act when pressed. Any other combination waits for its keys to be released.
    func press(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(Self.recordedModifiers)
        heldModifiers = modifiers
        switch event.keyCode {
        case 53 where modifiers.isEmpty: // Escape
            finish()
        case 51 where modifiers.isEmpty, 117 where modifiers.isEmpty: // Delete, Forward Delete
            onClear?()
            finish()
        default:
            guard let chord = ShortcutChord(recording: event) else { return }
            pendingChord = chord
        }
    }

    private func commit() {
        guard let chord = pendingChord else { return }
        pendingChord = nil
        onRecord?(chord)
        finish()
    }

    private func finish() {
        pendingChord = nil
        window?.makeFirstResponder(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        let frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: frame, xRadius: 5, yRadius: 5)
        (isRecording ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.15)
                     : NSColor.controlBackgroundColor).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
        let text = displayText
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: isRecording && pendingChord == nil ? NSColor.secondaryLabelColor : NSColor.labelColor
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                            y: (bounds.height - size.height) / 2),
                                withAttributes: attributes)
    }
}

/// Every command with a shortcut, each with a recorder field. Changes apply immediately.
struct EditorShortcutPreferencesView: View {
    @ObservedObject var settingsStore: EditorSettingsStore
    @State private var search = ""
    @State private var failure: (command: EditorCommand, message: String)?

    private var commands: [EditorCommand] {
        EditorShortcutRegistry.commands.filter {
            search.isEmpty || $0.title.localizedStandardContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("コマンドを検索", text: $search)
                .textFieldStyle(.roundedBorder)
            List(commands, id: \.self) { command in
                HStack {
                    Text(command.title)
                    Spacer()
                    ShortcutRecorder(label: settingsStore.shortcut(for: command)?.label
                                        ?? String(localized: "未設定"),
                                     accessibilityTitle: String(localized: "\(command.title)のショートカット"),
                                     onRecord: { assign($0, to: command) },
                                     onClear: { clear(command) })
                        .frame(width: 120, height: 22)
                    Button {
                        reset(command)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .disabled(settingsStore.app.shortcutOverrides?[command.toolbarIdentifier] == nil)
                    .help("既定に戻す")
                    .accessibilityLabel("\(command.title)を既定に戻す")
                }
            }
            if let failure {
                Label("\(failure.command.title): \(failure.message)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            } else {
                Text("欄をクリックしてキーを押し、離すと割り当てます。重複する操作やmacOSの予約操作は割り当てられません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func assign(_ chord: ShortcutChord, to command: EditorCommand) {
        do {
            try settingsStore.setShortcut(chord, for: command)
            failure = nil
        } catch {
            failure = (command, error.localizedDescription)
        }
    }

    private func clear(_ command: EditorCommand) {
        settingsStore.clearShortcut(for: command)
        failure = nil
    }

    private func reset(_ command: EditorCommand) {
        do {
            try settingsStore.resetShortcut(for: command)
            failure = nil
        } catch {
            failure = (command, error.localizedDescription)
        }
    }
}
