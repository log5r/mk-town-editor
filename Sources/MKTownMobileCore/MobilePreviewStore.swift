import Combine
import Foundation

/// One running parse and at most one pending source per document. A parser that cannot
/// be interrupted may finish, but superseded work never publishes or builds a queue.
@MainActor
final class MobilePreviewStore: ObservableObject {
    @Published private(set) var preview = MobileMarkdownPreview("")

    private struct Request {
        let source: String
        let generation: Int
    }

    private let debounce: Duration
    private let parse: @Sendable (String) async -> MobileMarkdownPreview
    private var generation = 0
    private var requestedSource: String?
    private var pending: Request?
    private var isParsing = false
    private var debounceTask: Task<Void, Never>?

    init(debounce: Duration = .milliseconds(150),
         parse: @escaping @Sendable (String) async -> MobileMarkdownPreview = { source in
             await Task.detached(priority: .userInitiated) { MobileMarkdownPreview(source) }.value
         }) {
        self.debounce = debounce
        self.parse = parse
    }

    func update(source: String) {
        guard requestedSource != source else { return }
        generation += 1
        requestedSource = source
        pending = nil
        debounceTask?.cancel()
        let request = Request(source: source, generation: generation)
        debounceTask = Task { [weak self, debounce] in
            do { try await Task.sleep(for: debounce) } catch { return }
            guard let self, !Task.isCancelled, request.generation == generation else { return }
            debounceTask = nil
            pending = request
            startPendingIfPossible()
        }
    }

    /// Invalidate the visible document's work without claiming an uninterruptible parser
    /// has stopped. Reappearing views still wait for that parse before starting another.
    func cancel() {
        generation += 1
        requestedSource = nil
        pending = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func startPendingIfPossible() {
        guard !isParsing, let request = pending else { return }
        pending = nil
        isParsing = true
        Task { [weak self, parse] in
            let result = await parse(request.source)
            guard let self else { return }
            isParsing = false
            if request.generation == generation { preview = result }
            startPendingIfPossible()
        }
    }

    deinit { debounceTask?.cancel() }
}
