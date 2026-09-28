import Foundation
import XCTest

final class LocalizationCatalogTests: XCTestCase {
    func testEnglishCatalogCoversExtractedUIStringsAndPreservesArguments() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Sources/MKTownEditor/Localizable.xcstrings")
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(catalog["sourceLanguage"] as? String, "ja")
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        XCTAssertGreaterThanOrEqual(strings.count, 580)

        for (key, entry) in strings {
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: [String: Any]], key)
            let english = try XCTUnwrap(localizations["en"]?["stringUnit"] as? [String: String], key)
            let value = try XCTUnwrap(english["value"], key)
            let japanese = (localizations["ja"]?["stringUnit"] as? [String: String])?["value"] ?? key
            XCTAssertEqual(argumentTypes(in: japanese), argumentTypes(in: value), key)
            XCTAssertFalse(value.range(of: "[\\p{Hiragana}\\p{Katakana}\\p{Han}]",
                                       options: .regularExpression) != nil, key)
        }
    }

    private func argumentTypes(in value: String) -> [String] {
        let pattern = #"%(?:[1-9][0-9]*\$)?(?:lld|ld|d|@|f)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard let range = Range(match.range, in: value) else { return nil }
            let token = String(value[range])
            return token.hasSuffix("@") ? "@" : token.hasSuffix("f") ? "f" : "d"
        }.sorted()
    }
}
