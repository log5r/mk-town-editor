import CoreText
import XCTest
#if canImport(MKTownMobileCore)
@testable import MKTownMobileCore
#else
@testable import MKTownEditorMobile
#endif

/// iPhone版のエディタのフォントの選択肢（Issue #103）。docs/editor-font-selection.md
final class MobileEditorFontTests: XCTestCase {
    func testDefaultIsTheSystemMonospacedFontUsedBefore() {
        XCTAssertEqual(MobileEditorFont.default, .monospacedSystem)
        XCTAssertEqual(MobileEditorFont.default.face, .system(.monospaced))
        XCTAssertNil(MobileEditorFont.default.japaneseFallback)
    }

    func testStoredValuesRoundTripAndUnknownValuesReadAsTheDefault() {
        for font in MobileEditorFont.allCases {
            XCTAssertEqual(MobileEditorFont(storedValue: font.rawValue), font)
        }
        XCTAssertEqual(MobileEditorFont(storedValue: nil), .default)
        XCTAssertEqual(MobileEditorFont(storedValue: "fontAddedInALaterVersion"), .default)
        XCTAssertEqual(MobileEditorFont(storedValue: ""), .default)
    }

    /// 保存値は raw value なので、選択肢の raw value を変えると保存した選択が既定に戻る。
    func testStoredRawValuesStayStable() {
        XCTAssertEqual(MobileEditorFont.allCases.map(\.rawValue), [
            "monospacedSystem", "menlo", "courierNew", "system", "hiraginoSans",
            "serifSystem", "hiraginoMincho", "georgia", "roundedSystem", "hiraginoMaruGothic",
        ])
        XCTAssertEqual(MobileEditorFont.storageKey, "mobile.editorFont")
    }

    func testEveryCategoryOffersAJapaneseCapableFontAndEveryFontHasOneCategory() {
        var listed: [MobileEditorFont] = []
        for category in MobileEditorFont.Category.allCases {
            let options = MobileEditorFont.options(in: category)
            XCTAssertFalse(options.isEmpty, "\(category)")
            listed += options
            // 等幅以外の分類には、日本語の字形をその分類で表示できる選択肢がある。
            if category != .monospaced {
                XCTAssertTrue(options.contains { font in
                    if case .named(let name) = font.face, name.hasPrefix("Hira") { return true }
                    return font.japaneseFallback != nil
                }, "\(category)")
            }
        }
        XCTAssertEqual(listed.sorted { $0.rawValue < $1.rawValue },
                       MobileEditorFont.allCases.sorted { $0.rawValue < $1.rawValue })
    }

    func testJapaneseFallbackMatchesTheCategory() {
        XCTAssertEqual(MobileEditorFont.serifSystem.japaneseFallback, "HiraMinProN-W3")
        XCTAssertEqual(MobileEditorFont.georgia.japaneseFallback, "HiraMinProN-W3")
        XCTAssertEqual(MobileEditorFont.roundedSystem.japaneseFallback, "HiraMaruProN-W4")
        for font in MobileEditorFont.allCases where font.category == .monospaced || font.category == .gothic {
            XCTAssertNil(font.japaneseFallback, "\(font) uses the system's Japanese fallback")
        }
    }

    /// 名前で取り出すフォントがこの環境に入っていることを確かめる。iOSのシミュレータでは
    /// iOS同梱のフォントを、macOSの `swift test` では同名のmacOSのフォントを調べる。
    func testNamedFontsAndJapaneseFallbacksAreInstalled() {
        var names = Set<String>()
        for font in MobileEditorFont.allCases {
            if case .named(let name) = font.face { names.insert(name) }
            if let fallback = font.japaneseFallback { names.insert(fallback) }
        }
        for name in names.sorted() {
            let font = CTFontCreateWithName(name as CFString, 13, nil)
            XCTAssertEqual(CTFontCopyPostScriptName(font) as String, name, "\(name) is not installed")
        }
    }
}
