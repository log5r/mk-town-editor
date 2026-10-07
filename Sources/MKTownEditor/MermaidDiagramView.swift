import Foundation
import SwiftUI
import WebKit

enum MermaidDiagram {
    static func isDiagram(_ block: MarkdownBlock) -> Bool {
        block.kind == .codeBlock && block.codeLanguage?.lowercased() == "mermaid"
    }

    static func errorLine(_ message: String, explicitLine: Int?) -> Int? {
        if let explicitLine, explicitLine > 0 { return explicitLine }
        let pattern = try! NSRegularExpression(pattern: #"(?i)\bline\s+(\d+)\b"#)
        let source = message as NSString
        guard let match = pattern.firstMatch(in: message, range: NSRange(location: 0, length: source.length)),
              let line = Int(source.substring(with: match.range(at: 1))), line > 0 else { return nil }
        return line
    }

    static let bundledScript: String? = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "mermaid.min", withExtension: "js")
            ?? bundle.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "Resources") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    static func hostHTML(script: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:">
        <style>html,body{margin:0;padding:0;overflow:hidden;background:transparent;color:CanvasText}#diagram{width:100%;overflow:auto}svg{max-width:100%}</style>
        <script>\(script)</script>
        <script>
        const engine = globalThis.mermaid;
        engine.initialize({startOnLoad:false,securityLevel:'strict',theme:'default',flowchart:{htmlLabels:false}});
        async function drawDiagram(source, requestID = null) {
          const container = document.getElementById('diagram');
          container.replaceChildren();
          try {
            const result = await engine.render('mktown-diagram', source);
            container.innerHTML = result.svg;
            window.webkit.messageHandlers.diagram.postMessage({requestID:requestID,height:Math.ceil(container.scrollHeight)+8});
          } catch (error) {
            const line = error?.hash?.loc?.first_line ?? error?.hash?.line ?? null;
            window.webkit.messageHandlers.diagram.postMessage({requestID:requestID,error:String(error?.message ?? error),line:line});
          }
        }
        </script></head><body><div id="diagram"></div></body></html>
        """
    }
}

struct MermaidDiagramView: View {
    let source: String
    @State private var showsSource = false
    @State private var renderError: String?
    @State private var errorLine: Int?
    @State private var image: NSImage?
    @State private var isRendering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Mermaid図").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(showsSource ? "図を表示" : "原文を表示") { showsSource.toggle() }
                    .buttonStyle(.borderless)
            }
            if showsSource || renderError != nil {
                if let renderError {
                    if let errorLine {
                        Text("図の\(errorLine)行目: \(renderError)")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    } else {
                        Text(renderError).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                Text(source)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            } else if MermaidDiagram.bundledScript != nil {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                        .accessibilityLabel("Mermaid図")
                }
                if isRendering { ProgressView() }
            } else {
                Text("図の描画器が見つかりません。")
                    .foregroundStyle(.secondary)
                Text(source).font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: source) {
            isRendering = true
            renderError = nil
            errorLine = nil
            do {
                let result = try await MermaidRenderService.shared.render(source)
                try Task.checkCancellation()
                image = result
            } catch is CancellationError {
                return
            } catch let error as MermaidRenderError {
                guard !Task.isCancelled else { return }
                renderError = error.message
                errorLine = error.line
            } catch {
                guard !Task.isCancelled else { return }
                renderError = error.localizedDescription
            }
            isRendering = false
        }
    }
}

struct MermaidRenderError: Error {
    let message: String
    let line: Int?
}

/// A single offscreen WebKit renderer, serialized requests and cached bitmap results.
@MainActor
final class MermaidRenderService: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = MermaidRenderService()
    private var webView: WKWebView?
    private var navigation: WKNavigation?
    private let script: String?
    private var ready = false
    private struct Request {
        let id: UUID
        let source: String
        let continuation: CheckedContinuation<NSImage, Error>
    }
    private var pending: [Request] = []
    private var active: [Request] = []
    private var requestID = 0
    private var timeout: Task<Void, Never>?
    private let cache = NSCache<NSString, NSImage>()
    private(set) var webViewCreationCount = 0
    private(set) var renderCount = 0

    var pendingRequestCount: Int { pending.count }
    var activeRequestCount: Int { active.count }

    override convenience init() { self.init(script: MermaidDiagram.bundledScript) }

    init(script: String?) {
        self.script = script
        super.init()
        cache.totalCostLimit = 32_000_000
    }

    func render(_ source: String) async throws -> NSImage {
        try Task.checkCancellation()
        guard source.utf8.count <= 256_000 else {
            throw MermaidRenderError(message: ExternalDiagramError.sourceTooLarge.localizedDescription, line: nil)
        }
        if let image = cache.object(forKey: source as NSString) { return image }
        try startIfNeeded()
        let id = UUID()
        let image: NSImage = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSImage, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending.append(Request(id: id, source: source, continuation: continuation))
                pump()
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancelRequest(id) }
        }
        try Task.checkCancellation()
        return image
    }

    private func startIfNeeded() throws {
        guard webView == nil else { return }
        guard let script else {
            throw MermaidRenderError(message: String(localized: "図の描画器が見つかりません。"), line: nil)
        }
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.add(WeakMermaidMessageHandler(self), name: "diagram")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 3_000), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        webViewCreationCount += 1
        reloadRenderer()
    }

    private func reloadRenderer() {
        guard let webView else { return }
        ready = false
        timeout?.cancel()
        navigation = webView.loadHTMLString(MermaidDiagram.hostHTML(script: ""), baseURL: nil)
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard self?.ready == false else { return }
            self?.failAll(ExternalDiagramError.timedOut)
        }
    }

    private func cancelRequest(_ id: UUID) {
        let cancelled = pending.filter { $0.id == id } + active.filter { $0.id == id }
        let wasActive = active.contains { $0.id == id }
        pending.removeAll { $0.id == id }
        active.removeAll { $0.id == id }
        cancelled.forEach { $0.continuation.resume(throwing: CancellationError()) }
        if wasActive, active.isEmpty, let source = cancelled.first?.source {
            // Requests arriving after rendering started still share its result.
            active = pending.filter { $0.source == source }
            pending.removeAll { $0.source == source }
            guard active.isEmpty else { return }
            // Invalidate late JavaScript/snapshot callbacks and discard the abandoned
            // JS context. Reload the existing view, keeping its script and image cache.
            requestID += 1
            reloadRenderer()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, navigation === self.navigation else { return }
        timeout?.cancel(); ready = true; pump()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView, navigation === self.navigation else { return }
        failAll(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView, navigation === self.navigation else { return }
        failAll(error)
    }

    private func failAll(_ error: Error) {
        let requests = active + pending
        active.removeAll(); pending.removeAll()
        timeout?.cancel()
        requests.forEach { $0.continuation.resume(throwing: error) }
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "diagram")
        webView = nil; navigation = nil; ready = false
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.scheme == "about" ? .allow : .cancel
    }

    private func pump() {
        guard ready, active.isEmpty, let first = pending.first, let webView else { return }
        active = pending.filter { $0.source == first.source }
        pending.removeAll { $0.source == first.source }
        requestID += 1
        let token = requestID
        renderCount += 1
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.complete(.failure(MermaidRenderError(message: ExternalDiagramError.timedOut.localizedDescription, line: nil)), token: token)
        }
        let encoded = String(data: try! JSONSerialization.data(withJSONObject: [first.source, token]), encoding: .utf8)!
        webView.evaluateJavaScript("drawDiagram(...\(encoded)); 0") { [weak self] _, error in
            if let error { self?.complete(.failure(error), token: token) }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let token = body["requestID"] as? Int,
              token == requestID, !active.isEmpty, let webView else { return }
        if let error = body["error"] as? String {
            complete(.failure(MermaidRenderError(message: error,
                line: MermaidDiagram.errorLine(error, explicitLine: body["line"] as? Int))), token: token)
            return
        }
        let measured = (body["height"] as? Double) ?? 120
        guard measured.isFinite, measured <= 32_768 else {
            complete(.failure(ExternalDiagramError.sourceTooLarge), token: token)
            return
        }
        let height = max(40, measured)
        webView.frame.size.height = height
        let configuration = WKSnapshotConfiguration()
        configuration.rect = NSRect(x: 0, y: 0, width: 900, height: height)
        // Preserve tall diagrams without clipping while bounding bitmap memory.
        configuration.snapshotWidth = NSNumber(value: min(900, sqrt(4_000_000 * 900 / height)))
        webView.takeSnapshot(with: configuration) { [weak self] image, error in
            guard let self else { return }
            if let image { self.complete(.success(image), token: token) }
            else { self.complete(.failure(error ?? ExternalDiagramError.invalidImage), token: token) }
        }
    }

    private func complete(_ result: Result<NSImage, Error>, token: Int) {
        guard token == requestID, let first = active.first else { return }
        timeout?.cancel()
        let requests = active + pending.filter { $0.source == first.source }
        pending.removeAll { $0.source == first.source }
        active.removeAll()
        if case let .success(image) = result {
            cache.setObject(image, forKey: first.source as NSString,
                cost: Int(image.size.width * image.size.height * 4))
        }
        requests.forEach { $0.continuation.resume(with: result) }
        pump()
    }
}

@MainActor
private final class WeakMermaidMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var renderer: MermaidRenderService?
    init(_ renderer: MermaidRenderService) { self.renderer = renderer }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        renderer?.userContentController(userContentController, didReceive: message)
    }
}
