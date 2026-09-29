import Foundation
import XCTest
@testable import MKTownEditor

final class WorkspaceDailyNoteTests: XCTestCase {
    func testDateNameUsesSelectedCalendarDayAcrossTimeZones() {
        let instant = Date(timeIntervalSince1970: 1_766_275_200 + 23 * 3600)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        XCTAssertNotEqual(WorkspaceDailyNote.dateName(for: instant, calendar: utc),
            WorkspaceDailyNote.dateName(for: instant, calendar: tokyo))
    }

    func testCreatesFromTemplateAndReopensSameDocumentWithoutOverwriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 29))!
        let created = try WorkspaceDailyNote.openOrCreate(for: date, root: root,
            template: .journal, calendar: calendar)
        XCTAssertEqual(created.lastPathComponent, "2026-09-29.md")
        XCTAssertEqual(created.deletingLastPathComponent().lastPathComponent, "Daily")
        XCTAssertTrue(try String(contentsOf: created, encoding: .utf8).contains("2026-09-29"))
        try "changed".write(to: created, atomically: true, encoding: .utf8)
        let reopened = try WorkspaceDailyNote.openOrCreate(for: date, root: root,
            template: .meeting, calendar: calendar)
        XCTAssertEqual(reopened, created)
        XCTAssertEqual(try String(contentsOf: reopened, encoding: .utf8), "changed")
    }

    func testRejectsSymlinkedDailyFolderOutsideWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Daily"),
            withDestinationURL: outside)
        XCTAssertThrowsError(try WorkspaceDailyNote.openOrCreate(for: Date(),
            root: root, template: .blank))
    }
}
