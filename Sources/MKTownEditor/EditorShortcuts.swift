import Foundation
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
        case .invalidKey: "キーは印字可能な1文字を指定してください。"
        case .modifierRequired: "CommandまたはControlを含めてください。"
        case .reserved: "macOSまたはアプリの標準操作に使われています。"
        case let .duplicate(title): "「\(title)」と重複しています。"
        }
    }
}

enum EditorShortcutRegistry {
    static let commands: [EditorCommand] = EditorCommand.palette

    static func shortcut(for command: EditorCommand,
                         overrides: [String: ShortcutChord]) -> ShortcutChord? {
        overrides[command.toolbarIdentifier] ?? command.shortcut.map {
            ShortcutChord(key: $0.key, modifiers: $0.modifiers)
        }
    }

    static func validate(_ chord: ShortcutChord, for command: EditorCommand,
                         overrides: [String: ShortcutChord]) throws {
        guard chord.key.count == 1, let character = chord.key.first,
              !character.isWhitespace, !character.isNewline,
              character.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { throw ShortcutError.invalidKey }
        guard chord.command || chord.control else { throw ShortcutError.modifierRequired }
        if reserved.contains(chord) { throw ShortcutError.reserved }
        if let collision = commands.first(where: { other in
            other != command && shortcut(for: other, overrides: overrides) == chord
        }) {
            throw ShortcutError.duplicate(collision.title)
        }
    }

    private static let reserved: Set<ShortcutChord> = [
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
        ShortcutChord(key: "r", option: true, shift: true),
        ShortcutChord(key: "l"), ShortcutChord(key: "p", option: true),
        ShortcutChord(key: "o", option: true), ShortcutChord(key: "o", shift: true),
        ShortcutChord(key: "+"), ShortcutChord(key: "-"), ShortcutChord(key: "0"),
        ShortcutChord(key: "+", option: true), ShortcutChord(key: "-", option: true),
        ShortcutChord(key: "0", option: true, shift: true)
    ]
}

struct EditorShortcutPreferencesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settingsStore: EditorSettingsStore
    @State private var search = ""
    @State private var selected: EditorCommand?
    @State private var draft = ShortcutChord(key: "")
    @State private var errorMessage: String?

    private var commands: [EditorCommand] {
        EditorShortcutRegistry.commands.filter {
            search.isEmpty || $0.title.localizedStandardContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ショートカット").font(.headline)
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("コマンドを選び、キーと修飾キーを設定します。重複する操作やmacOSの予約操作は保存できません。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("コマンドを検索", text: $search)
            List(commands, id: \.self) { command in
                Button {
                    selected = command
                    draft = settingsStore.shortcut(for: command) ?? ShortcutChord(key: "")
                    errorMessage = nil
                } label: {
                    HStack {
                        Text(command.title)
                        Spacer()
                        Text(settingsStore.shortcut(for: command)?.label ?? "未設定")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(height: 300)
            if let selected {
                Divider()
                Text(selected.title).font(.subheadline.weight(.semibold))
                HStack {
                    TextField("キー（1文字）", text: $draft.key).frame(width: 110)
                    Toggle("⌘", isOn: $draft.command)
                    Toggle("⌥", isOn: $draft.option)
                    Toggle("⇧", isOn: $draft.shift)
                    Toggle("⌃", isOn: $draft.control)
                }
                .toggleStyle(.checkbox)
                HStack {
                    Button("既定に戻す") {
                        do {
                            try settingsStore.resetShortcut(for: selected)
                            draft = settingsStore.shortcut(for: selected) ?? ShortcutChord(key: "")
                            errorMessage = nil
                        } catch { errorMessage = error.localizedDescription }
                    }
                    Spacer()
                    Button("設定を保存") {
                        do {
                            try settingsStore.setShortcut(draft, for: selected)
                            errorMessage = nil
                        } catch { errorMessage = error.localizedDescription }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
        .padding(20)
        .frame(width: 570)
    }
}
