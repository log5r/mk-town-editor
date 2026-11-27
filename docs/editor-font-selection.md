# エディタのフォントの選択（#103）

macOS版はエディタのフォントを標準装備の3種類（システム等幅・システム・Menlo）からしか選べなかった。iPhone版はフォントを選べず、システム等幅（SF Mono）に固定していた。この変更で、macOS版はMacにインストールされている任意のフォントファミリーを、iPhone版はiOSに同梱されている10種類のフォントを選べるようにした。プレビューのフォントは変えていない。

## macOS版

### 保存値と以前の版との互換

設定は `AppEditorSettings` をJSONにして `UserDefaults` に1つの値として保存している。`EditorSettingsStore` は値全体を1回でデコードし、失敗すると全設定を既定に戻す。

フォントファミリーを `fontChoice`（`EditorFontChoice` の raw value）に入れると、以前の版はその値を知らないため、デコードに失敗して全設定を失う。そこで保存先を2つに分けた。

| 項目 | 内容 | 以前の版の扱い |
| --- | --- | --- |
| `fontChoice` | 標準装備の選択肢（`monospacedSystem`・`system`・`menlo`）。変更前と同じ | 読む |
| `fontFamily` | インストール済みのフォントから選んだファミリー名（例: `Hiragino Sans`） | 知らない項目なので無視する |

読み書きは計算プロパティ `AppEditorSettings.editorFont`（`EditorFont`）を通す。

- `fontFamily` が空でなければ `.family(fontFamily)`、なければ `.builtIn(fontChoice ?? .monospacedSystem)` を返す。
- `.family` を書くと `fontFamily` だけを変え、`fontChoice` は直前の標準装備の選択のまま残す。以前の版に戻すと、その標準装備のフォントで表示する。
- `.builtIn` を書くと `fontChoice` を変え、`fontFamily` を消す。

`EditorFontChoice` のケースと raw value は、以前の版が読むため変えない。設定全体の互換の決まりは[設定の保存値と以前の版との互換](settings-backward-compatibility.md)にまとめている。`EditorFont` はメモリ上の型で、`Codable` にしていない。

### フォントの解決とフォールバック

`EditorFont.font(size:resolver:)` は、フォントファミリーを `EditorFontResolver.system` で取り出す。`NSFontManager.font(withFamily:traits:weight:size:)` の標準の太さ（weight 5）、斜体なしで取り出す。ファミリーに標準の太さの書体がなければ、近い太さの書体が返る。これで取り出せないファミリー（斜体だけのファミリーなど）は、`availableMembers(ofFontFamily:)` の最初の書体を使う。

ファミリーが見つからないとき（フォントを削除した、フォント管理アプリで無効にした、など）は、既定のシステム等幅にする。このとき `fontFamily` は消さない。フォントを戻すと、設定を変えなくても次にスタイルを適用したときから元のフォントで表示する。設定画面には「（ファミリー名）（見つかりません）」の項目と説明文を出す。

### 起動中のフォントの追加・削除

アプリの起動中に、選んだフォントをインストールし直したり削除したりしても、`EditorTextStyle` の値は変わらない。そのため `MarkdownTextEditor.updateNSView` は、適用済みのスタイルとの比較（`appliedTextStyle != textStyle`）で `apply(to:)` を省く。最初の実装では、開いているエディタが代替フォントのまま、または削除したフォントのまま残った（レビューで指摘）。設定画面のピッカーは `NSFont.fontSetChangedNotification` で一覧を読み直していたが、エディタは通知を受けていなかった。

現在は、エディタの `EditorTextView` が通知を受ける。

- `EditorTextStyle.apply(to:)` は、スタイルの変更前に、適用するスタイルと解決した本文フォントを `EditorTextView.prepareToApplyTextStyle(_:font:)` に記録する。フォントファミリーを使っている間だけ通知を購読し、標準装備のフォントに切り替えると購読をやめる。本文フォントは、[全角・半角の混在でベースラインが動かないための行レイアウト](editor-mixed-script-baseline.md)にも使う。
- 通知を受けると `reapplyTextStyleIfFontResolutionChanged()` でファミリーを解決し直し、記録した書体と違うときだけスタイルを適用し直す。書体が同じなら何もしないので、通知のたびに全文をレイアウトし直すことはない。
- 適用し直した後、行番号ルーラーの `refresh()` を呼び、スクロールビューのレイアウト（折り返さない表示での本文の幅の計算）をやり直させる。行番号の高さは `textView.font` から計算するので、新しい本文フォントに従う。
- エディタごとに購読するので、設定ウインドウを開いているか、分割表示か、ウインドウがいくつあるかに関係なく、開いているすべてのエディタが追従する。`EditorTextView` を作るのは `MarkdownTextEditor.makeNSView` だけで、`EditorTextStyle` を保持しているのも `MarkdownTextEditor.Coordinator` の比較用の値だけであることを検索して確認した。

