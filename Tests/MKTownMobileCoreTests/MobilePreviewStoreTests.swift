import Combine
import XCTest
#if canImport(MKTownMobileCore)
@testable import MKTownMobileCore
#else
@testable import MKTownEditorMobile
#endif

@MainActor
final class MobilePreviewStoreTests: XCTestCase {
    func testSlowParserRunsOnceAtATimeAndCoalescesPendingSources() async {
        let first = expectation(description: "first parse started")
        let latest = expectation(description: "latest parse started")
        let obsolete = expectation(description: "obsolete pending parse never starts")
        obsolete.isInverted = true
        let probe = ParserProbe(started: ["first": first, "middle": obsolete, "latest": latest])
        let store = MobilePreviewStore(debounce: .zero) { await probe.parse($0) }
        store.update(source: "first")
        await fulfillment(of: [first], timeout: 2)

        // Let each revision pass the debounce while the first parse remains suspended.
        store.update(source: "middle")
        await fulfillment(of: [obsolete], timeout: 0.05)
        store.update(source: "latest")
        try? await Task.sleep(for: .milliseconds(50))
        await probe.finish("first")
        await fulfillment(of: [latest], timeout: 2)
        XCTAssertTrue(store.preview.blocks.isEmpty, "An obsolete parse must not publish")

        let published = expectation(description: "latest result published")
        let subscription = store.$preview.dropFirst().sink { _ in published.fulfill() }
        await probe.finish("latest")
        await fulfillment(of: [published], timeout: 2)
        XCTAssertEqual(store.preview.blocks.map { String($0.text.characters) }, ["latest"])
        let calls = await probe.calls
        let maximum = await probe.maximumActive
        XCTAssertEqual(calls, ["first", "latest"])
        XCTAssertEqual(maximum, 1)
        withExtendedLifetime(subscription) {}
    }

    func testDisappearanceDiscardsPendingAndRunningResults() async {
        let first = expectation(description: "first started")
        let pending = expectation(description: "cancelled pending never starts")
        pending.isInverted = true
        let probe = ParserProbe(started: ["first": first, "pending": pending])
        let store = MobilePreviewStore(debounce: .zero) { await probe.parse($0) }
        store.update(source: "first")
        await fulfillment(of: [first], timeout: 2)
        store.update(source: "pending")
        try? await Task.sleep(for: .milliseconds(50))
        store.cancel()
        await probe.finish("first")
        await fulfillment(of: [pending], timeout: 0.05)
        XCTAssertTrue(store.preview.blocks.isEmpty)
        let calls = await probe.calls
        XCTAssertEqual(calls, ["first"])
    }

    func testReappearanceWaitsForThePreviousUninterruptibleParse() async {
        let first = expectation(description: "previous appearance started")
        let resumed = expectation(description: "reappeared document started")
        let probe = ParserProbe(started: ["first": first, "resumed": resumed])
        let store = MobilePreviewStore(debounce: .zero) { await probe.parse($0) }
        store.update(source: "first")
        await fulfillment(of: [first], timeout: 2)
        store.cancel()
        store.update(source: "resumed")
        await probe.finish("first")
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertTrue(store.preview.blocks.isEmpty)
        let published = expectation(description: "resumed result published")
        let subscription = store.$preview.dropFirst().sink { _ in published.fulfill() }
        await probe.finish("resumed")
        await fulfillment(of: [published], timeout: 2)
        let maximum = await probe.maximumActive
        XCTAssertEqual(maximum, 1)
        XCTAssertEqual(store.preview.blocks.map { String($0.text.characters) }, ["resumed"])
        withExtendedLifetime(subscription) {}
    }

    func testDebounceAndRepeatedIdenticalSourcesDoNotStartExtraParses() async {
        let latest = expectation(description: "debounced latest source")
        let probe = ParserProbe(started: ["latest": latest])
        let store = MobilePreviewStore(debounce: .milliseconds(20)) { await probe.parse($0) }
        store.update(source: "first")
        store.update(source: "middle")
        store.update(source: "latest")
        await fulfillment(of: [latest], timeout: 2)
        store.update(source: "latest")
        let published = expectation(description: "one result published")
        let subscription = store.$preview.dropFirst().sink { _ in published.fulfill() }
        await probe.finish("latest")
        await fulfillment(of: [published], timeout: 2)
        store.update(source: "latest")
        let calls = await probe.calls
        XCTAssertEqual(calls, ["latest"])
        withExtendedLifetime(subscription) {}
    }
}

/// Deliberately ignores cancellation, like Foundation's synchronous Markdown parser.
private actor ParserProbe {
    private let started: [String: XCTestExpectation]
    private var continuations: [String: CheckedContinuation<MobileMarkdownPreview, Never>] = [:]
    private(set) var calls: [String] = []
    private var active = 0
    private(set) var maximumActive = 0

    init(started: [String: XCTestExpectation]) { self.started = started }

    func parse(_ source: String) async -> MobileMarkdownPreview {
        calls.append(source)
        active += 1
        maximumActive = max(maximumActive, active)
        return await withCheckedContinuation { continuation in
            continuations[source] = continuation
            started[source]?.fulfill()
        }
    }

    func finish(_ source: String) {
        guard let continuation = continuations.removeValue(forKey: source) else { return }
        active -= 1
        continuation.resume(returning: MobileMarkdownPreview(source))
    }
}
