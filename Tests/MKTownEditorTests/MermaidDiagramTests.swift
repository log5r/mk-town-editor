import WebKit
import XCTest
@testable import MKTownEditor

@MainActor
final class MermaidDiagramTests: XCTestCase {
    func testMermaidCodeBlockSelectionAndErrorPosition() {
        let diagram = MarkdownAnalysis("```mermaid\ngraph TD\nA-->B\n```").blocks[0]
        XCTAssertTrue(MermaidDiagram.isDiagram(diagram))
        let code = MarkdownAnalysis("```swift\nlet x = 1\n```").blocks[0]
        XCTAssertFalse(MermaidDiagram.isDiagram(code))
        XCTAssertEqual(MermaidDiagram.errorLine("Parse error on line 3: unexpected token", explicitLine: nil), 3)
        XCTAssertEqual(MermaidDiagram.errorLine("invalid", explicitLine: 2), 2)
    }

    func testBundledRendererCreatesSVGWithoutNetwork() throws {
        let script = try XCTUnwrap(MermaidDiagram.bundledScript)
        XCTAssertGreaterThan(script.utf8.count, 1_000_000)
        let result = expectation(description: "Mermaid rendered locally")
        let delegate = RenderDelegate(expectation: result)
        let controller = WKUserContentController()
        controller.add(delegate, name: "diagram")
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 600, height: 300), configuration: config)
        delegate.webView = webView
        webView.navigationDelegate = delegate
        webView.loadHTMLString(MermaidDiagram.hostHTML(script: script), baseURL: nil)
        wait(for: [result], timeout: 12)
        XCTAssertNil(delegate.error)
        XCTAssertGreaterThan(delegate.height, 0)
        controller.removeScriptMessageHandler(forName: "diagram")
    }

    func testBundledRendererReportsSyntaxError() throws {
        let script = try XCTUnwrap(MermaidDiagram.bundledScript)
        let result = expectation(description: "Mermaid syntax error")
        let delegate = RenderDelegate(expectation: result, source: "graph TD\nA -->")
        let controller = WKUserContentController()
        controller.add(delegate, name: "diagram")
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 600, height: 300), configuration: config)
        delegate.webView = webView
        webView.navigationDelegate = delegate
        webView.loadHTMLString(MermaidDiagram.hostHTML(script: script), baseURL: nil)
        wait(for: [result], timeout: 12)
        XCTAssertNotNil(delegate.error)
        XCTAssertEqual(MermaidDiagram.errorLine(delegate.error ?? "", explicitLine: delegate.line), 2)
        controller.removeScriptMessageHandler(forName: "diagram")
    }
}

@MainActor
private final class RenderDelegate: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let expectation: XCTestExpectation
    let source: String
    weak var webView: WKWebView?
    var error: String?
    var height = 0
    var line: Int?
    private var completed = false

    init(expectation: XCTestExpectation, source: String = "graph TD; A-->B") {
        self.expectation = expectation
        self.source = source
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let encoded = String(data: try! JSONSerialization.data(withJSONObject: [source]), encoding: .utf8)!
        webView.evaluateJavaScript("drawDiagram(\(encoded.dropFirst().dropLast())); 0") { _, error in
            if let error {
                self.error = error.localizedDescription
                self.finish()
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        let body = message.body as? [String: Any]
        error = body?["error"] as? String
        height = body?["height"] as? Int ?? 0
        line = body?["line"] as? Int
        finish()
    }

    private func finish() {
        guard !completed else { return }
        completed = true
        expectation.fulfill()
    }
}