iPhone版は同梱フォントだけを使い、アプリの起動中に選択肢のフォントが増減しないため、同じ処理は入れていない。

フォントのインストールと削除はテストで行えないため、ファミリー名から書体を取り出す処理を `EditorFontResolver` に分け、`EditorTextView.fontResolver` で差し替えられるようにした。

### フォントが反映される箇所

エディタのフォントの参照元は `EditorSettingsStore.textStyle(for:)` → `EditorTextStyle.apply(to:)` の1経路だけで、ここで `NSTextView.font`、段落の既定のタブ幅、入力属性を設定する。次の処理はすべてこの値から派生するため、追加の変更は要らなかった。`fontChoice` と `EditorTextStyle` を参照する箇所を検索して確認した。

- 行番号と折りたたみマーカー: `MarkdownLineNumberLayout` は `textView.font` の `defaultLineHeight(for:)` で数字の高さを決める（[行番号のY座標の揺れ](line-number-vertical-alignment.md)）。
- 日本語の後に挿入する記号のフォント: `replaceEditorCharacters(in:with:)` は入力属性のフォントを使う（[日本語の後に挿入した記号が代替フォントで細く描かれる問題](editor-fallback-font-inheritance.md)）。日本語を含まないフォントを選んでも、日本語にはこれまでどおり代替フォントが付く。
- タブ幅: 選んだフォントの空白の幅から計算する。

行番号の数字（`monospacedDigitSystemFont`）、ミニマップ、プレビュー、HTML・PDF書き出しはエディタのフォントを使わない。

### 設定画面のUI

「エディタ」→「文字」の「フォント」を、ほかの設定と同じポップアップボタン（`Picker`）のままにし、項目を3つのセクションに分けた。

1. 標準: システム等幅・システム・Menlo
2. 等幅フォント: インストール済みのファミリーのうち、書体に等幅の特性（`kCTFontMonoSpaceTrait`）があるもの
3. その他のフォント: 残りのファミリー

ファミリーは表示言語での名前（例: ヒラギノ角ゴシック）で、表示名の順に並べる。名前が `.` で始まるシステム内部用のファミリーは出さない。一覧は `CTFontCollectionCreateFromAvailableFonts` の記述子から属性だけを読んで作り、書体は作らない。「エディタ」のタブを表示したときと、`NSFont.fontSetChangedNotification` を受けたときに読み直す。ポップアップの下には、選んだフォントで英数字の見分け（0とO、1とlとI）、括弧、かな・漢字の見本を出す。

フォントパネル（`NSFontPanel`）を採らなかった理由は次のとおり。

- フォントパネルはファミリー・書体・サイズをまとめて選ぶ。文字サイズは既存のステッパーと「文字表示」メニュー、表示倍率で別に管理しており、2か所でサイズを変えられることになる。
- フォントパネルはキーウインドウのファーストレスポンダに `changeFont(_:)` を送る、選択範囲の書式を変えるための共有パネルである。設定ウインドウから開くと、書類ウインドウのテキストビューに送られないよう応答の経路を管理する必要がある。
- 設定ウインドウのほかの選択（配色、Markdown構文など）はすべてポップアップボタンで、その場で反映する。同じ操作にそろえた。

ポップアップは数百項目になるが、macOSのメニューはスクロールと、文字を入力して項目を選ぶ操作に対応している。

### 検証

`EditorFontSelectionTests` で次を確かめる。

