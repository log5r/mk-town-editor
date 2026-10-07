import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

@MainActor
final class EditorScrollClippingTests: XCTestCase {
    func testSourceEditorClipsRulerAndBackgroundAtPaneBoundary() throws {
        let model = MarkdownEditorModel()
        let host = NSHostingView(rootView: MarkdownTextEditor(
            text: .constant("# Heading\n\nBody"), model: model))
        try checkClipping(in: host) { scroll in
            XCTAssertTrue(scroll.rulersVisible)
            XCTAssertTrue(scroll.verticalRulerView is MarkdownLineNumberRulerView)
            XCTAssertTrue(scroll.documentView is EditorTextView)
        }
    }

    func testPlainTextPreviewClipsBackgroundAtPaneBoundary() throws {
        // Plain paragraphs use the AppKit preview, unlike structured headings.
        let host = NSHostingView(rootView: MarkdownPreview(markdown: "Plain paragraph",
            documentContext: DocumentContext(fileURL: nil)))
        try checkClipping(in: host) { scroll in
            let text = try XCTUnwrap(scroll.documentView as? NSTextView)
            XCTAssertTrue(text.isSelectable)
            XCTAssertFalse(text.isEditable)
        }
    }

    func testStructuredPreviewRetainsEmbeddedStateAfterUpstreamInsertion() async throws {
        // Exercise the actual row subtree: recreating it reruns the embed's task.
        for sharedAnalysis in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let document = root.appendingPathComponent("main.md")
            let embedded = root.appendingPathComponent("note.md")
            var loads = 0
            func preview(_ source: String) -> MarkdownPreview {
                MarkdownPreview(markdown: source, documentContext: DocumentContext(fileURL: document),
                    snapshot: sharedAnalysis ? DocumentSnapshot(source: source) : nil,
                    usesSharedAnalysis: sharedAnalysis, workspaceDocumentURLs: [document, embedded],
                    workspaceDiskRevision: 0, loadWorkspaceOpenBuffers: { _ in
                        loads += 1
                        return [embedded: Data("Embedded body".utf8)]
                    })
            }
            let host = NSHostingView(rootView: preview("![[note]]"))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            for _ in 0..<100 where loads == 0 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(loads, 1)
            try await Task.sleep(for: .milliseconds(100))
            host.rootView = preview("Inserted paragraph\n\n![[note]]")
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(loads, 1, "An unchanged embed must retain state despite a changed parser block ID")
            window.orderOut(nil)
            window.contentView = nil
        }
    }

    func testEmbedsInSeparateWindowsRefreshOnlyChangedDependencies() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/embed-windows-\(UUID().uuidString)")
        let hostA = root.appendingPathComponent("host-a.md"), hostB = root.appendingPathComponent("host-b.md")
        let parent = root.appendingPathComponent("parent.md"), child = root.appendingPathComponent("child.md")
        let other = root.appendingPathComponent("other.md"), unrelated = root.appendingPathComponent("unrelated.md")
        let documents = [hostA, hostB, parent, child, other, unrelated]
        let index = WorkspaceDocumentIndex(documents: documents)
        let store = WorkspaceStore(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        var encodes: [URL: Int] = [:]
        var text = [parent: "Parent\n![[child]]", child: "Child", other: "Other", unrelated: "Unrelated"]
        let otherID = UUID()
        for url in documents {
            store.registerOpenBuffer(id: url == other ? otherID : UUID(), url: url, encodedData: {
                encodes[url, default: 0] += 1
                return Data((text[url] ?? "Host").utf8)
            }, updateText: { _ in })
        }
        var requestsA: [Set<URL>] = [], requestsB: [Set<URL>] = []
        func preview(_ isA: Bool) -> MarkdownPreview {
            MarkdownPreview(markdown: isA ? "![[parent]]" : "![[other]]",
                documentContext: DocumentContext(fileURL: isA ? hostA : hostB),
                workspaceDocumentURLs: documents, workspaceContentRevisions: store.openBufferRevisions,
                workspaceDiskRevision: 0, workspaceIndex: index, loadWorkspaceOpenBuffers: { requested in
                    if isA { requestsA.append(requested) } else { requestsB.append(requested) }
                    return try store.openBufferSnapshots(including: requested)
                })
        }
        let first = NSHostingView(rootView: preview(true)), second = NSHostingView(rootView: preview(false))
        let windows = [first, second].map { host in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host; host.layoutSubtreeIfNeeded()
            return window
        }
        defer { for window in windows { window.orderOut(nil); window.contentView = nil } }
        func updateHosts() {
            first.rootView = preview(true); second.rootView = preview(false)
            first.layoutSubtreeIfNeeded(); second.layoutSubtreeIfNeeded()
        }
        for _ in 0..<100 where encodes[child] == nil || encodes[other] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(encodes[parent], 1)
        XCTAssertEqual(encodes[child], 1)
        XCTAssertEqual(encodes[other], 1)
        XCTAssertNil(encodes[hostA]); XCTAssertNil(encodes[hostB]); XCTAssertNil(encodes[unrelated])
        let initialA = requestsA.count, initialB = requestsB.count
        for _ in 0..<20 { store.openBufferDidChange(for: unrelated); updateHosts() }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(requestsA.count, initialA); XCTAssertEqual(requestsB.count, initialB)
        XCTAssertNil(encodes[unrelated])

        text[child] = "Edited child"
        store.openBufferDidChange(for: child); updateHosts()
        for _ in 0..<100 where encodes[child] == 1 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(encodes[child], 2)
        XCTAssertEqual(requestsB.count, initialB, "Other window must not refresh for an unrelated nested dependency")

        text[parent] = "Parent\n![[other]]"
        store.openBufferDidChange(for: parent); updateHosts()
        for _ in 0..<100 where encodes[other] == 1 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        let changedA = requestsA.count
        store.openBufferDidChange(for: child); updateHosts()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(requestsA.count, changedA, "Removed dependencies must stop triggering refreshes")

        let previousOther = encodes[other]!
        text[other] = "Updated shared dependency"
        store.openBufferDidChange(for: other); updateHosts()
        for _ in 0..<100 where encodes[other] != previousOther + 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(encodes[other], previousOther + 2, "Both dependent windows must refresh")
        let beforeCloseA = requestsA.count, beforeCloseB = requestsB.count
        store.unregisterOpenBuffer(id: otherID, url: other); updateHosts()
        for _ in 0..<100 where requestsA.count == beforeCloseA || requestsB.count == beforeCloseB {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(requestsA.count, beforeCloseA)
        XCTAssertGreaterThan(requestsB.count, beforeCloseB)
        XCTAssertNil(encodes[unrelated])
    }

    private func checkClipping<V: View>(
        in host: NSHostingView<V>, inspect: (NSScrollView) throws -> Void
    ) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        for size in [NSSize(width: 600, height: 400), NSSize(width: 320, height: 240)] {
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(findTextScrollView(in: host))
            XCTAssertTrue(scroll.clipsToBounds,
                          "Unclipped AppKit drawing leaks the ruler/background into the titlebar.")
            try inspect(scroll)
        }
    }

    private func findTextScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView is NSTextView { return scroll }
        return view.subviews.lazy.compactMap { self.findTextScrollView(in: $0) }.first
    }
}
