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

    /// SwiftPM builds never sync the catalog, so a new string in the sources stays untranslated
    /// unless this finds it. Literals passed to SwiftUI and `String(localized:)` must have keys.
    func testLocalizedLiteralsInSourcesHaveCatalogEntries() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalogURL = root.appendingPathComponent("Sources/MKTownEditor/Localizable.xcstrings")
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        let keys = Array(try XCTUnwrap(catalog["strings"] as? [String: Any]).keys)
        let opener = try NSRegularExpression(pattern: ##"(?:String\(localized:\s*|LocalizedStringKey\(|\b(?:Text|Button|Label|Toggle|Picker|Section|ContentUnavailableView|TextField|SecureField|Menu|LabeledContent|GroupBox|DisclosureGroup|Stepper|Link|CommandMenu)\(|\.help\(|\.navigationTitle\(|\.accessibilityLabel\(|\.confirmationDialog\(|\.alert\()""##)
        let japanese = try NSRegularExpression(pattern: "[\\p{Hiragana}\\p{Katakana}\\p{Han}]")
        var checked = 0
        var missing: [String] = []
        for url in try swiftSources(in: root) {
            let text = try String(contentsOf: url, encoding: .utf8)
            let utf16 = Array(text.utf16)
            for match in opener.matches(in: text, range: NSRange(location: 0, length: utf16.count)) {
                guard let segments = literalSegments(in: utf16, from: NSMaxRange(match.range)) else { continue }
                let joined = segments.joined()
                guard japanese.firstMatch(in: joined, range: NSRange(location: 0, length: (joined as NSString).length)) != nil
                else { continue }
                checked += 1
                if !keys.contains(where: { key(key: $0, matches: segments) }) {
                    let line = utf16[..<match.range.location].filter { $0 == 10 }.count + 1
                    missing.append("\(url.lastPathComponent):\(line) \(segments.joined(separator: "\\(…)"))")
                }
            }
        }
        XCTAssertGreaterThan(checked, 500)
        // XCTest drops very long failure messages, so list the strings on standard output too.
        missing.forEach { print("Missing from Localizable.xcstrings: \($0)") }
        XCTAssertEqual(missing.count, 0, "See the strings listed above")
    }

    /// AppKit takes plain strings, so Japanese literals there are never looked up in the catalog.
    func testAppKitStringsAreLocalized() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pattern = try NSRegularExpression(pattern: ##"(?:addButton\(withTitle:|NSMenuItem\(title:|NSMenu\(title:|setAccessibilityLabel\(|setAccessibilityHelp\(|messageText\s*=|informativeText\s*=|toolTip\s*=|\.title\s*=|placeholderString\s*=|prompt\s*=|message\s*=|nameFieldLabel\s*=)\s*"[^"\n]*[\p{Hiragana}\p{Katakana}\p{Han}]"##)
        var found: [String] = []
        for url in try swiftSources(in: root) {
            let text = try String(contentsOf: url, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                found.append("\(url.lastPathComponent): \((text as NSString).substring(with: match.range))")
            }
        }
        XCTAssertTrue(found.isEmpty, "Wrap these in String(localized:):\n" + found.joined(separator: "\n"))
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

    private func swiftSources(in root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Sources/MKTownEditor"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The literal text around each interpolation of a one-line string literal that starts at `start`.
    private func literalSegments(in text: [UInt16], from start: Int) -> [String]? {
        let quote = UInt16(UInt8(ascii: "\"")), backslash = UInt16(UInt8(ascii: "\\"))
        let open = UInt16(UInt8(ascii: "(")), close = UInt16(UInt8(ascii: ")")), newline: UInt16 = 10
        var segments: [[UInt16]] = [[]]
        var index = start
        while index < text.count {
            let unit = text[index]
            if unit == quote {
                return segments.map { String(decoding: $0, as: UTF16.self) }
            }
            if unit == newline { return nil }
            if unit == backslash, index + 1 < text.count {
                let next = text[index + 1]
                if next == open {
                    var depth = 1
                    var inString = false
                    index += 2
                    while index < text.count, depth > 0 {
                        let inner = text[index]
                        if inString {
                            if inner == backslash { index += 2; continue }
                            if inner == quote { inString = false }
                        } else if inner == quote {
                            inString = true
                        } else if inner == open {
                            depth += 1
                        } else if inner == close {
                            depth -= 1
                        }
                        index += 1
                    }
                    segments.append([])
                    continue
                }
                switch next {
                case UInt16(UInt8(ascii: "n")): segments[segments.count - 1].append(newline)
                case UInt16(UInt8(ascii: "t")): segments[segments.count - 1].append(9)
                default: segments[segments.count - 1].append(next)
                }
                index += 2
                continue
            }
            segments[segments.count - 1].append(unit)
            index += 1
        }
        return nil
    }

    private func key(key: String, matches segments: [String]) -> Bool {
        if segments.count == 1 {
            return key == segments[0] || key == segments[0].replacingOccurrences(of: "%", with: "%%")
        }
        let parts = segments.map {
            NSRegularExpression.escapedPattern(for: $0.replacingOccurrences(of: "%", with: "%%"))
        }
        let pattern = "^" + parts.joined(separator: #"%(?:[1-9][0-9]*\$)?(?:@|lld|ld|d|f|\.[0-9]+f)"#) + "$"
        return key.range(of: pattern, options: .regularExpression) != nil
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
