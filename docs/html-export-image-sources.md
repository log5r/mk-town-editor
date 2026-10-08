# HTML書き出しでのローカル画像・メディアの参照方法

Issue #41 の修正で決めた設計と、検証方法をまとめる。

## 症状と原因

`MarkdownHTMLExporter.render` は、ローカル画像を常に base64 の `data:` URI として本文へ埋め込み、
音声・動画のリンクには絶対 `file:` URL を書いていた。この前提が三つの機能で別々の不具合になっていた。

- 持ち出し用パッケージのHTML形式では、画像を `assets/` へコピーしたうえで `index.html` にも
  base64 で埋め込んでいたため、画像の容量が二重になっていた。後処理の書き換えは `<a href>` だけを
  対象にしており、`<img src>` は書き換えていなかった。
- WordPress公開では、本文JSONに `data:` URI が入るため `post_max_size` を超えて HTTP 413 になったり、
  KSES に除去されたりした。利用者には「HTTP 413」しか表示されなかった。
- メディアリンクは絶対 `file:` URL なので、HTMLを移動すると壊れ、ホームフォルダのパスも公開されていた。
  パッケージの後処理は `resolveLocalResource` がスキーム付きの文字列を拒否するため、このリンクも書き換えていなかった。

## 設計: `MarkdownHTMLExporter.ImageSource`

ローカルファイル（画像、`!audio`/`!video` のメディア、添付ファイルへのリンク）をどう書くかを、
呼び出し側が `images:` 引数で選ぶ。キーと引数は `resolvingSymlinksInPath().standardizedFileURL` で
正規化したファイルURLで、値はそのまま `src`/`href` に書くため、パーセントエンコード済みのURL文字列にする。

| 戦略 | 画像 | メディア・添付リンク | 使う呼び出し元 |
| --- | --- | --- | --- |
| `.embedBase64`（既定） | base64 で埋め込む | メディアは `outputURL` があればそこからの相対パス、なければ絶対 `file:` URL。添付リンクは原文のまま | 単体HTML書き出し、PDF、リッチテキストコピー、スライドPDF |
| `.relative(pathMap:)` | 対応表の値。対応がなければ代替テキスト | 対応表の値（`#`/`?` 以降は保持）。対応がなければメディアはラベルのみ、リンクは原文のまま | 持ち出し用パッケージ |
| `.resolver(_:)` | 描画中に関数へ問い合わせる。意味は `.relative` と同じ | 同左 | WordPress公開（アップロード対象の収集） |

対応表にない画像を base64 に戻さないのは、パッケージで二重保存が再発するのを防ぐためである。

単体HTML書き出し（書類のHTML書き出し、ワークスペースの一括書き出し、ショートカットのHTML書き出し）は、
保存先を `outputURL` として渡す。メディアリンクは保存先フォルダからの相対パスになり、`:`・`#`・`?`・空白を
含むファイル名も1つのパス要素としてエンコードする。画像は従来どおり base64 で埋め込み、HTML単体で表示できる状態を保つ。
相対パスで表せるのは同じファイル配置を保っている場合だけなので、別の環境へ渡すときは持ち出し用パッケージを使う。

PDF、リッチテキストコピー、スライドPDFは保存先のHTMLが存在しないため `outputURL` を渡さず、
メディアリンクは絶対 `file:` URL のままにしている。これらは同じMac上で開く用途を想定している。

## 持ち出し用パッケージ

`PortablePackagePlanner` は、先にMarkdownを走査して `assets/` へのコピー対象と対応表を決め、
その対応表を `.relative(pathMap:)` に渡してHTMLを描画する。以前の `<a href>` を正規表現で書き換える後処理は、
書き出し側の対応表で置き換えたため削除した。

## WordPress公開

`PublicationPlan.make`/`makeAsync` は `.resolver` で描画し、PNG・JPEG・GIF・WebPの画像と、
メディア記法が扱う音声・動画をアップロード対象として収集する。本文には `mktown-upload://<番号>/<ファイル名>` を
仮の参照として書き、送信内容の確認画面にはアップロード件数と置き換えの説明を表示する。
SVGなどWordPressが既定で受け付けない形式は、代替テキストにする。

`PublicationPlan.publish(perform:)` は、各ファイルを `POST /wp-json/wp/v2/media` で送り、
応答の `source_url` で仮の参照を置き換えてから投稿を送る。ファイル名は `Content-Disposition` の
`filename=` で送るため、ASCII以外の文字をハイフンに置き換える。アップロードに失敗すると、ファイル名を含む
エラーを表示し、投稿は送らない。この場合、それまでにアップロード済みのファイルはメディアライブラリに残る。
HTTP 413 には送信サイズの上限を説明する専用のメッセージを表示する。

仮の参照は属性値の `"` の直後だけを置き換える。本文中の引用符は書き出し時に `&quot;` へエスケープされるため、
同じ文字列を本文に書いても置き換えの対象にならない。

## 未対応の点

- 数式画像は書き出し時に生成するPNGを `data:` URI で埋め込んでいる。WordPressでは KSES に除去される可能性があるが、
  数式ごとにメディアライブラリへ項目を増やすかどうかは未決のため、今回は対象外とした。
- WordPress公開で、画像・メディア以外の添付ファイル（PDFなど）へのリンクは相対パスのまま送る。

## 回帰確認

```sh
swift test --filter 'PublicationTests|MarkdownHTMLExporterTests|PortablePackageExporterTests|MarkdownMediaTests|DocumentWorkTests'
```

- `PortablePackageExporterTests.testHTMLPackageReferencesCopiedAssetsInsteadOfEmbeddingThem`: `index.html` が
  `assets/` を参照し、`data:` と `file:` を含まず、画像サイズより十分小さいことを確認する。
- `PublicationTests.testWordPressUploadsLocalFilesBeforePostingAndReplacesSources`: 差し替えたネットワーク層で、
  アップロード、`source_url` への置き換え、投稿の順に送ることを確認する。
- `MarkdownMediaTests.testSavedHTMLLinksMediaRelativeToTheSavedFile`: ショートカットと一括書き出しの
  メディアリンクが保存先からの相対パスになることを確認する。
