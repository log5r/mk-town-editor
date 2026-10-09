# オープンソースエディタの構文着色方式

[設計評価に戻る](code-syntax-highlighting-design.md)

2026-10-09に公式資料と公開ソースを調査した。CotEditorは公開版7.1.1、VS Codeの実装詳細はmainのコミット`8538eb35631b8981a2b0268fc5a8394c8f7b7254`を対象とする。VS Codeの公開版と開発ブランチの機能を同一とは扱わない。ZedとHelixは公式ドキュメントによる確認である。各エディタを起動した比較試験や速度測定は行っていない。

## 方式の違い

構文着色では、字句の分類、構文木の生成、意味解析を区別する。TextMate方式は正規表現と入れ子の規則で文字列やキーワードを分類する。Tree-sitter方式は構文木を作り、ノードに対するクエリで分類する。意味解析による着色は、宣言や参照の関係などを解決し、識別子の役割を判定する。LSPはエディタと言語サーバーの通信規約であり、それ自体が構文解析器ではない。

| エディタ | 基本の着色 | 補足 |
| --- | --- | --- |
| VS Code | TextMate文法、vscode-textmate、Oniguruma | Semantic Tokensを重ねる。調査した開発版には限定的なTree-sitter経路もある |
| CotEditor 7.1.1 | 主要な組み込み言語はTree-sitter、その他は正規表現・区切り規則 | SwiftTreeSitter／SwiftTreeSitterLayerを使用。色分けとアウトラインの方式を機能別に選ぶ |
| Zed | Tree-sitter文法とhighlights.scm | 同じ構文木を括弧・アウトライン・字下げ・埋め込み言語にも利用。LSPの意味着色も設定可能 |
| Helix | Tree-sitter文法とhighlights.scm | injections、locals、字下げなどを用途別クエリに分離 |

## VS Code

### TextMateによる基本の着色

