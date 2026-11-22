# カスタムテーマの作り方

プレビューの配色は、JSONファイルを1つ書けば追加できる。この文書では、ファイルの書き方、色の決め方、読み込めないときの直し方を説明する。標準装備の配色と選び方は[プレビューの配色](preview-themes.md)を参照。

テーマが変えるのはmacOS版のプレビューの色だけで、編集画面、HTML・PDFの書き出し、iOS版には影響しない。

## 最小のテーマ

色を6つ決めれば、テーマとして読み込める。次のJSONを `my-theme.json` のような名前で保存する。

```json
{
  "schemaVersion": 1,
  "id": "example.plain-light",
  "name": "Plain Light",
  "theme": {
    "name": "Plain Light",
    "background": "#FFFDF8",
    "body": "#2A2A2A",
    "heading": "#2A2A2A",
    "code": "#2A2A2A",
    "link": "#0B57A4",
    "codeBackground": "#F1EEE6"
  }
}
```

「MKTownEditor」→「設定…」（⌘,）→「プレビュー」→「カスタムテーマを読み込む…」でこのファイルを選ぶと、テーマが追加され、その場で選択される。このテーマではコードブロックの文字がすべて `code` の色になる。字句ごとに色を分ける方法は「コードの字句の色」の節で説明する。

## ファイルの項目

外側の項目はテーマを入れる「拡張」の情報で、色は `theme` の中に書く。

| 項目 | 内容 | 制約 |
| --- | --- | --- |
| `schemaVersion` | 形式の版 | `1` 固定 |
| `id` | 拡張の識別子。読み込み直すときの上書きの判定に使う | 半角英数字と `.` `_` `-`、100文字まで |
| `name` | 設定の「拡張」に表示する名前 | 80文字まで |
| `theme.name` | 「配色」の選択肢に表示する名前 | 80文字まで |

`id` は `自分の名前.テーマ名` のように、他の拡張と重ならない文字列にする。同じ `id` のファイルを読み込むと、前の内容を置き換える。

色はすべて `#RRGGBB` の6桁で書く。`#FFF` のような3桁、`#RRGGBBAA` のような透明度つき、`red` のような色名は使えない。

## 色の役割

| 項目 | 塗る場所 |
| --- | --- |
| `background` | プレビュー全体の背景 |
| `body` | 本文、リスト、引用、表、フロントマター |
| `heading` | 見出し |
| `link` | リンク |
| `codeBackground` | インラインコードの背景、コードブロックの枠の中 |
| `code` | インラインコード、コードブロックの地の文字、コピーボタン |

表の罫線、引用の縦線、コードブロックの枠線には専用の項目がない。これらは `background` の明るさから決まる。`background` が暗ければ暗い外観用の薄い線に、明るければ明るい外観用の線になる。そのため、暗いテーマを作るときも罫線の色を指定する必要はない。

`codeBackground` は `background` と少しだけ違う色にする。同じ色でも読み込めるが、インラインコードが本文と見分けにくくなる。

## コードの字句の色

`theme` に `syntax` を加えると、コードブロックをキーワードや文字列などの字句ごとに色分けできる。次は暗いテーマの例である。

```json
{
  "schemaVersion": 1,
  "id": "example.soft-dark",
  "name": "Soft Dark",
  "theme": {
    "name": "Soft Dark",
    "background": "#22252B",
    "body": "#D7DAE0",
    "heading": "#E8C07D",
    "code": "#D7DAE0",
    "link": "#7FB4F0",
    "codeBackground": "#1A1C21",
    "syntax": {
      "keyword": "#D69AE0",
      "type": "#7CC5D6",
      "string": "#A9D08A",
      "comment": "#9198A6",
      "number": "#E0A070",
      "attribute": "#E3C78A",
      "variable": "#E58F97",
      "inserted": "#A9D08A",
      "deleted": "#E58F97"
    }
  }
}
```

`syntax` に書ける名前は次の9つで、これ以外の名前があるとテーマ全体を読み込まない。

| 名前 | 色が付く字句の例 |
| --- | --- |
| `keyword` | `if`、`return`、`SELECT`、HTMLのタグ名 |
| `type` | `Int`、`String`、大文字で始まる型名、CSSのセレクタ |
| `string` | `"text"`、HTMLの属性値 |
| `comment` | `// note`、`# note` |
| `number` | `42`、`0x1F`、`4px` |
| `attribute` | `@Override`、`#include`、JSON・YAMLのキー、CSSのプロパティ |
| `variable` | シェルの `$name`、Rubyの `@name`・`:symbol` |
| `inserted` | Diffの `+` 行 |
| `deleted` | Diffの `-` 行 |

9つすべてを書く必要はない。書かなかった字句は `code` の色で表示する。関数名や演算子には字句の種類がないため、どのテーマでも `code` の色になる。言語ごとの分類は[コードブロックの色分け](code-syntax-highlighting.md)にある。

## コントラストの基準

文字の色は、その文字が載る背景に対して4.5:1以上のコントラスト比が必要で、1色でも届かないとテーマ全体を読み込まない。比べる相手は色によって違う。