- 以前の版が保存した `fontChoice`（3種類すべて）だけを含む設定が読め、同じフォントになる。
- フォントファミリーを選んで保存した値を、`fontFamily` を知らない以前の版の形でデコードしても失敗せず、`fontChoice` が直前の標準装備の選択のまま読める。
- 標準装備を選ぶと `fontFamily` が消える。空のファミリー名は標準装備として読む。
- 選んだファミリーが保存され、`textStyle(for:)` に届く。標準の太さ・斜体なしで取り出す。
- 見つからないファミリーはシステム等幅で表示し、設定の値は残る。
- 選んだフォントが本文・入力属性・タブ幅に入る。
- 同じエディタで、見つからなかったファミリーが解決できるようになったときと、解決できなくなったときの両方で、本文・既存の文字・入力属性・行番号の高さが新しい書体に従う。`NSScrollView` に載せた `EditorTextView` と、`NSHostingView` に載せた `MarkdownTextEditor` の両方で確かめ、後者ではその後のSwiftUIの更新で元に戻らないことも確かめる。通知の処理を外すと、この2件が失敗する。
- 解決する書体が同じ通知では適用し直さない。標準装備のフォントは通知の影響を受けない。
- インストール済みのファミリーの一覧が重複なく表示名の順に並び、Menloを等幅、Helveticaを等幅でないと判定する。設定画面の分類と、見つからないフォントの判定。

`MarkdownLineNumberRulerTests` の行番号の揺れの検査に、ヒラギノ角ゴシック・ヒラギノ明朝・Times New Roman を加えた。

## iPhone版

### 選択肢

iOSには全フォントから選ぶ標準のUI（`UIFontPickerViewController`）もある。ただし iPhone版の設定画面は項目の少ない `Form` で、ほかの設定もその場の選択肢から選ぶ。全フォントを出すと装飾用の書体が大半を占めるため、コードと日本語の文章に向くフォントを分類ごとに選んで並べた。

| 分類 | 選択肢 | 日本語の字形 |
| --- | --- | --- |
| 等幅 | システム等幅（SF Mono、既定）、Menlo、Courier New | ヒラギノ角ゴシック（iOSの既定） |
| ゴシック | システム（SF Pro）、ヒラギノ角ゴシック | ヒラギノ角ゴシック |
| 明朝・セリフ | システムセリフ（New York）、ヒラギノ明朝、Georgia | ヒラギノ明朝 |
| 丸ゴシック | システム丸ゴシック（SF Rounded）、ヒラギノ丸ゴ | ヒラギノ丸ゴ |

欧文だけのフォントで日本語を書くと、iOSはヒラギノ角ゴシックで表示する。明朝・丸ゴシックの欧文フォント（New York、Georgia、SF Rounded）では、フォント記述子のカスケードリスト（`UIFontDescriptor.AttributeName.cascadeList`）に同じ分類のヒラギノを入れ、1行の中で欧文と日本語の字形の分類をそろえた。

ヒラギノ明朝・ヒラギノ丸ゴ・Georgia などはすべてiOSに同梱されている。iOSで追加のダウンロードが必要なフォントは、取得を待つ処理が要るため入れていない。

### 保存と表示

選択は `UserDefaults` の `mobile.editorFont` に `MobileEditorFont` の raw value で保存する（`@AppStorage`）。知らない値は既定のシステム等幅として読む。既定は変更前と同じ `.monospacedSystemFont(ofSize:weight:)` で、文字の大きさはこれまでどおりDynamic Typeの本文の大きさに従う。`MobileMarkdownTextView` はフォントが変わったときだけ `UITextView.font` を設定し直す（全文の属性とレイアウトをやり直すため）。名前で取り出すフォントが読み込めない場合はシステム等幅にする。

設定画面では「エディタ」セクションの「フォント」を `.navigationLink` のピッカーにした。各選択肢はそのフォントとエディタと同じ大きさで表示する。

### 検証

- `MobileEditorFontTests`（`swift test` とiOSのテストの両方で実行）: 既定がシステム等幅、保存値の往復と未知の値、raw value の固定、分類ごとに日本語を表示できる選択肢があること、名前で取り出すフォントとカスケード先がインストールされていること。
- `MobileWorkspaceTests`（iOSシミュレータ）: 設定の既定値と保存、すべての選択肢がDynamic Typeの3段階の大きさで読み込めること、カスケードリストの内容、フォントを切り替えても同じエディタの本文と選択範囲が変わらず、切り替え後もDynamic Typeに従うこと。

## プレビューを対象外にした理由

プレビューのフォントは配色（テーマ）の一部として決まり、macOS版は `MarkdownRenderer`・`PreviewTypography`、iPhone版は SwiftUI の `Font` で組んでいる。HTML・PDF書き出しには別のフォント設定がある。Issueはエディタのフォントの選択肢についての要望で、プレビューまで広げると、配色・書き出しとの優先順位を決める必要がある。今回は対象外とした。
