import AppKit
import SwiftUI

struct RegexSearchSheet: View {
    let source: String
    let selectedRange: NSRange
    let canReplace: Bool
    let isHighlighting: Bool
    let onSelect: (NSRange, String) -> Void
    let onReplace: (MarkdownEdit, String) -> Bool
    let onHighlight: ([NSRange], String) -> Void
    let onClearHighlights: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("documentSearchHistory") private var searchHistory = DocumentSearchHistory()
    @AppStorage("documentReplacementHistory") private var replacementHistory = DocumentSearchHistory()
    @AppStorage("documentSearchWraps") private var wraps = true
    @State private var mode: DocumentSearchMode
    @State private var pattern = ""
    @State private var replacement = ""
    @State private var options = DocumentSearchOptions()
    @State private var limitsToSelection = false
    @State private var scope: RegexSelectionScope?
    @State private var scopeSource: String?
    @State private var completedSearch: CompletedSearch?
    @State private var selectedIndex: Int?
    @State private var hasPendingSelection = false
    @State private var replacementTask: Task<Void, Never>?
    @State private var replacementError: String?

    private struct Query: Equatable, Sendable {
        let source: String
        let pattern: String
        let mode: DocumentSearchMode
        let options: DocumentSearchOptions
        let scope: NSRange?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.mode == rhs.mode && lhs.options == rhs.options && lhs.scope == rhs.scope
                && MarkdownTextFormat.identicalText(lhs.pattern, rhs.pattern)
                && MarkdownTextFormat.identicalText(lhs.source, rhs.source)
        }
    }

    private struct CompletedSearch {
        let query: Query
        let matches: [DocumentSearchMatch]
        let ranges: [NSRange]
        let hasDrawableRange: Bool
        let errorMessage: String?
    }

    init(source: String, selectedRange: NSRange, initialScope: NSRange, canReplace: Bool,
         initialMode: DocumentSearchMode, isHighlighting: Bool,
         onSelect: @escaping (NSRange, String) -> Void,
         onReplace: @escaping (MarkdownEdit, String) -> Bool,
         onHighlight: @escaping ([NSRange], String) -> Void,
         onClearHighlights: @escaping () -> Void) {
        self.source = source
        self.selectedRange = selectedRange
        self.canReplace = canReplace
        self.isHighlighting = isHighlighting
        self.onSelect = onSelect
        self.onReplace = onReplace
        self.onHighlight = onHighlight
        self.onClearHighlights = onClearHighlights
        _mode = State(initialValue: initialMode)
        let selectionScope = RegexSelectionScope(initialScope)
        _scope = State(initialValue: selectionScope)
        _scopeSource = State(initialValue: selectionScope == nil ? nil : source)
    }

    var body: some View {
        let query = query
        let matches = currentSearch?.matches ?? []
        VStack(alignment: .leading, spacing: 12) {
            Text("文書内検索・置換")
                .font(.headline)
            Form {
                LabeledContent("検索") {
                    HStack {
                        DocumentSearchField(
                            title: String(localized: "検索"),
                            placeholder: mode == .regex
                                ? String(localized: "検索パターン") : String(localized: "検索文字列"),
                            text: $pattern,
                            style: mode == .regex ? .pattern : nil,
                            autoFocus: true,
                            onMove: moveListSelection,
                            onSubmit: submitSearch
                        )
                        historyMenu("検索履歴", history: $searchHistory, field: $pattern)
                    }
                }
                LabeledContent("置換") {
                    HStack {
                        DocumentSearchField(
                            title: String(localized: "置換"),
                            placeholder: mode == .regex
                                ? String(localized: "置換文字列（$1 などで参照）") : String(localized: "置換文字列"),
                            text: $replacement,
                            style: mode == .regex ? .replacement : nil,
                            onSubmit: { move(backwards: false) }
                        )
                        historyMenu("置換履歴", history: $replacementHistory, field: $replacement)
                    }
                }
                .disabled(!canReplace)
                Picker("検索方法", selection: $mode) {
                    Text("文字列").tag(DocumentSearchMode.plain)
                    Text("正規表現").tag(DocumentSearchMode.regex)
                }
                .pickerStyle(.segmented)
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading) {
                        Toggle("大文字と小文字を区別", isOn: $options.caseSensitive)
                        Toggle("選択範囲内", isOn: $limitsToSelection).disabled(availableScope == nil)
                        Toggle("折り返し検索", isOn: $wraps)
                    }
                    if mode == .plain {
                        VStack(alignment: .leading) {
                            Toggle("全角と半角を区別しない", isOn: $options.ignoresWidth)
                            Toggle("ひらがなとカタカナを区別しない", isOn: $options.ignoresKana)
                        }
                        VStack(alignment: .leading) {
                            Toggle("アクセント記号を無視", isOn: $options.ignoresDiacritics)
                            Toggle("単語全体に一致", isOn: $options.wholeWords)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)

            status(matches.count)
            resultList(matches)

            HStack {
                Button("前を検索") { move(backwards: true) }
                    .disabled(navigationMatch(backwards: true) == nil)
                Button("次を検索") { move(backwards: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(navigationMatch(backwards: false) == nil)
                Button("すべてハイライト", action: highlightAll)
                    .disabled(currentSearch?.hasDrawableRange != true)
                Button("ハイライトを解除", action: onClearHighlights)
                    .disabled(!isHighlighting)
                Spacer()
                Button("1件置換") {
                    if let range = replacementTarget { replace(only: range) }
                }
                .disabled(!canReplace || replacementTarget == nil || replacementTask != nil)
                Button("すべて置換") { replace(only: nil) }
                    .disabled(!canReplace || matches.isEmpty || replacementTask != nil)
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(minWidth: 730, idealWidth: 770, minHeight: 440)
        .padding(20)
        .task(id: query) { await search(query) }
        .onChange(of: query) { cancelReplacement() }
        .onChange(of: replacement) {
            cancelReplacement()
            replacementError = nil
        }
        .onDisappear { cancelReplacement() }
    }

    @ViewBuilder
    private func status(_ matchCount: Int) -> some View {
        if let errorMessage = replacementError ?? currentSearch?.errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
        } else if replacementTask != nil {
            ProgressView("置換中…").controlSize(.small)
        } else if !pattern.isEmpty && currentSearch == nil {
            ProgressView("検索中…").controlSize(.small)
        } else {
            Text("\(matchCount)件の一致")
                .foregroundStyle(.secondary)
        }
    }

    private func historyMenu(_ title: LocalizedStringKey, history: Binding<DocumentSearchHistory>,
                             field: Binding<String>) -> some View {
        let entries = history.wrappedValue.entries
        return Menu {
            ForEach(entries.indices, id: \.self) { index in
                let entry = entries[index]
                Button { field.wrappedValue = entry } label: {
                    if entry.isEmpty {
                        Text("空文字列（削除）")
                    } else {
                        Text(verbatim: entry)
                    }
                }
            }
            Divider()
            Button("履歴を消去") { history.wrappedValue = DocumentSearchHistory() }
        } label: {
            Label(title, systemImage: "clock.arrow.circlepath")
                .labelStyle(.iconOnly)
        }
        .help(Text(title))
        .fixedSize()
        .disabled(entries.isEmpty)
    }

    private func resultList(_ matches: [DocumentSearchMatch]) -> some View {
        ScrollViewReader { scroll in
            List(matches.indices, id: \.self, selection: listSelection) { index in
                let match = matches[index]
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(match.lineNumber) 行")
                        .font(.subheadline.monospacedDigit())
                    Text(verbatim: match.snippet)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .activatesOnClick { activate(index) }
            }
            .activatesSelectionOnReturn(Int.self, perform: activate)
            .onChange(of: selectedIndex) {
                if let selectedIndex, matches.indices.contains(selectedIndex) {
                    scroll.scrollTo(selectedIndex)
                }
            }
        }
        .frame(minHeight: 180, idealHeight: 260)
    }

    private var listSelection: Binding<Int?> {
        Binding(get: { selectedIndex }, set: { index in
            guard !ListKeyboardSelection.isPointerEvent(NSApp.currentEvent) else { return }
            selectedIndex = index
            hasPendingSelection = index != nil
        })
    }

    private var query: Query {
        Query(source: source, pattern: pattern, mode: mode, options: options,
            scope: limitsToSelection ? availableScope?.range : nil)
    }

    private var availableScope: RegexSelectionScope? {
        guard let scopeSource, MarkdownTextFormat.identicalText(source, scopeSource) else { return nil }
        return scope
    }

    private var currentSearch: CompletedSearch? {
        guard let completedSearch, completedSearch.query == query else { return nil }
        return completedSearch
    }

    private func search(_ query: Query) async {
        if scope != nil, availableScope == nil {
            scope = nil
            scopeSource = nil
            limitsToSelection = false
        }
        selectedIndex = nil
        hasPendingSelection = false
        completedSearch = nil
        replacementError = nil
        guard !query.pattern.isEmpty else { return }
        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }

        let worker = Task.detached(priority: .userInitiated) {
            let matches = try DocumentSearch.matches(in: query.source, pattern: query.pattern,
                mode: query.mode, options: query.options, scope: query.scope)
            let ranges = matches.map(\.range)
            return (matches, ranges, ranges.contains { $0.length > 0 })
        }
        do {
            let (matches, ranges, hasDrawableRange) = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            completedSearch = CompletedSearch(query: query, matches: matches, ranges: ranges,
                                              hasDrawableRange: hasDrawableRange, errorMessage: nil)
        } catch {
            guard !Task.isCancelled else { return }
            completedSearch = CompletedSearch(query: query, matches: [], ranges: [],
                                              hasDrawableRange: false, errorMessage: error.localizedDescription)
        }
    }

    private func moveListSelection(by offset: Int) -> Bool {
        guard let matches = currentSearch?.matches, !matches.isEmpty else { return false }
        let start = selectedIndex ?? (offset < 0 ? matches.count : -1)
        selectedIndex = min(max(start + offset, 0), matches.count - 1)
        hasPendingSelection = true
        return true
    }

    private func submitSearch() {
        guard let currentSearch, currentSearch.errorMessage == nil else { return }
        if hasPendingSelection, let selectedIndex {
            activate(selectedIndex)
        } else if navigationMatch(backwards: false) != nil {
            move(backwards: false)
        } else {
            searchHistory.record(pattern)
        }
    }

    private func activate(_ index: Int) {
        guard let matches = currentSearch?.matches, matches.indices.contains(index) else { return }
        selectedIndex = index
        hasPendingSelection = false
        searchHistory.record(pattern)
        onSelect(matches[index].range, source)
    }

    private func move(backwards: Bool) {
        guard let range = navigationMatch(backwards: backwards), let ranges = currentSearch?.ranges,
              let index = DocumentSearch.index(of: range, in: ranges) else { return }
        activate(index)
    }

    private func navigationMatch(backwards: Bool) -> NSRange? {
        guard let ranges = currentSearch?.ranges else { return nil }
        if backwards {
            return DocumentSearch.previousMatch(in: ranges, before: selectedRange, wraps: wraps)
        }
        return DocumentSearch.nextMatch(in: ranges, after: selectedRange, wraps: wraps)
    }

    private var replacementTarget: NSRange? {
        guard let ranges = currentSearch?.ranges else { return nil }
        return DocumentSearch.index(of: selectedRange, in: ranges).map { ranges[$0] }
            ?? navigationMatch(backwards: false)
    }

    private func highlightAll() {
        guard let currentSearch, currentSearch.hasDrawableRange else { return }
        onHighlight(currentSearch.ranges, source)
        searchHistory.record(pattern)
    }

    private func replace(only match: NSRange?) {
        guard canReplace, replacementTask == nil,
              let currentSearch, !currentSearch.matches.isEmpty else { return }
        let request = currentSearch.query
        let template = replacement
        let tracksScope = availableScope != nil
        replacementError = nil
        let worker = Task.detached(priority: .userInitiated) { () -> (MarkdownEdit, String?)? in
            guard let edit = try DocumentSearch.replacementEdit(in: request.source, pattern: request.pattern,
                template: template, mode: request.mode, options: request.options,
                scope: request.scope, onlyMatch: match) else { return nil }
            let updatedSource = tracksScope
                ? (request.source as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
                : nil
            return (edit, updatedSource)
        }
        replacementTask = Task {
            defer { if !Task.isCancelled { replacementTask = nil } }
            do {
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                guard !Task.isCancelled, let (edit, updatedSource) = result,
                      request == query, MarkdownTextFormat.identicalText(template, replacement) else { return }
                guard onReplace(edit, request.source) else {
                    replacementError = String(localized: "置換できません。本文と編集状態を確認してください。")
                    return
                }
                searchHistory.record(request.pattern)
                replacementHistory.record(template)
                if var currentScope = scope {
                    if currentScope.apply(edit) {
                        scope = currentScope
                        scopeSource = updatedSource
                    } else {
                        scope = nil
                        scopeSource = nil
                        limitsToSelection = false
                    }
                }
            } catch {
                if !Task.isCancelled { replacementError = error.localizedDescription }
            }
        }
    }

    private func cancelReplacement() {
        replacementTask?.cancel()
        replacementTask = nil
    }
}

/// Separate persisted histories share the same ordering and size limit.
struct DocumentSearchHistory: RawRepresentable, Equatable {
    private(set) var entries: [String] = []

    init() {}

    init?(rawValue: String) {
        guard let values = try? JSONDecoder().decode([String].self, from: Data(rawValue.utf8)) else {
            return nil
        }
        entries = Array(values.prefix(20))
    }

    var rawValue: String {
        guard let data = try? JSONEncoder().encode(entries) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entries.elementsEqual(rhs.entries, by: MarkdownTextFormat.identicalText)
    }

    mutating func record(_ entry: String) {
        if let first = entries.first, MarkdownTextFormat.identicalText(first, entry) { return }
        entries.removeAll { MarkdownTextFormat.identicalText($0, entry) }
        entries.insert(entry, at: 0)
        if entries.count > 20 { entries.removeLast() }
    }
}

/// Styling uses UTF-16 ranges so the field editor keeps its original text and selection.
enum RegexSearchInputStyle {
    case pattern, replacement

    private static let patternTokens = try? NSRegularExpression(
        pattern: #"(\\Q)(?s:.*?)(\\E|\z)|\\(?:[pPxN]\{[^}]*\}|k<[^>]*>|[0-9]+|(?s:.))|\\|\(\?(?:[:=!>]|<[=!]|<[^>]*>)|\{[0-9]+(?:,[0-9]*)?\}|[.^$|?*+()\[\]{}]"#
    )
    private static let replacementTokens = try? NSRegularExpression(pattern: #"\\[\\$]|(\$[0-9]+)"#)

    func highlightedRanges(in text: String) -> [NSRange] {
        let tokenExpression = self == .pattern ? Self.patternTokens : Self.replacementTokens
        let tokens = tokenExpression?.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)) ?? []
        return tokens.flatMap { token -> [NSRange] in
            switch self {
            case .pattern:
                if token.range(at: 1).location == NSNotFound { return [token.range] }
                return [token.range(at: 1), token.range(at: 2)].filter { $0.length > 0 }
            case .replacement:
                let capture = token.range(at: 1)
                return capture.location == NSNotFound ? [] : [capture]
            }
        }
    }

    var color: NSColor { self == .pattern ? .systemPurple : .systemBlue }
}

private struct DocumentSearchField: NSViewRepresentable {
    let title: String
    let placeholder: String
    @Binding var text: String
    var style: RegexSearchInputStyle?
    var autoFocus = false
    var onMove: ((Int) -> Bool)?
    let onSubmit: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SearchTextField {
        let field = SearchTextField(string: "")
        field.delegate = context.coordinator
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.autoFocus = autoFocus
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: SearchTextField, context: Context) {
        context.coordinator.input = self
        field.placeholderString = placeholder
        field.setAccessibilityLabel(title)
        field.isEnabled = isEnabled
        if let editor = field.currentEditor() as? NSTextView {
            guard !editor.hasMarkedText() else { return }
            if !MarkdownTextFormat.identicalText(editor.string, text) {
                editor.string = text
                editor.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
            }
            context.coordinator.applyStyle(to: editor)
        } else {
            let value = NSMutableAttributedString(string: text, attributes: [.foregroundColor: NSColor.controlTextColor])
            if let style {
                for range in style.highlightedRanges(in: text) {
                    value.addAttribute(.foregroundColor, value: style.color, range: range)
                }
            }
            if !field.attributedStringValue.isEqual(to: value) { field.attributedStringValue = value }
        }
    }

    final class SearchTextField: NSTextField {
        var autoFocus = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard autoFocus, let window else { return }
            autoFocus = false
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                window.makeFirstResponder(self)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var input: DocumentSearchField
        private var styledText: String?
        private var appliedStyle: RegexSearchInputStyle?

        init(_ input: DocumentSearchField) { self.input = input }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let editor = (notification.object as? NSTextField)?.currentEditor() as? NSTextView else { return }
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isContinuousSpellCheckingEnabled = false
            styledText = nil
            applyStyle(to: editor)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let editor = (notification.object as? NSTextField)?.currentEditor() as? NSTextView,
                  !editor.hasMarkedText() else { return }
            input.text = editor.string
            applyStyle(to: editor)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch command {
            case #selector(NSResponder.moveUp(_:)): return input.onMove?(-1) ?? false
            case #selector(NSResponder.moveDown(_:)): return input.onMove?(1) ?? false
            case #selector(NSResponder.insertNewline(_:)):
                input.onSubmit()
                return true
            default: return false
            }
        }

        func applyStyle(to editor: NSTextView) {
            guard let layout = editor.layoutManager else { return }
            let text = editor.string
            if let styledText, appliedStyle == input.style,
               MarkdownTextFormat.identicalText(styledText, text) { return }
            styledText = text
            appliedStyle = input.style
            guard !text.isEmpty else { return }
            let entireText = NSRange(location: 0, length: text.utf16.count)
            layout.addTemporaryAttribute(.foregroundColor, value: NSColor.controlTextColor,
                                         forCharacterRange: entireText)
            if let style = input.style {
                for range in style.highlightedRanges(in: text) {
                    layout.addTemporaryAttribute(.foregroundColor, value: style.color, forCharacterRange: range)
                }
            }
        }
    }
}
