# ローカライズの方針と検査

## 文字列カタログが更新される条件

`Sources/MKTownEditor/Localizable.xcstrings` の元の言語は日本語で、英語訳を持つ。Xcodeのビルド（`SWIFT_EMIT_LOC_STRINGS = YES`）はソースから文字列を抽出してカタログに追加するが、`swift build` と `swift test` はカタログを更新しない。SwiftPMだけで開発すると、新しい文字列がカタログに入らないまま英語環境で日本語が表示される。

`LocalizationCatalogTests` は次の3点を検査する。

- `testEnglishCatalogCoversExtractedUIStringsAndPreservesArguments`: カタログのすべてのキーに英語訳があり、書式引数の型と数が日本語と一致する。
- `testLocalizedLiteralsInSourcesHaveCatalogEntries`: `String(localized:)`、`Text`、`Button`、`.help` などに渡した日本語の文字列リテラルが、カタログのキーにある。補間 `\(…)` は `%@`・`%lld` などの書式指定子に対応させて照合する。リテラル中の `%` は `%%` として照合する。
- `testAppKitStringsAreLocalized`: `NSAlert.addButton(withTitle:)`、`NSMenuItem(title:)`、`setAccessibilityLabel(_:)` などAppKitに日本語のリテラルを直接渡していない。AppKitはカタログを参照しないため、`String(localized:)` を通す。

失敗したテストは、不足する文字列をファイル名・行番号つきで標準出力に列挙する（XCTestは長い失敗メッセージを省略するため）。

## iOS版の文字列カタログと `stale` の誤判定

`Sources/MKTownMobile/Localizable.xcstrings` も、Xcode GUIのビルド直後に走る `Sync Localizations` で更新される。カタログを持つターゲットには `SWIFT_EMIT_LOC_STRINGS = YES` が必要である。`NO` のままだと、次のように使用中の文字列まで `"extractionState" : "stale"` になる。

1. コンパイラが `-emit-localized-strings` なしで動き、同期に使える抽出結果を出力しない。
2. 同期はXcode内部の構文解析の結果だけを使う。`MKTownEditorMobile` で確認したときに拾えたのは `Text("…")` だけで、`Button`、`Toggle`、`.alert`、`.navigationTitle`、`.accessibilityLabel`、`String(localized:)` は拾えなかった。
3. 拾えなかったキーを、コードから消えたものとして `stale` にする。同時にキーを並べ替えて保存するので、diffが大きくなる。

`xcodebuild`、`swift build`、`swift test` は同期を実行しない。そのため、差分はXcode GUIでビルドしたときだけ現れる。

### 調べ方

同期のログと抽出結果はDerivedDataに残る。

- `Logs/Localization/*.xcactivitylog`: `Sync Localizations` の実行記録。`gunzip -c` で展開すると、同期したターゲットと時刻が分かる。
- `Localization/Strings/<ターゲット>/Parser/*.stringsdata`: 構文解析の抽出結果（JSON）。
- `Localization/Strings/<ターゲット>/Compiler/`: コンパイラの抽出結果。

カタログの全キーから抽出結果のキーを除いた集合が `stale` と一致すれば、抽出漏れが原因である。設定の効果は、`xcodebuild ... SWIFT_EMIT_LOC_STRINGS=YES build` で出力された `.stringsdata` のキーをカタログと比べて確認できる。リポジトリの設定を変えずに実行でき、このコマンドではカタログも書き換わらない。

### 検査

`Tools/test_mobile_project.py` は、文字列カタログを持つターゲットのすべての構成で `SWIFT_EMIT_LOC_STRINGS = YES` であること、iOS版のカタログに `stale` が残っていないことを検査する。本当に使わなくなった文字列はカタログから削除する。macOS版のカタログにはコードから消えた文字列が `stale` のまま3件あるため、`stale` の検査はiOS版だけを対象にしている。

## 訳されない書き方

- `Text("…" + 文字列)` は `String` を受け取る初期化子になり、カタログを参照しない。文全体を1つの `String(localized:)` にする。
- 永続化する列挙型の raw value に表示名を使わない。`SidebarTab` と `EditorSplitOrientation` は英語の識別子を保存し、表示名は `title` で返す。以前の版が保存した日本語の値は `init?(storedValue:)` と `EditorSplitOrientation.init(from:)` で読み替える。

## HTML書き出し

脚注・参考文献・目次の見出しや「本文に戻る」は、アプリの表示言語で出力する。`<html lang>` は次の順に決める。

1. フロントマターの `lang:`（言語タグとして正しい場合）
2. 本文（コードブロックを除く先頭4,000文字）から `NLLanguageRecognizer` で判定した言語
3. 判定できないほど短い文書では、アプリが使っているローカライズ（`Bundle.main.preferredLocalizations`）

`lang` は本文の言語を表すため、アプリの表示言語より本文を優先する。フロントマターで `lang: en` を指定しても、見出しはアプリの表示言語のまま。
