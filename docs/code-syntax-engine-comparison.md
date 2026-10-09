# コード色分けエンジンの比較記録（旧走査器と Tree-sitter）

2026-10-09。[Issue #67](https://github.com/log5r/mk-town-editor/issues/67) の採用判断の記録です。JavaScript・TypeScript・TSX・Ruby の色分けを、手書きの走査器（`CodeSyntaxTokenizer`）から Tree-sitter へ移す前に、同じ入力で両者の結果を並べました。

- 使用した版：swift-tree-sitter 0.25.0（ランタイム 0.25.10）、tree-sitter-javascript 0.23.1、tree-sitter-typescript 0.23.2（TSX を含む）、tree-sitter-ruby 0.23.1。
- クエリは上流の `highlights.scm` ではなく、このアプリ用に書いたもの（`TreeSitterSyntaxParser.swift` の `TreeSitterHighlightQueries`）。述語（`#match?` など）は使わない。
- 表の「旧」「新」は、文字列・コメント・数値の字句を `テキスト:種類` で並べたもの。一部の行は属性（`attribute`）、型（`type`）、変数（`variable`）も含む。何も見つからない場合は「単色」。改行は `⏎` で示す。
- 「判定」は「旧と同じか」ではなく、「意図」の欄に書いた期待に対して新しい結果が良くなったか（改善）、同じか（維持）、悪くなったか（悪化）、静的な構文解析では扱えないか（対象外）で付けた。
- 例は `CodeSyntaxHighlighterTests` の `testRegexLiteralsAreNotCommentsAndDivisionStaysCode` の入力と、[コード色分けの既知の制約](code-syntax-highlighting.md#既知の制約)の2件、JSX・TSX、テンプレート文字列、Ruby の補間とヒアドキュメント、閉じていない入力、デコレーター、型注釈、Ruby の記号・変数・定数。

## 結果

43件の内訳は、改善5件、維持28件、悪化8件、対象外2件。

- 改善：JSX・TSX の閉じタグ（旧は `</Button>; /` を正規表現と取り違えた）、テンプレート文字列と Ruby の文字列補間の中の数値、Ruby のヒアドキュメント（旧は本文の `#` をコメントと取り違えた）。
- 悪化：Ruby のローカル変数の後ろの `/`（4件）、名前のない `export default function() {}` の直後の正規表現、字下げした `  =end` を Ruby のブロックコメントの終わりとすること、閉じていない文字列と閉じていないブロックコメント。
- 対象外：Ruby の `eval` で定義した変数、括弧内で行頭が `/` になる Ruby（構文エラーになる書き方）。

## 比較表

| 例 | 意図 | 旧 | 新 | 判定 |
|---|---|---|---|---|
| `const slash = /[//]/g; return 1;⏎let r = a / b / c; // note⏎if (/\/\*/.test(x)) {}` | `/[//]/g` と `/\/\*/` は正規表現、`a / b / c` は除算、`// note` だけがコメント | `/[//]/g`:string `1`:number `// note`:comment `/\/\*/`:string | `/[//]/g`:string `1`:number `// note`:comment `/\/\*/`:string | 維持 |
| `const slash = /[//]/g; return 1;⏎let r = a / b / c; // note⏎if (/\/\*/.test(x)) {}` | 同上（TypeScript） | `/[//]/g`:string `1`:number `// note`:comment `/\/\*/`:string | `/[//]/g`:string `1`:number `// note`:comment `/\/\*/`:string | 維持 |
| `const r = /* note */ /[//]/g; return 1⏎export default /[//]/g; const x = 1⏎y = ++/a/.lastIndex` | コメント・`default`・前置 `++` の後ろは正規表現 | `/* note */`:comment `/[//]/g`:string `1`:number `/[//]/g`:string `1`:number `/a/`:string | `/* note */`:comment `/[//]/g`:string `1`:number `/[//]/g`:string `1`:number `/a/`:string | 維持 |
| `a = x++ / b/g⏎c = y-- / d/g⏎const q = obj.in / b/g` | 後置 `++` `--` とメンバー名 `obj.in` の後ろは除算（文字列なし） | 単色 | 単色 | 維持 |
| `if (ok) /[//]/.test(x); return 1⏎while (a) /b/g.exec(s)⏎for (;;) /c/.test(t)` | 制御文の条件の後ろは正規表現 | `/[//]/`:string `1`:number `/b/g`:string `/c/`:string | `/[//]/`:string `1`:number `/b/g`:string `/c/`:string | 維持 |
| `z = (a) / b / c⏎v = {a: 1} / h / i⏎w = f({}) / j / k` | 括弧・オブジェクト・呼び出しの後ろは除算（文字列なし） | `1`:number | `1`:number | 維持 |
| `if (ok) {} /e/.test(x)⏎function f() {} /f/.test(x)` | ブロックと関数宣言の後ろは文の始まりなので正規表現 | `/e/`:string `/f/`:string | `/e/`:string `/f/`:string | 維持 |
| `const p = function() {} / b / g⏎const q = () => {} / c / g⏎const r = (class {}) / d / g` | 式の中の関数・クラス本体の後ろは除算（文字列なし） | 単色 | 単色 | 維持 |
| `const f = async function() {} / b / g⏎async function h() {} /e/.test(x)` | `async function` 式の後ろは除算、宣言の後ろは正規表現 | `/e/`:string | `/e/`:string | 維持 |
| `label: {} /[//]/.test(x); return 1⏎switch (v) { case 1: {} /c/.test(x); default: {} /d/.test(x) }` | ラベルと `case` のコロンの後ろのブロックは文なので正規表現 | `/[//]/`:string `1`:number `1`:number `/c/`:string `/d/`:string | `/[//]/`:string `1`:number `1`:number `/c/`:string `/d/`:string | 維持 |
| `export default function() {}⏎/[//]/.test(x)` | 名前のない `export default function` は宣言なので次行の `/[//]/` は正規表現 | `/[//]/`:string | `//]/.test(x)`:comment | 悪化 |
| `export default function f() {}⏎/[//]/.test(x)⏎export default class K {}⏎/e/.test(x)` | 名前付きの `export default` 宣言の後ろは正規表現 | `/[//]/`:string `/e/`:string | `/[//]/`:string `/e/`:string | 維持 |
| `import fs from "node:fs"⏎/[//]/.test(x)⏎import {⏎  a,⏎  b⏎} from "y"⏎/c/.test(x)` | セミコロンのない `import` は改行で終わるので次行の `/` は正規表現（`import` 文は `/` で続けられないので文法上も自動セミコロン挿入が働く） | `"node:fs"`:string `/[//]/`:string `"y"`:string `/c/`:string | `"node:fs"`:string `/[//]/`:string `"y"`:string `/c/`:string | 維持 |
| `const of = 12; const q = of / b / g⏎for (const m of /[ab]/.exec(s)) {}⏎const n = !/d/.test(s)` | 変数名 `of` の後ろは除算、`for … of` と前置 `!` の後ろは正規表現 | `12`:number `/[ab]/`:string `/d/`:string | `12`:number `/[ab]/`:string `/d/`:string | 維持 |
| `const r = x! / c / g` | TypeScript の非 null アサーション `x!` の後ろは除算（文字列なし） | 単色 | 単色 | 維持 |
| `while (x) { break⏎/[//]/.test(x) }⏎outer: for (;;) { continue outer⏎/e/.test(x) }` | `break` `continue` は改行で終わるので次行の `/` は正規表現 | `/[//]/`:string `/e/`:string | `/[//]/`:string `/e/`:string | 維持 |
| `y = a⏎/ 2 / 3` | JavaScript に改行での文の終端はなく、`a / 2 / 3` の除算（文字列なし） | `2`:number `3`:number | `2`:number `3`:number | 維持 |
| `async function f(xs) { for await (const x of xs) /[//]/.test(x) }` | `for await (…)` の後ろは文の始まりなので正規表現 | `/[//]/`:string | `/[//]/`:string | 維持 |
| `puts /a#b/⏎x = a / b / c⏎y = @n /2 # note` | `puts /a#b/` は正規表現、`a / b / c` と `@n /2` は除算、`# note` はコメント | `/a#b/`:string `2`:number `# note`:comment | `/a#b/`:string `2`:number `# note`:comment | 維持 |
| `a = 12; x = a /2/3⏎items.each { \|n\| y = n /2/1 }⏎def f(k) k /2/1 end⏎def g k; k /2/1 end⏎puts /a#b/` | 代入済みのローカル変数・ブロックやメソッドの引数の後ろは除算、最後の `puts /a#b/` だけ正規表現 | `12`:number `2`:number `3`:number `2`:number `1`:number `2`:number `1`:number `2`:number `1`:number `/a#b/`:string | `12`:number `/2/`:string `3`:number `/2/`:string `1`:number `/2/`:string `1`:number `/2/`:string `1`:number `/a#b/`:string | 悪化 |
| `a \|\|= 12; x = a /2/3⏎b += 1; y = b /2/1⏎foo! /a#b/; z = 1⏎puts /c#d/` | 複合代入の左辺はローカル変数（除算）、`foo! /a#b/` と `puts /c#d/` は正規表現 | `12`:number `2`:number `3`:number `1`:number `2`:number `1`:number `/a#b/`:string `1`:number `/c#d/`:string | `12`:number `/2/`:string `3`:number `1`:number `/2/`:string `1`:number `/a#b/`:string `1`:number `/c#d/`:string | 悪化 |
| `a, b = 12, 3; y = a /2/3⏎h = { x: (e = 12) }; w = e /2/3⏎puts /f#g/` | 多重代入の左辺はすべて変数（除算）、最後の `puts /f#g/` だけ正規表現 | `12`:number `3`:number `2`:number `3`:number `12`:number `2`:number `3`:number `/f#g/`:string | `12`:number `3`:number `/2/`:string `3`:number `12`:number `/2/`:string `3`:number `/f#g/`:string | 悪化 |
| `def f⏎  puts = 1⏎  x = puts /2/1⏎end⏎puts /a#b/` | メソッド内のローカル変数 `puts` は除算、外側の `puts /a#b/` は正規表現 | `1`:number `2`:number `1`:number `/a#b/`:string | `1`:number `/2/`:string `1`:number `/a#b/`:string | 悪化 |
| `x = 1⏎/a#b/.match(s)⏎z = 4 \⏎/ 5 # note` | 行頭の `/a#b/` は正規表現、行末 `\` の次行の `/ 5` は除算、`# note` はコメント | `1`:number `/a#b/`:string `4`:number `5`:number `# note`:comment | `1`:number `/a#b/`:string `4`:number `5`:number `# note`:comment | 維持 |
| `y = (2⏎/ 3)` | Ruby では括弧内でも改行で文が終わり、行頭の `/` は正規表現の開始になる（閉じる `/` がなければ構文エラー）。旧走査器は継続とみなした。色分けの対象外 | `2`:number `3`:number | `2`:number `3`:number | 対象外 |
| `if cond then /a#b/ else nil end⏎x =~ /a#b/ if y` | `then` の後ろと `=~` の後ろは正規表現 | `/a#b/`:string `/a#b/`:string | `/a#b/`:string `/a#b/`:string | 維持 |
| `x =begin⏎  1⏎end⏎puts x⏎=begin⏎if⏎  =end⏎=end⏎return` | ブロックコメントは `=begin` `=end` が0桁目のときだけ。字下げした `  =end` では閉じない | `1`:number `=begin⏎if⏎  =end⏎=end`:comment | `1`:number `=begin⏎if⏎  =end`:comment | 悪化 |
| `foo()⏎/re/.test(x)` | 既知の制約（JavaScript）：セミコロンのない文の次行の `/re/`。JavaScript の文法では `foo() / re / .test(x)` と続く除算で、自動セミコロン挿入は起きない。除算が正しい | 単色 | 単色 | 維持 |
| `eval("a = 1"); a /2/ 1` | 既知の制約（Ruby）：`eval` で定義した変数 `a` の除算。静的な構文解析の対象外 | `"a = 1"`:string `/2/`:string `1`:number | `"a = 1"`:string `/2/`:string `1`:number | 対象外 |
| `const el = <Button label="ok">{x / y}</Button>; /re/.test(x)` | JSX の属性値は文字列、`{x / y}` は除算、`/re/` は正規表現 | `"ok"`:string `/Button>; /re`:string | `"ok"`:string `/re/`:string | 改善 |
| `const el = <Button>{x / y}</Button>; /re/.test(x)` | `{x / y}` は除算、`/re/` は正規表現 | `/Button>; /re`:string | `/re/`:string | 改善 |
| `const App = (p: Props) => <div className="a">{p.n / 2}</div>;` | TSX の型注釈とJSX。属性値は文字列、`/ 2` は除算 | `"a"`:string `2`:number | `"a"`:string `2`:number | 維持 |
| `const s = `a ${a + 1} b`;` | テンプレート文字列。`${…}` の中の `1` は数値 | ``a ${a + 1} b``:string | ``a ${a + `:string `1`:number `} b``:string | 改善 |
| `x = "a#{1}b"` | 文字列補間。`#{…}` の中の `1` は数値 | `"a#{1}b"`:string | `"a#{`:string `1`:number `}b"`:string | 改善 |
| `text = <<~EOS⏎  hello #{1}⏎  # not comment⏎EOS⏎puts text # end` | ヒアドキュメントの本文は文字列（中の `#` はコメントではない）、行末の `# end` はコメント | `#{1}`:comment `# not comment`:comment `# end`:comment | `<<~EOS⏎  hello #{`:string `1`:number `}⏎  # not comment⏎EOS`:string `# end`:comment | 改善 |
| `const s = "abc` | 閉じていない文字列でも色分けが破綻しない | `"abc`:string | 単色 | 悪化 |
| `x = 1 /* unclosed` | 閉じていないブロックコメント | `1`:number `/* unclosed`:comment | `1`:number | 悪化 |
| `if (` | 括弧が閉じていない `if (` | 単色 | 単色 | 維持 |
| `function f( {⏎  return 1 // c⏎}` | 引数リストが閉じていない関数。後ろの数値とコメントは識別したい | `1`:number `// c`:comment | `1`:number `// c`:comment | 維持 |
| `def f(⏎  x = 1 # c` | 引数リストが閉じていない `def f(`。後ろの数値とコメントは識別したい | `1`:number `# c`:comment | `1`:number `# c`:comment | 維持 |
| `@Component({ selector: 'a' })⏎class A { @Input() x = 1 }` | デコレーターは属性、`'a'` は文字列、`1` は数値 | `@Component`:attribute `'a'`:string `@Input`:attribute `1`:number | `@Component`:attribute `'a'`:string `@Input`:attribute `1`:number | 維持 |
| `interface User { name: string; age?: number }⏎const u: User = { name: 'a', age: 1 } // c` | 型注釈。文字列・数値・コメントを識別する | `User`:type `string`:type `number`:type `User`:type `'a'`:string `1`:number `// c`:comment | `User`:type `string`:type `number`:type `User`:type `'a'`:string `1`:number `// c`:comment | 維持 |
| `class Foo < Bar⏎  attr_reader :name⏎  def hi; @x = 1; $g = 'a'; end # note⏎end` | シンボル・インスタンス変数・グローバル変数・定数、文字列・数値・コメント | `Foo`:type `Bar`:type `:name`:variable `@x`:variable `1`:number `$g`:variable `'a'`:string `# note`:comment | `Foo`:type `Bar`:type `:name`:variable `@x`:variable `1`:number `$g`:variable `'a'`:string `# note`:comment | 維持 |

## 残る制約

Tree-sitter へ移しても、次の取り違えや未対応が残る。いずれも色だけの問題で、原文や書き出しの内容は変わらない。

- **Ruby のローカル変数と `/`**：tree-sitter-ruby は変数が定義済みかどうかを追跡しない。`a = 1; a /2/3` のように、変数の後ろに空白、`/`、空白なしの並びが来ると、`a(/2/3)` というメソッド呼び出しの正規表現として読む。旧走査器はスコープを追っていたため除算と判定できた。この点は後退である。対策は、色分け後に Swift 側でローカル変数を追跡して該当する正規表現を取り消す方法か、この書き方を許容するかの判断が要る。
- **Ruby の `eval` と `binding`**：実行時に定義される変数は静的な構文解析では分からない（旧走査器でも同じ）。
- **JavaScript の行頭の正規表現**：JavaScript には改行での文の終端がなく、`foo()⏎/re/.test(x)` は文法どおり除算（`foo() / re / .test(x)`）になる。自動セミコロン挿入が起きるのは、その位置のトークンが文法上許されない場合だけ（`import` 文や `break` の直後など）。旧走査器は文の種類ごとの推定で正規表現としていた箇所があったが、文法に従う Tree-sitter の結果が正しい。この制約は移行後の「既知の制約」には残らない（現行の同節の書き換えは後続の作業で行う）。
- **名前のない `export default function() {}` と `export default class {}`**：tree-sitter-javascript 0.23.1 は式として読むため、直後の行頭の `/` を正規表現にできず、構文エラーの回復で後続がコメントに見えることがある。名前付きの宣言は正しく読める。
- **Ruby の字下げした `  =end`**：tree-sitter-ruby は字下げした `=end` でもブロックコメントを閉じる（Ruby 本体は0桁目だけ）。
- **閉じていない文字列とブロックコメント**：構文木が誤り扱いになり、文字列・コメント全体が色なしになる（旧走査器は末尾まで色を付けた）。入力途中の編集画面で一時的に色が消える。他のキーワードや数値は、構文として識別できる範囲で色が付く。
- **非 null アサーション `x!`（JavaScript）**：構文エラーとして読まれ、`x! / c / g` の `/ c /` は文字列にならない（旧走査器は `!` の後ろを正規表現とみなして文字列にした）。TypeScript では非 null アサーションとして正しく除算になる。
- **クエリは自前**：上流の `highlights.scm` は述語に依存するので使わず、7種類の字句に写すクエリを書いた。上流の更新は自動では反映されず、文法パッケージを更新するときは `TreeSitterGrammar.queryRevision` を上げ、`TreeSitterSyntaxParserTests` のクエリのコンパイル確認で未知のノード名を検出する。述語を使わないため、組み込み関数名の判定（Ruby の `require` や `private`）は Swift 側の集合で行う。
- **解析の上限**：入力が100万UTF-16単位を超える場合と、解析が0.5秒を超える場合は単色にする。
