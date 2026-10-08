import SwiftUI
import XCTest
@testable import MKTownEditor

@MainActor
final class EditorFormattingToolbarTests: XCTestCase {
    func testEveryFormattingCommandBuildsAsCustomizableToolbarContentInOrder() {
        var commands: [EditorCommand] = []
        let toolbar = EditorFormattingToolbar { command in
            let _ = commands.append(command)
            Text(command.title)
        }

        // Requiring this protocol catches a regression to ForEach-based items.
        func acceptCustomizableContent(_ content: some CustomizableToolbarContent) {}
        acceptCustomizableContent(toolbar.body)
        XCTAssertEqual(commands, EditorCommand.toolbar,
                       "Explicit toolbar declarations must match the command catalogue")
    }
}
