# 設定の保存値と以前の版との互換

macOS版の設定（`EditorSettingsStore`）は、`UserDefaults` の `MKTownEditor.editorSettings.v1` にJSON1つ（`StoredEditorSettings`）として保存し、起動時に `try? JSONDecoder().decode(...)` で丸ごと読む。1項目でもデコードに失敗すると設定全体が既定値になり、その状態で何か設定を変えると、ショートカット、スニペット、フォルダごとの設定などが既定値で上書きされる。

新しい版で保存した設定を以前の版で開くことは、版を戻したときや、新旧の版を並べて使ったときに起きる。そのため、保存値は「新しい版が書いたJSONを以前の版のデコードロジックで読んでも失敗しない」形にする。

## 不具合: 「紺色」を選ぶと以前の版で全設定を失う（Issue #107、2026-11-22修正）

- **症状**：編集画面の配色で「紺色」を選ぶと、PR #98 より前の版で起動したときに全設定が既定値になる。
- **原因**：PR #98 で `PreviewTheme.navy` を追加し、`encode(to:)` が `"navy"` と書くようにした。以前の版の `PreviewTheme.init(from:)` は知らないテーマ名で `DecodingError` を投げ、`editorTheme` の1項目の失敗で `StoredEditorSettings` 全体のデコードが失敗した。
- **対処**：「紺色」を `"system"` として保存する（`PreviewTheme.encode(to:)`）。読み込み後、`AppEditorSettings.restoreNavyEditorThemes()` が編集画面の項目（`editorTheme`、`editorLightTheme`、`editorDarkTheme`）の `.system` を `.navy` に戻す。あわせて、知らないテーマ名と読めない色の定義を投げずに `.system` として読むようにした（`PreviewTheme.init(from:)`）。

### 「紺色」を `"system"` で保存してよい理由

`"system"` と `"navy"` の関係を `git log` で確かめた。

| 版 | 編集画面の `"system"` | 編集画面の `"navy"` |
| --- | --- | --- |
| `102130e`（PR #96）〜PR #98 の前 | 紺の背景（#283264）の配色。既定 | 読めない（全設定を失う） |
| PR #98（`b9bdc90`）以降 | 「紺色」として読む（`PreviewTheme.editorColors`） | 「紺色」 |

PR #98 は編集画面の紺の「システム」を「紺色」に改名した変更で、改名後も編集画面の `"system"` は「紺色」として読む。編集画面には「システム」の選択肢がないため、編集画面の項目では `"system"` と `"navy"` が同じ意味になる。「紺色」を `"system"` で書いても、この版では選んだ値が失われず、以前の版では当時の紺の配色で表示される。

プレビューの `"system"` は外観に追従する「システム」で、「紺色」とは意味が違う。ただし「紺色」はプレビューの選択肢にないため（`ThemeTarget.basicThemes`）、プレビューの項目に `.navy` が入ることはない。仮に入っていた場合は、保存し直すと「システム」になる。

### 検討した別案

- **以前の版が読める値を `editorTheme` に残し、別の項目に `"navy"` を書く**（エディタのフォントの `fontFamily` と同じ方式。[エディタのフォントの選択](editor-font-selection.md)）。フォントでは以前の版の値と新しい値が別物だったため2項目が必要だった。テーマでは編集画面の `"system"` がすでに「紺色」を指すため、項目を増やしても得るものがなく、2つの値が食い違ったときの扱いが増えるだけなので採らなかった。
- **知らないテーマ名を既定として読むだけにする**。この版以降の読み込みには効くが、すでに出回っているPR #98 より前の版の挙動は変えられないため、それだけでは直らない。今後のテーマの追加に備えて、上の対処と合わせて入れた。

### 保存データを書き換えない

`restoreNavyEditorThemes()` で `.navy` に戻した値は、書き出すと元と同じ `"system"` になる。`EditorSettingsStore.save()` は前回と同じバイト列なら書き込まないため、読み込んだだけで保存データが変わることはない。PR #98〜Issue #107 の修正前の版が `"navy"` と書いた保存データもそのまま「紺色」として読み、次に設定を保存したときに `"system"` に置き換わる。

## 値を追加するときの決まり

- 以前の版が読む項目の enum に、ケースや raw value を足したり変えたりしない。新しい値は、以前の版が知らない別の項目（キー）に書き、以前の版の項目には以前の版が読める値を残す。以前の版は知らないキーを無視する。
- 新しい版の `init(from:)` は、知らない値で投げずに既定に落とす。今後の版で値が増えたときに、この版が全設定を失わないようにする。
- テストでは、以前の版の構造体とデコード実装をテスト内に再現し、新しい版が書いたJSONを読めることと、テーマ以外の設定が残ることを確かめる（`SettingsBackwardCompatibilityTests`）。

## ほかの設定項目の調査（2026-11-22）

`AppEditorSettings`、`FolderEditorSettings`、`DocumentDisplayState` が保存する enum について、導入時からケースが増えたかを `git log -L` で調べた。

- 導入時からケースが変わっていない：`EditorMode`、`ImageImportMode`、`EditorFontChoice`、`WordCountMode`、`ReadingLanguage`、`MarkdownLintRule`、`ProofingLanguage`、`AttachmentDirectory`、`MarkdownDialect`、`DocumentOpeningMode`。
- `PreviewThemePreset`（`"github-light"`、`"nord"` など）は PR #89（`147a7cd`、2026-11-21）で `PreviewTheme` に加わった。それより前の版は `"system"`、`"paper"` とカスタムテーマしか読めず、標準装備のテーマを選んだ設定で全設定を失う。対象は2026-11-21より前の版で、標準装備のテーマを以前の版が読める値に置き換えると選択が失われるため、修正していない。
- `EditorSplitOrientation` は `0ad4b26`（2026-09-29）で raw value を日本語（`"左右"`、`"上下"`）として導入し、`2a71ce2`（2026-10-08）で英語に変えた。この間の版は英語の値を読めない。新しい版は日本語の値も読む（`init?(storedValue:)`）。書類ごとの表示状態の値で、2026-10-08より前の版に限られるため、修正していない。
- `MarkdownLintRule` は `Set<MarkdownLintRule>`（`disabledLintRules`）として保存する。今後ルールを足し、利用者がそのルールを無効にすると、ルールを知らない版で全設定を失う。ルールを足すときは、上の決まりに従って別の項目に保存するか、知らない値を読み飛ばす実装を先に出す。

## 検証

`SettingsBackwardCompatibilityTests`（`Tests/MKTownEditorTests/SettingsBackwardCompatibilityTests.swift`）が次を確かめる。

- 「紺色」を編集画面の各項目に選んだ設定を、PR #98 より前の版の形（`EarlierStoredSettings`、知らないテーマ名で投げる `EarlierPreviewTheme`）でデコードでき、文字サイズ、ショートカット、スニペット、フォルダごとの設定が残ること。保存したJSONに `"navy"` がないこと
- 既定の設定も以前の版の形で読めること
- 「紺色」が保存・読み込みで「紺色」のまま戻ること（`editorTheme`、`editorLightTheme`、`editorDarkTheme`）。プレビューの既定は「システム」のままであること
- 読み込んだ設定を同じ内容で保存しても、保存データが変わらず書き込みも起きないこと
- `"navy"` を直接書いた保存データを「紺色」として読み、ほかの設定も残ること
- 知らないテーマ名と読めない色の定義を既定（編集画面は「紺色」、プレビューは「システム」）として読み、ほかの設定が残ること
