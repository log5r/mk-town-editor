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

        let issues = validationIssues(in: strings)
        XCTAssertTrue(issues.isEmpty, issues.joined(separator: "\n"))
    }

    func testReportsAllMissingTranslationsInStableOrder() {
        let strings: [String: [String: Any]] = [
            "選択テキストがありません。": [:],
            "競合版あり": ["localizations": ["ja": ["stringUnit": ["value": "競合版あり"]]]],
            "Gitの読み取りが時間切れになりました。": ["localizations": ["en": [:]]]
        ]

        XCTAssertEqual(validationIssues(in: strings), strings.keys.sorted().map {
            "Missing English translation: \($0)"
        })
    }

    func testOnlyEmptySourceKeyIsExemptFromTranslation() {
        XCTAssertEqual(validationIssues(in: ["": [:]]), [])
        XCTAssertEqual(validationIssues(in: [" ": [:]]), ["Missing English translation:  "])
        XCTAssertEqual(validationIssues(in: ["コピー": entry(english: "")]),
                       ["Empty English translation: コピー"])
        XCTAssertEqual(validationIssues(in: [" ": entry(english: " ")]), [])
    }

    func testRejectsUntranslatedStateAndJapaneseInEnglishValue() {
        XCTAssertEqual(validationIssues(in: ["コピー": entry(english: "Copy", state: "new")]),
                       ["English translation is not marked translated: コピー"])
        XCTAssertEqual(validationIssues(in: ["コピー": entry(english: "コピー")]),
                       ["Japanese text in English translation: コピー"])
    }

    func testPreservesArgumentTypesAndCountsWithPositionalTranslations() {
        let key = "公開先がHTTP %lldを返しました: %@"
        let japanese = "公開先がHTTP %1$lldを返しました: %2$@"
        XCTAssertEqual(validationIssues(in: [key: entry(
            english: "%2$@ (HTTP %1$lld)", japanese: japanese)]), [])
        XCTAssertEqual(validationIssues(in: [key: entry(
            english: "HTTP %1$lld: %2$lld", japanese: japanese)]),
                       ["Format arguments differ: \(key)"])
        XCTAssertEqual(validationIssues(in: [key: entry(
            english: "HTTP %1$lld", japanese: japanese)]),
                       ["Format arguments differ: \(key)"])
    }

    private func entry(english: String, state: String = "translated",
                       japanese: String? = nil) -> [String: Any] {
        var localizations = ["en": ["stringUnit": ["state": state, "value": english]]]
        if let japanese {
            localizations["ja"] = ["stringUnit": ["state": "translated", "value": japanese]]
        }
        return ["localizations": localizations]
    }

    private func validationIssues(in strings: [String: [String: Any]]) -> [String] {
        var issues: [String] = []
        // Xcode extracts empty UI strings; they have no content to translate.
        for key in strings.keys.sorted() where !key.isEmpty {
            let localizations = strings[key]?["localizations"] as? [String: [String: Any]]
            guard let english = localizations?["en"]?["stringUnit"] as? [String: String],
                  let value = english["value"] else {
                issues.append("Missing English translation: \(key)")
                continue
            }
            if value.isEmpty { issues.append("Empty English translation: \(key)") }
            if english["state"] != "translated" {
                issues.append("English translation is not marked translated: \(key)")
            }
            let japanese = (localizations?["ja"]?["stringUnit"] as? [String: String])?["value"] ?? key
            if argumentTypes(in: japanese) != argumentTypes(in: value) {
                issues.append("Format arguments differ: \(key)")
            }
            if value.range(of: "[\\p{Hiragana}\\p{Katakana}\\p{Han}]", options: .regularExpression) != nil {
                issues.append("Japanese text in English translation: \(key)")
            }
        }
        return issues
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
