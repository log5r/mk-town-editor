import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class ReplacementSetLibrary: ObservableObject {
    static let shared = ReplacementSetLibrary()
    private static let storageKey = "savedReplacementSets"

    @Published private(set) var sets: [ReplacementSet] {
        didSet {
            if let data = try? JSONEncoder().encode(sets) {
                UserDefaults.standard.set(data, forKey: Self.storageKey)
            }
        }
    }

    private init() {
        let data = UserDefaults.standard.data(forKey: Self.storageKey)
        sets = data.flatMap { try? JSONDecoder().decode([ReplacementSet].self, from: $0) } ?? []
    }

    func append(_ set: ReplacementSet) { sets.append(set) }

    func remove(_ id: UUID) { sets.removeAll { $0.id == id } }

    func update(_ id: UUID, _ change: (inout ReplacementSet) -> Void) {
        guard let index = sets.firstIndex(where: { $0.id == id }) else { return }
        change(&sets[index])
    }

    func updateRule(_ ruleID: UUID, in setID: UUID, _ change: (inout ReplacementRule) -> Void) {
        update(setID) { set in
            guard let index = set.rules.firstIndex(where: { $0.id == ruleID }) else { return }
            change(&set.rules[index])
        }
    }
}

struct ReplacementSetSheet: View {
    let source: String
    let canApply: Bool
    let dialect: MarkdownDialect
    let onApply: (ReplacementSetPlan) -> Bool
    let onHighlight: (String, [NSRange]) -> Bool

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = ReplacementSetLibrary.shared
    @State private var selection: OriginalSelection?
    @State private var selectedSetID: UUID?
    @State private var selectedRuleID: UUID?
    @State private var setToDelete: ReplacementSet?
    @State private var confirmsDeletion = false
    @State private var limitsToSelection = false
    @State private var excludesCode = false
    @State private var preview: Preview?
    @State private var operation: Operation?
    @State private var work: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var isHandlingFile = false

    private struct OriginalSelection {
        let source: MarkdownSourceText
        let range: NSRange
    }

