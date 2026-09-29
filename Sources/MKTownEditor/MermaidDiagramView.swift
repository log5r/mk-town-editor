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
        async function drawDiagram(source) {
          const container = document.getElementById('diagram');
          container.replaceChildren();
          try {
            const result = await engine.render('mktown-diagram', source);
            container.innerHTML = result.svg;
            window.webkit.messageHandlers.diagram.postMessage({height:Math.ceil(container.scrollHeight)+8});
          } catch (error) {
            const line = error?.hash?.loc?.first_line ?? error?.hash?.line ?? null;
            window.webkit.messageHandlers.diagram.postMessage({error:String(error?.message ?? error),line:line});
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
    @State private var diagramHeight: CGFloat = 120

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
            } else if let script = MermaidDiagram.bundledScript {
                MermaidWebView(source: source, script: script) { height, error, line in
                    diagramHeight = max(40, min(height, 3000))
                    renderError = error
                    errorLine = MermaidDiagram.errorLine(error ?? "", explicitLine: line)
                }
                .frame(height: diagramHeight)
                .accessibilityLabel("Mermaid図")
            } else {
                Text("図の描画器が見つかりません。")
                    .foregroundStyle(.secondary)
                Text(source).font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: source) { _, _ in
            renderError = nil
            errorLine = nil
        }
    }
}

private struct MermaidWebView: NSViewRepresentable {
    let source: String
    let script: String
    let onResult: (CGFloat, String?, Int?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "diagram")
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(MermaidDiagram.hostHTML(script: script), baseURL: nil)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onResult = onResult
        context.coordinator.source = source
        context.coordinator.render(on: view)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "diagram")
        view.navigationDelegate = nil
        view.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onResult: (CGFloat, String?, Int?) -> Void
        var source = ""
        private var lastSource: String?
        private var ready = false

        init(onResult: @escaping (CGFloat, String?, Int?) -> Void) { self.onResult = onResult }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            render(on: webView)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            navigationAction.request.url?.scheme == "about" ? .allow : .cancel
        }

        func render(on view: WKWebView) {
            guard ready, lastSource != source else { return }
            lastSource = source
            let argument = String(data: try! JSONSerialization.data(withJSONObject: [source], options: [.fragmentsAllowed]),
                                  encoding: .utf8) ?? "[]"
            view.evaluateJavaScript("drawDiagram(\(argument.dropFirst().dropLast())); 0") { _, error in
                if let error { self.onResult(120, error.localizedDescription, nil) }
            }
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let result = message.body as? [String: Any] else { return }
            let height = (result["height"] as? NSNumber).map { CGFloat(truncating: $0) } ?? 120
            let error = result["error"] as? String
            let line = result["line"] as? Int
            onResult(height, error, line)
        }
    }
}
