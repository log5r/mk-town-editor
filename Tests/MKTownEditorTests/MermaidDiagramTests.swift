import WebKit
import XCTest
@testable import MKTownEditor

@MainActor
final class MermaidDiagramTests: XCTestCase {
    private static let controlledScript = """
    globalThis.mermaid = {
      initialize() {},
      async render(id, source) {
        if (source.startsWith('blocked')) return await new Promise(() => {});
        return {svg: '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><rect width="100" height="100" fill="blue"/></svg>'};
      }
    };
    """

    private func waitForRequests(_ renderer: MermaidRenderService, active: Int, pending: Int) async throws {
        for _ in 0..<200 {
            if renderer.activeRequestCount == active, renderer.pendingRequestCount == pending { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected active=\(active), pending=\(pending); got \(renderer.activeRequestCount), \(renderer.pendingRequestCount)")
    }

    func testCancellingAbandonedRequestsRemovesBacklogAndLetsLatestSourceRender() async throws {
        let renderer = MermaidRenderService(script: Self.controlledScript)
        let activeCancelled = expectation(description: "Active abandoned render cancelled immediately")
        let active = Task {
            do { _ = try await renderer.render("blocked-active"); XCTFail("Expected cancellation") }
            catch is CancellationError { activeCancelled.fulfill() }
            catch { XCTFail("Unexpected error: \(error)") }
        }
        try await waitForRequests(renderer, active: 1, pending: 0)
        let pendingCancelled = expectation(description: "Every queued abandoned source cancelled immediately")
        pendingCancelled.expectedFulfillmentCount = 20
        let abandoned = (0..<20).map { index in
            Task {
                do { _ = try await renderer.render("blocked-\(index)"); XCTFail("Expected cancellation") }
                catch is CancellationError { pendingCancelled.fulfill() }
                catch { XCTFail("Unexpected error: \(error)") }
            }
        }
        try await waitForRequests(renderer, active: 1, pending: 20)
        abandoned.forEach { $0.cancel() }
        await fulfillment(of: [pendingCancelled], timeout: 2)
        XCTAssertEqual(renderer.pendingRequestCount, 0)
        XCTAssertEqual(renderer.renderCount, 1)
        active.cancel()
        await fulfillment(of: [activeCancelled], timeout: 2)
        XCTAssertEqual(renderer.activeRequestCount, 0)
        let latestRendered = expectation(description: "Latest source renders without waiting for obsolete timeouts")
        let latest = Task {
            do {
                let image = try await renderer.render("latest")
                XCTAssertGreaterThan(image.size.height, 0)
                latestRendered.fulfill()
            } catch { XCTFail("Latest render failed: \(error)") }
        }
        await fulfillment(of: [latestRendered], timeout: 3)
        latest.cancel()
        XCTAssertEqual(renderer.renderCount, 2)
        XCTAssertEqual(renderer.webViewCreationCount, 1)
        XCTAssertEqual(renderer.pendingRequestCount, 0)
        XCTAssertEqual(renderer.activeRequestCount, 0)
    }

    func testCancellingOneCoalescedRequestKeepsOtherWaiterAndCancellingLastStopsRender() async throws {
        let renderer = MermaidRenderService(script: Self.controlledScript)
        let firstCancelled = expectation(description: "First waiter cancelled")
        let first = Task {
            do { _ = try await renderer.render("blocked-shared"); XCTFail("Expected cancellation") }
            catch is CancellationError { firstCancelled.fulfill() }
            catch { XCTFail("Unexpected error: \(error)") }
        }
        try await waitForRequests(renderer, active: 1, pending: 0)
        let secondCancelled = expectation(description: "Last waiter cancelled")
        let second = Task {
            do { _ = try await renderer.render("blocked-shared"); XCTFail("Expected cancellation") }
            catch is CancellationError { secondCancelled.fulfill() }
            catch { XCTFail("Unexpected error: \(error)") }
        }
        try await waitForRequests(renderer, active: 1, pending: 1)
        first.cancel()
        await fulfillment(of: [firstCancelled], timeout: 2)
        XCTAssertEqual(renderer.activeRequestCount, 1)
        XCTAssertEqual(renderer.pendingRequestCount, 0)
        XCTAssertEqual(renderer.renderCount, 1)
        second.cancel()
        await fulfillment(of: [secondCancelled], timeout: 2)
        XCTAssertEqual(renderer.activeRequestCount, 0)
        XCTAssertEqual(renderer.pendingRequestCount, 0)
    }

    func testAlreadyCancelledRequestDoesNotStartRenderer() async {
        let renderer = MermaidRenderService(script: Self.controlledScript)
        let cancelled = Task { try await renderer.render("unused") }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(renderer.webViewCreationCount, 0)
        XCTAssertEqual(renderer.pendingRequestCount, 0)
    }

    func testSharedRendererKeepsEntireTallDiagram() async throws {
        let source = "graph TD\n" + (0..<65).map { "Node\($0)-->Node\($0 + 1)" }.joined(separator: "\n")
        let image = try await MermaidRenderService.shared.render(source)
        XCTAssertGreaterThan(image.size.height / image.size.width, 3_000.0 / 900.0)
    }

    func testSharedRendererCoalescesRequestsAndCachesBitmaps() async throws {
        let renderer = MermaidRenderService.shared
        let source = "graph TD; UniqueCacheTestA-->UniqueCacheTestB"
        let before = renderer.renderCount
        async let first = renderer.render(source)
        async let second = renderer.render(source)
        let images = try await (first, second)
        XCTAssertGreaterThan(images.0.size.height, 0)
        XCTAssertTrue(images.0 === images.1)
        let cached = try await renderer.render(source)
        XCTAssertTrue(cached === images.0)
        XCTAssertEqual(renderer.renderCount, before + 1)
        XCTAssertEqual(renderer.webViewCreationCount, 1)
    }

    func testDiagramIdentitySurvivesUpstreamParagraphInsertionAndDistinguishesDuplicates() {
        let code = "```mermaid\ngraph TD; A-->B\n```"
        let before = DocumentSnapshot(source: code + "\n\n" + code)
        let after = DocumentSnapshot(source: "paragraph\n\n" + code + "\n\n" + code)
        let idsBefore = before.analysis.blocks.filter(MermaidDiagram.isDiagram).map { before.blockPresentationIDs[$0.id] }
        let idsAfter = after.analysis.blocks.filter(MermaidDiagram.isDiagram).map { after.blockPresentationIDs[$0.id] }
        XCTAssertEqual(idsBefore, idsAfter)
        XCTAssertNotEqual(idsBefore[0], idsBefore[1])
    }

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
