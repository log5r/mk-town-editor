# ローカライズの方針と検査

## 文字列カタログが更新される条件

`Sources/MKTownEditor/Localizable.xcstrings` の元の言語は日本語で、英語訳を持つ。Xcodeのビルド（`SWIFT_EMIT_LOC_STRINGS = YES`）はソースから文字列を抽出してカタログに追加するが、`swift build` と `swift test` はカタログを更新しない。SwiftPMだけで開発すると、新しい文字列がカタログに入らないまま英語環境で日本語が表示される。

`LocalizationCatalogTests` は次の3点を検査する。

- `testEnglishCatalogCoversExtractedUIStringsAndPreservesArguments`: カタログのすべてのキーに英語訳があり、書式引数の型と数が日本語と一致する。
- `testLocalizedLiteralsInSourcesHaveCatalogEntries`: `String(localized:)`、`Text`、`Button`、`.help` などに渡した日本語の文字列リテラルが、カタログのキーにある。補間 `\(…)` は `%@`・`%lld` などの書式指定子に対応させて照合する。リテラル中の `%` は `%%` として照合する。
- `testAppKitStringsAreLocalized`: `NSAlert.addButton(withTitle:)`、`NSMenuItem(title:)`、`setAccessibilityLabel(_:)` などAppKitに日本語のリテラルを直接渡していない。AppKitはカタログを参照しないため、`String(localized:)` を通す。

失敗したテストは、不足する文字列をファイル名・行番号つきで標準出力に列挙する（XCTestは長い失敗メッセージを省略するため）。

## 訳されない書き方

- `Text("…" + 文字列)` は `String` を受け取る初期化子になり、カタログを参照しない。文全体を1つの `String(localized:)` にする。
- 永続化する列挙型の raw value に表示名を使わない。`SidebarTab` と `EditorSplitOrientation` は英語の識別子を保存し、表示名は `title` で返す。以前の版が保存した日本語の値は `init?(storedValue:)` と `EditorSplitOrientation.init(from:)` で読み替える。

## HTML書き出し

脚注・参考文献・目次の見出しや「本文に戻る」は、アプリの表示言語で出力する。`<html lang>` はフロントマターの `lang:`（言語タグとして正しい場合）を優先し、なければアプリが使っているローカライズ（`Bundle.main.preferredLocalizations`）にする。フロントマターで `lang: en` を指定しても、見出しはアプリの表示言語のまま。