    private struct Request: Equatable, Sendable {
        let set: ReplacementSet
        let source: MarkdownSourceText
        let selection: NSRange?
        let excludesCode: Bool
        let dialect: MarkdownDialect

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.set.id == rhs.set.id && lhs.selection == rhs.selection &&
                lhs.excludesCode == rhs.excludesCode && lhs.dialect == rhs.dialect &&
                lhs.source == rhs.source &&
                lhs.set.rules.elementsEqual(rhs.set.rules) { left, right in
                    left.id == right.id && left.isEnabled == right.isEnabled &&
                        left.usesRegularExpression == right.usesRegularExpression &&
                        left.caseSensitive == right.caseSensitive &&
                        MarkdownTextFormat.identicalText(left.pattern, right.pattern) &&
                        MarkdownTextFormat.identicalText(left.replacement, right.replacement)
                }
        }
    }

    private struct Preview {
        let request: Request
        let plan: ReplacementSetPlan
    }

    private enum Operation { case preview, highlight }

    init(source: String, selectedRange: NSRange?, selectionSource: String, canApply: Bool, dialect: MarkdownDialect,
         onApply: @escaping (ReplacementSetPlan) -> Bool,
         onHighlight: @escaping (String, [NSRange]) -> Bool) {
        self.source = source
        self.canApply = canApply
        self.dialect = dialect
        self.onApply = onApply
        self.onHighlight = onHighlight
        if let selectedRange, selectedRange.location >= 0, selectedRange.length > 0 {
            let length = selectionSource.utf16.count
            if selectedRange.location <= length, selectedRange.length <= length - selectedRange.location {
                _selection = State(initialValue: OriginalSelection(source: MarkdownSourceText(selectionSource),
                                                                   range: selectedRange))
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("置換セット").font(.headline)
            setControls
            if let set = selectedSet {
                LabeledContent("セット名") {
                    TextField("セット名", text: nameBinding(for: set)).labelsHidden().id(set.id)
                }
                ruleEditor(in: set)
            } else {
                ContentUnavailableView("置換セットがありません", systemImage: "text.badge.plus",
                                       description: Text("新規作成するか、ファイルから読み込んでください。"))
                    .frame(height: 174)
            }
            Divider()
            HStack(spacing: 20) {
                Toggle("選択範囲内", isOn: $limitsToSelection).disabled(selection == nil)
                Toggle("コードブロックとインラインコードを除外", isOn: $excludesCode)
            }
            .disabled(selectedSet == nil)
            status
            GitDiffView(diff: currentPreview?.diff ?? "", placeholder: currentPreview == nil
                ? String(localized: "「差分を確認」で置換内容を表示します。") : String(localized: "差分なし"))
                .frame(maxHeight: .infinity)
                .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
            actions
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 380, idealHeight: 460)
        .padding(20)
        .onAppear { selectAvailableSet() }
        .onChange(of: library.sets.map(\.id)) { selectAvailableSet() }
        .onChange(of: selectedSet?.rules.map(\.id)) { selectAvailableRule() }
        .onChange(of: request) { invalidatePreview() }
        .onDisappear { work?.cancel() }
        .alert("置換セットを削除しますか？", isPresented: $confirmsDeletion, presenting: setToDelete) { set in
            Button("削除", role: .destructive) { library.remove(set.id) }
            Button("キャンセル", role: .cancel) {}
        } message: { set in
            Text("「\(displayName(for: set))」のルールがすべて削除されます。")
        }
    }

    private var setControls: some View {
        HStack {
            Picker("置換セット", selection: $selectedSetID) {
                if selectedSet == nil { Text("セットを選択").tag(nil as UUID?) }
                ForEach(library.sets) { set in
                    Text(verbatim: displayName(for: set)).tag(Optional(set.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .disabled(library.sets.isEmpty)
            Button("新規") {
                add(ReplacementSet(name: String(localized: "新規セット"), rules: [ReplacementRule()]))
            }
            Button("複製") {
                guard let set = selectedSet else { return }
                add(set.duplicated(named: String(localized: "\(displayName(for: set))のコピー")))
            }
            .disabled(selectedSet == nil)
            Button("読み込む…", action: importFile)
            Button("書き出す…", action: exportFile).disabled(selectedSet == nil)
            iconButton("置換セットを削除", symbol: "trash") {
                setToDelete = selectedSet
                confirmsDeletion = true
            }
            .disabled(selectedSet == nil)
        }
        .disabled(isHandlingFile)
    }

    private func ruleEditor(in set: ReplacementSet) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                List(selection: $selectedRuleID) {
                    ForEach(Array(set.rules.enumerated()), id: \.element.id) { index, rule in
                        HStack(spacing: 8) {
                            Text((index + 1).formatted()).monospacedDigit().foregroundStyle(.secondary)
                            Text(verbatim: rule.pattern.isEmpty ? String(localized: "新規ルール") : rule.pattern)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if !rule.isEnabled {
                                Image(systemName: "pause.circle").accessibilityLabel("無効")
                            }
                        }
                        .tag(rule.id)
                        .accessibilityElement(children: .combine)
                    }
                }
                .listStyle(.bordered)
                .accessibilityLabel("置換ルール")
                HStack(spacing: 4) {
                    iconButton("ルールを追加", symbol: "plus") { addRule(to: set.id) }
                    iconButton("ルールを削除", symbol: "minus", action: removeRule)
                        .disabled(selectedRule == nil)
                    Spacer()
                    iconButton("ルールを上へ移動", symbol: "arrow.up") { moveRule(by: -1) }
                        .disabled(!canMoveRule(by: -1))
                    iconButton("ルールを下へ移動", symbol: "arrow.down") { moveRule(by: 1) }
                        .disabled(!canMoveRule(by: 1))
                }
            }
            .frame(width: 228)
            if let rule = selectedRule {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("検索文字列") {
                        DocumentSearchField(title: String(localized: "検索文字列"),
                            placeholder: rule.usesRegularExpression ? String(localized: "検索パターン") : "",
                            text: ruleBinding(\.pattern, rule: rule, in: set.id),
                            style: rule.usesRegularExpression ? .pattern : nil,
                            onSubmit: { prepare(.preview) })
                    }
                    LabeledContent("置換文字列") {
                        DocumentSearchField(title: String(localized: "置換文字列"),
                            placeholder: rule.usesRegularExpression
                                ? String(localized: "置換文字列（$1 などで参照）") : "",
                            text: ruleBinding(\.replacement, rule: rule, in: set.id),
                            style: rule.usesRegularExpression ? .replacement : nil,
                            onSubmit: { prepare(.preview) })
                    }
                    LabeledContent("メモ") {
                        TextField("メモ", text: ruleBinding(\.notes, rule: rule, in: set.id)).labelsHidden()
                    }
                    HStack {
                        Toggle("有効", isOn: ruleBinding(\.isEnabled, rule: rule, in: set.id))
                        Toggle("正規表現", isOn: ruleBinding(\.usesRegularExpression, rule: rule, in: set.id))
                        Toggle("大文字と小文字を区別", isOn: ruleBinding(\.caseSensitive, rule: rule, in: set.id))
                    }
                }
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
                .id(rule.id)
            } else {
                Text("ルールを追加してください。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 145)
    }

    @ViewBuilder
    private var status: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.circle").foregroundStyle(.red)
        } else if limitsToSelection && availableScope == nil {
            Label("本文が変更されました。選択範囲を使うには、置換セットを開き直してください。",
                  systemImage: "exclamationmark.circle").foregroundStyle(.red)
        } else if let operation {
            ProgressView {
                if operation == .preview { Text("差分を確認中…") } else { Text("検索中…") }
            }
            .controlSize(.small)
        } else if let preview = currentPreview {
            HStack {
                Text("\(preview.matchCount)件の置換")
                if preview.edit == nil { Text("適用後の本文に変更はありません。") }
            }
            .foregroundStyle(.secondary)
        } else {
            Text("有効なルールを上から順に適用します。")
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack {
            Button("すべてハイライト") { prepare(.highlight) }
                .help("元の本文で各ルールに一致する箇所を表示します。")
                .disabled(request == nil || operation != nil)
            Spacer()
            Button("閉じる") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("差分を確認") { prepare(.preview) }
                .keyboardShortcut(.defaultAction)
                .disabled(request == nil || operation != nil)
            Button("適用") { applyPreview() }
                .disabled(!canApply || currentPreview?.edit == nil || operation != nil)
        }
        .disabled(isHandlingFile)
    }

    private func iconButton(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).labelStyle(.iconOnly) }
            .help(Text(title))
    }

    private var selectedSet: ReplacementSet? { library.sets.first { $0.id == selectedSetID } }
    private var selectedRule: ReplacementRule? { selectedSet?.rules.first { $0.id == selectedRuleID } }

    private var availableScope: NSRange? {
        guard let selection, selection.source == MarkdownSourceText(source) else { return nil }
        return selection.range
    }

    private var request: Request? {
        guard let set = selectedSet, set.rules.contains(where: \.isEnabled),
              !limitsToSelection || availableScope != nil else { return nil }
        return Request(set: set, source: MarkdownSourceText(source), selection: limitsToSelection ? availableScope : nil,
                       excludesCode: excludesCode, dialect: dialect)
    }

    private var currentPreview: ReplacementSetPlan? {
        guard let preview, preview.request == request else { return nil }
        return preview.plan
    }

    private func displayName(for set: ReplacementSet) -> String {
        let name = set.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "名称未設定") : name
    }

    private func nameBinding(for set: ReplacementSet) -> Binding<String> {
        Binding(get: { library.sets.first { $0.id == set.id }?.name ?? set.name }, set: { value in
            library.update(set.id) { $0.name = value }
        })
    }

    private func ruleBinding<Value>(_ keyPath: WritableKeyPath<ReplacementRule, Value>,
                                    rule: ReplacementRule, in setID: UUID) -> Binding<Value> {
        Binding(get: {
            library.sets.first { $0.id == setID }?.rules.first { $0.id == rule.id }?[keyPath: keyPath]
                ?? rule[keyPath: keyPath]
        }, set: { value in
            library.updateRule(rule.id, in: setID) { $0[keyPath: keyPath] = value }
        })
    }

    private func selectAvailableSet() {
        if selectedSet == nil { selectedSetID = library.sets.first?.id }
        selectAvailableRule()
    }

    private func selectAvailableRule() {
        if selectedRule == nil { selectedRuleID = selectedSet?.rules.first?.id }
    }

    private func add(_ set: ReplacementSet) {
        library.append(set)
        selectedSetID = set.id
        selectedRuleID = set.rules.first?.id
    }

    private func addRule(to setID: UUID) {
        let rule = ReplacementRule()
        library.update(setID) { $0.rules.append(rule) }
        selectedRuleID = rule.id
    }

    private func removeRule() {
        guard let set = selectedSet, let rule = selectedRule,
              let index = set.rules.firstIndex(where: { $0.id == rule.id }) else { return }
        let neighbor = set.rules.dropFirst(index + 1).first ?? set.rules.prefix(index).last
        library.update(set.id) { $0.rules.remove(at: index) }
        selectedRuleID = neighbor?.id
    }

    private func canMoveRule(by offset: Int) -> Bool {
        guard let set = selectedSet, let index = set.rules.firstIndex(where: { $0.id == selectedRuleID }) else {
            return false
        }
        return set.rules.indices.contains(index + offset)
    }

    private func moveRule(by offset: Int) {
        guard let set = selectedSet, let index = set.rules.firstIndex(where: { $0.id == selectedRuleID }),
              set.rules.indices.contains(index + offset) else { return }
        library.update(set.id) { $0.rules.swapAt(index, index + offset) }
    }

    private func prepare(_ nextOperation: Operation) {
        guard let request, operation == nil else { return }
        invalidatePreview()
        operation = nextOperation
        work = Task {
            defer {
                if !Task.isCancelled {
                    operation = nil
                    work = nil
                }
            }
            do {
                switch nextOperation {
                case .preview:
                    let plan = try await DocumentWork.perform {
                        try request.set.plan(in: request.source.text, selection: request.selection,
                                             excludesCode: request.excludesCode, dialect: request.dialect)
                    }
                    guard !Task.isCancelled, request == self.request else { return }
                    preview = Preview(request: request, plan: plan)
                case .highlight:
                    let ranges = try await DocumentWork.perform {
                        try request.set.highlights(in: request.source.text, selection: request.selection,
                                                   excludesCode: request.excludesCode, dialect: request.dialect)
                    }
                    guard !Task.isCancelled, request == self.request else { return }
                    if ranges.isEmpty {
                        errorMessage = String(localized: "ハイライトできる一致箇所がありません。")
                    } else if onHighlight(request.source.text, ranges) {
                        dismiss()
                    } else {
                        errorMessage = String(localized: "本文が変更されました。もう一度検索してください。")
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled, request == self.request { errorMessage = error.localizedDescription }
            }
        }
    }

    private func applyPreview() {
        guard canApply, let plan = currentPreview, plan.edit != nil else { return }
        if onApply(plan) {
            dismiss()
        } else {
            invalidatePreview()
            errorMessage = String(localized: "置換できませんでした。本文と編集状態を確認し、差分を確認し直してください。")
        }
    }

    private func invalidatePreview() {
        work?.cancel()
        work = nil
        operation = nil
        preview = nil
        errorMessage = nil
    }

    private func importFile() {
        isHandlingFile = true
        errorMessage = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .tabSeparatedText, .plainText]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "読み込む")
        panel.beginAttached { response in
            panel.orderOut(nil)
            guard response == .OK, let url = panel.url else {
                isHandlingFile = false
                return
            }
            Task {
                defer { isHandlingFile = false }
                do {
                    let imported = try await DocumentWork.perform {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let data = try Data(contentsOf: url)
                        if url.pathExtension.caseInsensitiveCompare("json") == .orderedSame {
                            return try ReplacementSet.fromJSON(data)
                        }
                        return try ReplacementSet.fromTSV(data, named: url.deletingPathExtension().lastPathComponent)
                    }
                    add(imported)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func exportFile() {
        guard let set = selectedSet else { return }
        isHandlingFile = true
        errorMessage = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        let name = displayName(for: set).replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(name).json"
        panel.beginAttached { response in
            panel.orderOut(nil)
            guard response == .OK, let url = panel.url else {
                isHandlingFile = false
                return
            }
            Task {
                defer { isHandlingFile = false }
                do {
                    try await DocumentWork.commit {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        try set.jsonData().write(to: url, options: .atomic)
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
