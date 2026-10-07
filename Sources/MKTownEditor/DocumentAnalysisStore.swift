import Combine
import Foundation
import CryptoKit

/// Values derived from exactly one immutable version of a document.
struct DocumentSnapshot: Sendable {
    let source: String
    let dialect: MarkdownDialect
    let analysis: MarkdownAnalysis
    let statistics: DocumentStatistics
    let wordCounts: [WordCountMode: Int]
    let outlineEntries: [MarkdownOutlineEntry]
    let sectionActions: [Int: MarkdownSectionActions]
    let syntaxSpans: [MarkdownSyntaxSpan]
    let blockPresentationIDs: [Int: String]
    let hoverLinks: [MarkdownHoverLink]
    let proofingRanges: [MarkdownProofingContext.ProtectedRange]
    let inlineCodeRanges: [NSRange]
    let remoteImageURLs: Set<URL>
    let previewLayout: PreviewLayoutIndex
    let needsStructuredPreview: Bool

    init(source: String, dialect: MarkdownDialect = .extended) {
        self.init(source: source, dialect: dialect, checkCancellation: {})
    }

    static func observingCancellation(source: String, dialect: MarkdownDialect = .extended) throws -> Self {
        try Self(source: source, dialect: dialect, checkCancellation: { try Task.checkCancellation() })
    }

    init<Failure>(source: String, dialect: MarkdownDialect,
                  checkCancellation: () throws(Failure) -> Void) throws(Failure) {
        try checkCancellation()
        let parsed = MarkdownAnalysis(source, dialect: dialect)
        try checkCancellation()
        self.source = source
        self.dialect = dialect
        analysis = parsed
        blockPresentationIDs = PreviewBlockIdentity.identifiers(in: parsed)
        try checkCancellation()
        outlineEntries = MarkdownOutline.entries(in: parsed)
        sectionActions = MarkdownSectionActions.all(in: outlineEntries)
        try checkCancellation()
        statistics = try DocumentStatistics.scan(source, checkCancellation: checkCancellation)
        wordCounts = [.whitespace: statistics.words,
                      .japanese: try WordCountMode.japanese.count(in: source, checkCancellation: checkCancellation),
                      .english: try WordCountMode.english.count(in: source, checkCancellation: checkCancellation)]
        try checkCancellation()
        syntaxSpans = MarkdownSyntaxHighlighter.spans(in: source, analysis: parsed)
        try checkCancellation()
        hoverLinks = MarkdownLinkHover.links(in: source, analysis: parsed)
        try checkCancellation()
        proofingRanges = MarkdownProofingContext.protectedRanges(in: source, analysis: parsed)
        try checkCancellation()
        inlineCodeRanges = MarkdownInlineSyntax.codeSpanRanges(in: source)
        try checkCancellation()
        remoteImageURLs = RemoteImageStore.referencedURLs(in: source, analysis: parsed)
        try checkCancellation()
        previewLayout = PreviewLayoutIndex(parsed)
        needsStructuredPreview = PreviewStructure.needsStructuredLayout(parsed, source: source)
        try checkCancellation()
    }

    /// Source offsets and parsed structure are valid only for both inputs.
    func matches(source: String, dialect: MarkdownDialect) -> Bool {
        self.dialect == dialect && self.source == source
    }
}

/// Stable SwiftUI identities, also used by previews without a shared snapshot.
enum PreviewBlockIdentity {
    static func identifiers(in analysis: MarkdownAnalysis) -> [Int: String] {
        var occurrences: [String: Int] = [:]
        return Dictionary(uniqueKeysWithValues: analysis.blocks.map { block in
            let key = "\(block.kind):\(block.codeLanguage ?? ""):\(block.content)"
            let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            let occurrence = occurrences[digest, default: 0]
            occurrences[digest] = occurrence + 1
            return (block.id, "\(digest):\(occurrence)")
        })
    }
}

/// Keep the last completed preview visible while the next source is being analyzed.
/// Source-based actions must only use a snapshot that matches the live document.
struct PreviewPresentation {
    let snapshot: DocumentSnapshot?
    let source: String
    let isCurrent: Bool

    init(snapshot: DocumentSnapshot?, requestedSource: String,
         currentSource: String, dialect: MarkdownDialect) {
        self.snapshot = snapshot?.dialect == dialect ? snapshot : nil
        source = self.snapshot?.source ?? requestedSource
        isCurrent = self.snapshot != nil && source == currentSource
    }
}

@MainActor
final class DocumentAnalysisStore: ObservableObject {
    @Published private(set) var snapshot: DocumentSnapshot?
    private let analyze: @Sendable (String) async throws -> DocumentSnapshot
    private var generation = 0
    private var task: Task<Void, Never>?
    private var requestedSource: String?
    private var requestedDialect: MarkdownDialect?

    init(analyze: @escaping @Sendable (String) async throws -> DocumentSnapshot = { try DocumentSnapshot.observingCancellation(source: $0) }) {
        self.analyze = analyze
    }

    func update(source: String, dialect: MarkdownDialect = .extended) {
        var source = source
        source.makeContiguousUTF8()
        if snapshot?.matches(source: source, dialect: dialect) == true {
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
            do {
                try Task.checkCancellation()
                let result = dialect == .extended
                    ? try await analyze(source) : try DocumentSnapshot.observingCancellation(source: source, dialect: dialect)
                try Task.checkCancellation()
                await self?.publish(result, generation: requestedGeneration)
            } catch { /* Superseded analysis never publishes a partial snapshot. */ }
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
