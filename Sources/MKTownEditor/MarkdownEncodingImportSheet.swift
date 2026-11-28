import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct MarkdownEncodingPreview: View {
    @Binding var encoding: MarkdownTextEncoding
    let decodedText: String?

    var body: some View {
        Picker("読み込み", selection: $encoding) {
            ForEach(MarkdownTextEncoding.allCases) { encoding in
                Text(encoding.title).tag(encoding)
            }
        }
        if let decodedText {
            ScrollView {
                Text(verbatim: decodedText.isEmpty ? String(localized: "空の書類") : String(decodedText.prefix(1_000)))
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: 150)
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Text("先頭1,000文字を表示しています。").font(.caption).foregroundStyle(.secondary)
        } else {
            Text("この文字コードでは損失なく読めません。別の候補を選んでください。")
                .foregroundStyle(.red)
        }
    }
}

struct MarkdownEncodingPicker: View {
    @Environment(\.dismiss) private var dismiss
    let sourceData: Data
    let isReload: Bool
    let onOpen: (MarkdownDocument) -> Void
    let onCancel: (() -> Void)?
    @State private var encoding: MarkdownTextEncoding
    @State private var cache = DerivedValueCache<MarkdownTextEncoding, MarkdownDocument?>()

    init(sourceData: Data, initialEncoding: MarkdownTextEncoding = .utf8, isReload: Bool = false,
         onOpen: @escaping (MarkdownDocument) -> Void, onCancel: (() -> Void)? = nil) {
        self.sourceData = sourceData
        self.isReload = isReload
        self.onOpen = onOpen
        self.onCancel = onCancel
        _encoding = State(initialValue: initialEncoding)
    }

    var body: some View {
        let document = cache.value(for: encoding) { try? MarkdownDocument(data: sourceData, encoding: $0) }
        VStack(alignment: .leading, spacing: 14) {
            Text("文字コードを選んで開く").font(.headline)
            if isReload {
                Text("開くと、編集中の本文をディスクから読み直した内容に置き換えます。")
            } else {
                Text("文字コードを判別できませんでした。読み込みに使う文字コードを選び、本文を確認してください。")
            }
            MarkdownEncodingPreview(encoding: $encoding, decodedText: document?.text)
            HStack {
                Spacer()
                Button("キャンセル") {
                    if let onCancel { onCancel() } else { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                Button("開く") { if let document { onOpen(document) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(document == nil)
            }
        }
        .frame(width: 520)
        .padding(20)
    }
}

struct MarkdownEncodingImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sourceEncoding: MarkdownTextEncoding = .utf8
    @State private var destinationEncoding: MarkdownTextEncoding = .utf8
    @State private var errorMessage: String?
    @State private var decodedCache = DerivedValueCache<MarkdownTextEncoding, String?>()

    let sourceURL: URL
    let sourceData: Data
    let onSaved: (URL) -> Void

    var body: some View {
        // 全体のデコードと往復検証は、読み込みの文字コードを変えた時だけ行う。
        let decodedText = decodedCache.value(for: sourceEncoding) { encoding in
            try? MarkdownEncodingConverter.read(sourceData, as: encoding).text
        }
        VStack(alignment: .leading, spacing: 14) {
            Text("文字コードを指定して取り込む").font(.headline)
            Text(sourceURL.lastPathComponent).foregroundStyle(.secondary)
            MarkdownEncodingPreview(encoding: $sourceEncoding, decodedText: decodedText)
            Picker("保存形式", selection: $destinationEncoding) {
                ForEach(MarkdownTextEncoding.allCases) { encoding in
                    Text(encoding.title).tag(encoding)
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("変換して保存…") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(decodedText == nil)
            }
        }
        .frame(width: 540)
        .padding(20)
    }

    private func save() {
        let converted: Data
        do {
            converted = try MarkdownEncodingConverter.convert(sourceData, from: sourceEncoding,
                                                              to: destinationEncoding)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [MarkdownDocument.markdownType]
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent +
            "-converted.md"
        let encoding = destinationEncoding
        panel.beginAttached { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                try converted.write(to: destination, options: .atomic)
                dismiss()
                if encoding == .utf8 { onSaved(destination) }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct MarkdownEncodingLoss: Sendable {
    struct Input: Equatable {
        let source: String
        let encoding: MarkdownTextEncoding

        init?(document: MarkdownDocument) {
            switch document.encoding {
            case .utf8, .utf16BE, .utf16LE: return nil
            default:
                source = document.text
                encoding = document.encoding
            }
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            guard lhs.encoding == rhs.encoding else { return false }
            // Swift String equality treats NFC and NFD as equal, even when only one can be saved.
            var left = lhs.source, right = rhs.source
            return left.withUTF8 { a in right.withUTF8 { b in
                a.count == b.count && (a.baseAddress == b.baseAddress || a.elementsEqual(b))
            } }
        }
    }

    struct Occurrence: Identifiable, Sendable {
        let range: NSRange
        let line: Int
        let utf16Column: Int
        let character: String
        var id: Int { range.location }
    }

    let source: String
    let encoding: MarkdownTextEncoding
    let occurrences: [Occurrence]

    init?(source: String, encoding: MarkdownTextEncoding) {
        guard let ranges = try? MarkdownEncodingConverter.unrepresentableRanges(
            in: source, as: encoding, checkCancellation: { try Task.checkCancellation() }),
              let last = ranges.last else { return nil }
        let lines = MarkdownLineIndex(source, through: NSMaxRange(last))
        let nsText = source as NSString
        self.source = source
        self.encoding = encoding
        occurrences = ranges.map { range in
            let line = lines.line(containingUTF16Offset: range.location)
            return Occurrence(range: range, line: line,
                              utf16Column: range.location - lines.starts[line - 1] + 1,
                              character: nsText.substring(with: range))
        }
    }
}

struct MarkdownEncodingLossSheet: View {
    @Environment(\.dismiss) private var dismiss
    let loss: MarkdownEncodingLoss?
    let isLocked: Bool
    let onResolve: (_ convertToUTF8: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("保存できない文字").font(.headline)
            if let loss {
                Text("\(loss.encoding.title)で表せない文字が\(loss.occurrences.count)箇所あります。")
                List(loss.occurrences) { item in
                    HStack {
                        Text("\(item.line)行・\(item.utf16Column)列（UTF-16）")
                            .monospacedDigit()
                        Text(verbatim: item.character)
                    }
                }
                Text("UTF-8で保存すると本文を保持できます。元の文字コードで保存すると、一覧の文字が「?」に置き換わります。")
                    .font(.callout)
            } else {
                Text("保存できない文字はありません。")
            }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                if loss != nil {
                    Button("「?」に置換して保存", role: .destructive) { onResolve(false) }
                        .disabled(isLocked)
                    Button("UTF-8で保存") { onResolve(true) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isLocked)
                }
            }
        }
        .padding(20)
        .frame(width: 550, height: loss == nil ? 160 : 360)
    }
}
