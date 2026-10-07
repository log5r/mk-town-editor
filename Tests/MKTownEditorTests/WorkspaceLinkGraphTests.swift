import Foundation
import XCTest
@testable import MKTownEditor

final class WorkspaceLinkGraphTests: XCTestCase {
    func testBuildsEdgesFromMarkdownWikiAndEmbedsUsingUnsavedBuffer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let a = root.appendingPathComponent("a.md")
        let b = root.appendingPathComponent("b.md")
        let c = root.appendingPathComponent("c.md")
        for url in [a, b, c] {
            try "body".write(to: url, atomically: true, encoding: .utf8)
        }
        let open = "[B](b.md) [[b]]\n![[c]]\n```\n[[c]]\n```\n![image](c.md)"
        let index = WorkspaceFileIndex.scan(root: root)
        let graph = try WorkspaceLinkGraph.scan(root: root, nodes: index.nodes,
            openBuffers: [a: Data(open.utf8)])
        XCTAssertEqual(Set(graph.edges), Set([
            WorkspaceGraphEdge(source: a, target: b),
            WorkspaceGraphEdge(source: a, target: c)
        ]))
        XCTAssertEqual(graph.view(around: b, showsAll: false).nodes, [b, a])
        XCTAssertEqual(graph.skippedDocuments, 0)
    }

    func testLimitsWholeGraphAndKeepsFocusInNeighborhood() {
        let root = URL(fileURLWithPath: "/tmp/graph-tests")
        let urls = (0..<8).map { root.appendingPathComponent("\($0).md") }
        let edges = (1..<8).map { WorkspaceGraphEdge(source: urls[0], target: urls[$0]) }
        let graph = WorkspaceLinkGraph(nodes: urls, edges: edges,
            skippedDocuments: 0, isTruncated: false)
        let nearby = graph.view(around: urls[0], showsAll: false, limit: 3)
        XCTAssertEqual(nearby.nodes.first, urls[0])
        XCTAssertEqual(nearby.nodes.count, 3)
        XCTAssertTrue(nearby.isLimited)
        let all = graph.view(around: urls[0], showsAll: true, limit: 3)
        XCTAssertEqual(all.nodes.count, 3)
        XCTAssertTrue(all.isLimited)
        XCTAssertEqual(all.limit, 3, "The displayed limit follows the requested limit")
        XCTAssertEqual(graph.view(around: nil, showsAll: true).limit, WorkspaceLinkGraph.defaultDisplayLimit)
    }
}