| 色 | 比べる背景 |
| --- | --- |
| `body`、`heading`、`link` | `background` |
| `code` | `background` と `codeBackground` の両方 |
| `syntax` の各色 | `codeBackground` |

`code` だけ相手が2つあるのは、インラインコードとコードブロックの文字を `codeBackground` の上に描き、同じ色を `background` に対しても検査しているためである。

既存の配色を移すと、コメントの色がこの基準に届かないことが多い。コメントは目立たせない意図で背景に近い色が選ばれているためで、Monokaiのコメント色（#75715E）は背景（#272822）に対して約3.0:1しかない。この場合は、色相を変えずに背景から遠ざける。暗い背景なら明るく、明るい背景なら暗くする。

コントラスト比は、次のスクリプトで読み込む前に確かめられる。アプリの検査と同じ式（WCAG 2の相対輝度）を使っている。

```python
import sys

def luminance(color):
    channels = []
    for i in (1, 3, 5):
        c = int(color[i:i + 2], 16) / 255
        channels.append(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4)
    return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]

def contrast(first, second):
    a, b = luminance(first), luminance(second)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)

print(f"{contrast(sys.argv[1], sys.argv[2]):.2f}")
```

`contrast.py` として保存し、文字色と背景色を渡して実行する。

```bash
python3 contrast.py '#75715E' '#272822'
```

## 他のエディタの配色を移す

VS CodeやTextMateのテーマを移すときは、色の役割を次のように対応させる。左の列は元のテーマでの設定名である。

| 元のテーマ | このアプリの項目 |
| --- | --- |
| `editor.background` | `background` |
| `editor.foreground` | `body`、`code` |
| `textLink.foreground` | `link` |
| 行のハイライトやサイドバーの背景 | `codeBackground` |
| `keyword`、`storage` | `syntax.keyword` |
| `entity.name.type`、`support.type` | `syntax.type` |
| `string` | `syntax.string` |
| `comment` | `syntax.comment` |
| `constant.numeric` | `syntax.number` |
| `entity.other.attribute-name`、`meta.annotation` | `syntax.attribute` |
| `variable` | `syntax.variable` |
| `markup.inserted`、`markup.deleted` | `syntax.inserted`、`syntax.deleted` |

エディタのテーマには見出しの色がないことが多い。`heading` には `body` と同じ色か、配色の中で目立つ色を1つ選ぶ。

元のテーマにある関数名（`entity.name.function`）や定数の色は、対応する字句の種類がないため移せない。

移した配色を他人に配る場合は、元のテーマのライセンスを確認する。標準装備の配色を選んだときの確認内容は[出典と権利](preview-themes.md#標準装備の配色の出典と権利)に記録している。

## 修正と削除

色を直すときは、JSONを書き換えて同じファイルをもう一度読み込む。`id` が同じなら前のテーマを置き換え、そのテーマを選択中であれば新しい色がすぐに反映される。ファイルを保存しただけでは反映されない。アプリは読み込んだ時点の内容を設定に写しており、元のファイルを参照し続けないためである。同じ理由で、読み込んだ後にファイルを移動・削除してもテーマは残る。

削除は「設定」→「拡張」で、拡張の名前の右にある「削除」を押す。選択中のテーマを削除すると、プレビューの配色は「システム」、エディタの配色は既定の「紺色」に戻る。外観に合わせて切り替えている場合のライト用・ダーク用の配色は、それぞれの既定に戻る。

## 読み込めないとき

読み込みに失敗すると「拡張を読み込めません」という警告が出る。原因はその下のメッセージから分かる。

| メッセージ | 原因 | 直し方 |
| --- | --- | --- |
| テーマの色指定を確認してください。 | `#RRGGBB` でない色がある。または `syntax` に9つ以外の名前がある | 3桁の色、色名、`syntax` の名前の綴りを確かめる |
| テーマの文字色と背景色のコントラストを4.5:1以上にしてください。 | 基準に届かない色がある | 「コントラストの基準」の表の組み合わせを、上のスクリプトで1つずつ確かめる |
| 拡張ファイルの形式を確認してください。 | `schemaVersion` が `1` でない。`id` に使えない文字がある。`name` が空 | 「ファイルの項目」の表の制約を確かめる |
| 拡張ファイルは100KB以下にしてください。 | ファイルが大きすぎる | 色以外のデータを取り除く |

これ以外のメッセージは、JSONの文法の誤りか、必須の項目の不足を示す。`theme` の中では `name` と6つの色（`background`、`body`、`heading`、`code`、`link`、`codeBackground`）が必須である。末尾の余分なカンマと、`"` の閉じ忘れも確かめる。

メッセージはどの色が原因かを示さない。色が多いテーマで原因を絞るには、`syntax` を丸ごと外して読み込み、通ったら字句の色を数個ずつ戻す。

## この文書の検証

`PreviewThemePresetTests.testAuthoringGuideExamplesLoad` が、この文書に載せた2つのJSONをアプリと同じ手順で読み込み、検査を通ることを確認する。メッセージと原因の対応は `DeclarativeExtension.validate` と `DeclarativeExtension.Theme.validate` の実装による。