言語拡張がJSONまたはplistで文法を提供し、正規表現にはOnigurumaを使う。`match`、`begin`／`end`、入れ子の規則などから字句のスコープを得て、テーマが色へ変換する。[公式ガイド](https://code.visualstudio.com/api/language-extensions/syntax-highlight-guide)

`vscode-textmate`は1行と前の行の状態を受け取り、トークン列と次の状態を返す。行ごとの正規表現置換だけではなく、複数行コメントや文字列の中にいる状態を次の行へ引き継ぐ。[vscode-textmate](https://github.com/microsoft/vscode-textmate)

差分更新では行末の状態を保存し、編集で無効になった行から再計算する。新しい行末状態が以前と異なる場合に次の行を無効化し、同じになればその変更による伝播を止められる。別に無効化された範囲は引き続き処理する。[状態の保存と比較](https://github.com/microsoft/vscode/blob/8538eb35631b8981a2b0268fc5a8394c8f7b7254/src/vs/editor/common/model/textModelTokens.ts#L231-L245)

調査した開発版にはWeb Workerによるバックグラウンド処理もあり、文書の版番号と状態差分を返し、時間を区切って処理を譲る。利用は`editor.experimental.asyncTokenization`設定に依存するため、常にすべて別スレッドとは説明できない。[設定](https://github.com/microsoft/vscode/blob/8538eb35631b8981a2b0268fc5a8394c8f7b7254/src/vs/workbench/services/textMate/browser/textMateTokenizationFeatureImpl.ts#L107-L113)・[Worker](https://github.com/microsoft/vscode/blob/8538eb35631b8981a2b0268fc5a8394c8f7b7254/src/vs/workbench/services/textMate/browser/backgroundTokenization/worker/textMateWorkerTokenizer.ts)

### 意味解析とTree-sitter

Semantic Token Providerは、変数、引数、クラス、読み取り専用の識別子などの分類を返す。VS Codeはこの結果を基本の構文着色に重ねる。プロジェクトの解析を待つため、後から色が変わることがある。Providerは言語サーバーで実装されることが多いが、VS CodeのAPIを使って直接実装することもできる。[Semantic Highlight Guide](https://code.visualstudio.com/api/language-extensions/semantic-highlight-guide)

調査したmainには`@vscode/tree-sitter-wasm`を使う実装もある。言語別の`editor.experimental.preferTreeSitter.<language>`を参照し、設定未指定時の参照値はfalse。許可対象の定数にはCSS、TypeScript、INI、regexが並ぶ。これをもってVS Codeが全面的にTree-sitterへ移行済みとは扱わない。[TreeSitterLibraryService](https://github.com/microsoft/vscode/blob/8538eb35631b8981a2b0268fc5a8394c8f7b7254/src/vs/workbench/services/treeSitter/browser/treeSitterLibraryService.ts)

## CotEditor

### 公開版はTree-sitterと正規表現を併用

CotEditorは2026-04-20公開の7.0で、多くの主要言語にTree-sitterを導入した。JavaScript、TypeScript、Ruby、Swift、C/C++などが対象で、Markdownについてはアウトライン抽出だけが対象と明記されている。従来の正規表現方式も残っている。[7.0リリースノート](https://coteditor.com/releasenotes/7.0.0.en)

7.1.1の`SyntaxController.setupParser`は、Tree-sitterパーサーを用意できる場合に、色分けとアウトラインそれぞれの対応状況でパーサーを選ぶ。対応しない機能は既存の定義に基づくパーサーを利用する。[選択処理](https://github.com/coteditor/CotEditor/blob/7.1.1/CotEditor/Sources/Models/Syntax/SyntaxController.swift#L88-L101)・[言語と機能の対応](https://github.com/coteditor/CotEditor/blob/7.1.1/Packages/Syntax/Sources/SyntaxParsers/TreeSitter/TreeSitterSyntax.swift)

正規表現側は`NSRegularExpression`、開始・終了文字列、コメント・文字列の入れ子処理を組み合わせる。`RegexHighlightParser`はactorで、抽出処理にはTaskGroupを使う。[抽出器](https://github.com/coteditor/CotEditor/blob/7.1.1/Packages/Syntax/Sources/SyntaxParsers/RegexParser/HighlightExtractors.swift)・[RegexHighlightParser](https://github.com/coteditor/CotEditor/blob/7.1.1/Packages/Syntax/Sources/SyntaxParsers/RegexParser/RegexHighlightParser.swift)

### Swift実装で参考にできる点

Tree-sitter側もactorに閉じ込められている。`TreeSitterClient`はSwiftTreeSitter／SwiftTreeSitterLayerを利用し、本文の複製と編集の影響範囲を保持する。編集を構文木へ反映し、影響範囲を含めてクエリを実行する。キャンセル確認と解析長の上限があり、同じノードへのcaptureの競合を解消してからアプリの分類と範囲へ変換する。[TreeSitterClient](https://github.com/coteditor/CotEditor/blob/7.1.1/Packages/Syntax/Sources/SyntaxParsers/TreeSitter/TreeSitterClient.swift)

共通の`HighlightParsing`はactorのプロトコルで、分類付き範囲と表示を更新する範囲を返す。画面側は結果を受け取って適用する。[共通インターフェース](https://github.com/coteditor/CotEditor/blob/7.1.1/Packages/Syntax/Sources/SyntaxParsers/SyntaxParsing.swift)

入力時には約50ミリ秒の待ち合わせで変更をまとめ、古いタスクをキャンセルする。初期表示では先頭2,000 UTF-16単位への着色を行ってから全体を処理する。これは着色要求の分割であり、最初の構文木生成も先頭だけになるという意味ではない。[SyntaxController](https://github.com/coteditor/CotEditor/blob/7.1.1/CotEditor/Sources/Models/Syntax/SyntaxController.swift)

描画は`NSLayoutManager`の一時属性として行う。分類を`.syntaxType`に保持し、テーマ変更時はそれを参照して色を当て直す。この責務分離はMKTownEditorの既存設計と近い。[描画とテーマの再適用](https://github.com/coteditor/CotEditor/blob/7.1.1/CotEditor/Sources/Models/Syntax/NSLayoutManager%2BSyntaxHighlight.swift)

### 導入上の条件

CotEditorのSyntaxパッケージをそのまま依存に追加できるとは限らない。7.1.1のPackage.swiftはSwift tools 6.3、macOS 26を要求し、内部のEditorCoreにも依存する。MKTownEditorは現時点でSwift tools 6.0、macOS 14を指定している。[CotEditorの依存定義](https://github.com/coteditor/CotEditor/blob/7.1.1/Packages/Syntax/Package.swift)

まず責務分離と処理方式を参考にし、SwiftTreeSitterおよび各文法の利用可能な版を本プロジェクトの条件で確認する。CotEditor自身も一部の文法にSwiftPM対応用のforkやブランチを利用している。

## ZedとHelix

ZedはTree-sitter文法に加えて、着色、括弧、アウトライン、埋め込み言語などの用途別クエリを持つ。同じ構文木を複数の編集機能で利用し、言語サーバーは別の層にある。公式資料では意味着色は既定でoff、Tree-sitterとの併用をcombined、意味着色だけの使用をfullとしている。[Zed言語拡張](https://zed.dev/docs/extensions/languages)

Helixも文法とクエリを分離する。`languages.toml`に文法を登録し、`runtime/queries/<language>/highlights.scm`を用意する。埋め込み言語は`injections.scm`、ローカル変数の追跡は`locals.scm`などに分ける。コードフェンスを別言語として扱う場合にも、この埋め込みの仕組みを利用できる。[Helix言語追加ガイド](https://docs.helix-editor.com/master/guides/adding_languages.html)

## MKTownEditorへの判断

色分けに完全な構文解析が必須という結論にはならない。VS CodeのTextMate方式は、状態を持つ字句規則と既存の言語文法を利用する実例である。前回の提案は、多数の言語の構文推定を自前で追加し続ける保守負担を減らすものと位置付ける。

そのうえで、Swift／AppKitを使うMKTownEditorにはCotEditorの併用方式を最も直接的な参考とする。共通の範囲表現、解析用actor、古い結果の破棄、配色の分離を導入し、構文が複雑な言語からTree-sitterに移す方針を維持する。主要3言語で期待した改善が得られなければ、TextMate系の既存文法も比較対象にする。

Markdownのコード片は、単独のソースファイルとして完結しない場合があり、型定義や依存先もそろわない。これは今回の用途に関する判断であり、性能比較の結果ではない。プロジェクト全体の意味解決やLSPの導入は初期改善に含めず、ブロック単位で完結する解析を優先する。

既存のMarkdown解析器を置き換える必要もない。まず抽出済みのコード本文だけに適用する。CotEditorがMarkdownの着色とアウトラインに異なる方式を選んでいることも、言語・機能ごとの併用が成立する実例となる。

評価時には既知の誤判定に加え、未完成の入力、埋め込み言語、UTF-16位置対応、解析結果の共有、変更したブロック以外の再利用を確認する。
