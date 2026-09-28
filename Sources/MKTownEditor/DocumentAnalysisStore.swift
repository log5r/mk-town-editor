import Combine
import Foundation

/// Values derived from exactly one immutable version of a document.
struct DocumentSnapshot: Sendable {
    let source: String
    let dialect: MarkdownDialect
    let analysis: MarkdownAnalysis
    let statistics: DocumentStatistics
    let syntaxSpans: [MarkdownSyntaxSpan]

    init(source: String, dialect: MarkdownDialect = .extended) {
        let parsed = MarkdownAnalysis(source, dialect: dialect)
        self.source = source
        self.dialect = dialect
        analysis = parsed
        statistics = DocumentStatistics(text: source)
        syntaxSpans = MarkdownSyntaxHighlighter.spans(in: source, analysis: parsed)
    }
}

@MainActor
final class DocumentAnalysisStore: ObservableObject {
    @Published private(set) var snapshot: DocumentSnapshot?
    private let analyze: @Sendable (String) async -> DocumentSnapshot
    private var generation = 0
    private var task: Task<Void, Never>?
    private var requestedSource: String?
    private var requestedDialect: MarkdownDialect?

    init(analyze: @escaping @Sendable (String) async -> DocumentSnapshot = { DocumentSnapshot(source: $0) }) {
        self.analyze = analyze
    }

    func update(source: String, dialect: MarkdownDialect = .extended) {
        if snapshot?.source == source && snapshot?.dialect == dialect {
            if requestedSource != nil { cancel() }
            return
        }
        if requestedSource == source && requestedDialect == dialect { return }
        generation += 1
        let requestedGeneration = generation
        requestedSource = source
        requestedDialect = dialect
        task?.cancel()
        task = Task.detached(priority: .userInitiated) { [weak self, analyze] in
            let result = dialect == .extended
                ? await analyze(source) : DocumentSnapshot(source: source, dialect: dialect)
            await self?.publish(result, generation: requestedGeneration)
        }
    }

    private func publish(_ result: DocumentSnapshot, generation requestedGeneration: Int) {
        guard generation == requestedGeneration else { return }
        requestedSource = nil
        requestedDialect = nil
        snapshot = result
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        requestedSource = nil
        requestedDialect = nil
    }
}
