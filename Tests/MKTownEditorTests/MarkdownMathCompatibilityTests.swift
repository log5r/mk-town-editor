import AppKit
import SwiftMath
import SwiftUI
import XCTest
@testable import MKTownEditor

/// KaTeX・MathJax向けに書かれた式を、SwiftMathが描画できる形に書き換える処理の検証。
/// 数式の題材は docs-local/test-samples の無限反復指数関数のメモから取っている。
@MainActor
final class MarkdownMathCompatibilityTests: XCTestCase {
    private func normalized(_ latex: String, display: Bool = true) -> String {
        MarkdownMath.Formula(source: latex, latex: latex, display: display).swiftMathLaTeX
    }

    private func builds(_ latex: String, display: Bool = true, file: StaticString = #filePath,
                        line: UInt = #line) {
        let formula = MarkdownMath.Formula(source: latex, latex: latex, display: display)
        var error: NSError?
        let list = MTMathListBuilder.build(fromString: formula.swiftMathLaTeX, error: &error)
        XCTAssertNotNil(list, "\(latex) => \(formula.swiftMathLaTeX)", file: file, line: line)
        XCTAssertNil(error, "\(latex): \(error?.localizedDescription ?? "")", file: file, line: line)
        XCTAssertNotNil(MarkdownMathRenderer.image(formula), latex, file: file, line: line)
    }

    func testEquationEnvironmentIsUnwrappedAndAmsVariantsAreRenamed() {
        XCTAssertEqual(normalized("\\begin{equation}\nx = 1\n\\end{equation}"), "\nx = 1\n")
        XCTAssertEqual(normalized("\\begin{equation*}x\\end{equation*}"), "x")
        XCTAssertEqual(normalized("\\begin{equation}\\begin{aligned}a &= b\\\\c &= d\\end{aligned}\\end{equation}"),
                       "\\begin{aligned}a &= b\\\\c &= d\\end{aligned}")
        XCTAssertEqual(normalized("\\begin{align*}a &= b\\end{align*}"), "\\begin{aligned}a &= b\\end{aligned}")
        XCTAssertEqual(normalized("\\begin{gather*}a\\\\b\\end{gather*}"), "\\begin{gather}a\\\\b\\end{gather}")
        // 対応する \end がない式はそのまま渡し、SwiftMath側の判定に任せる。
        XCTAssertEqual(normalized("\\begin{equation}x"), "\\begin{equation}x")
        XCTAssertEqual(normalized("\\begin{aligned}x\\end{cases}"), "\\begin{aligned}x\\end{cases}")
        builds("\\begin{equation}\n\\text{dom}\\left(\\mathcal{T}\\right) = \\{ x\\in\\mathbb{R}^+~|~ e^{-e}\\le x \\le e^{\\frac{1}{e}} \\}\n\\end{equation}")
    }

    func testSingleColumnAlignedAndCasesReceiveEmptySecondColumn() {
        XCTAssertEqual(normalized("\\begin{aligned}\n a = b \\\\\n c = d \n\\end{aligned}"),
                       "\\begin{aligned}\n a = b &\\\\\n c = d \n&\\end{aligned}")
        XCTAssertEqual(normalized("\\begin{cases}a\\\\b\\end{cases}"), "\\begin{cases}a&\\\\b&\\end{cases}")
        XCTAssertEqual(normalized("\\begin{align*}a = b\\\\c = d\\end{align*}"),
                       "\\begin{aligned}a = b&\\\\c = d&\\end{aligned}")
        // 一部の行だけに & があるときはSwiftMathがそのまま2列として扱うので変更しない。
        XCTAssertEqual(normalized("\\begin{aligned}a &= b\\\\ccc = d\\end{aligned}"),
                       "\\begin{aligned}a &= b\\\\ccc = d\\end{aligned}")
        // 複数の揃え位置は最初の & だけを残し、組の区切りは \qquad に、組の中の揃え位置は取り除く。
        XCTAssertEqual(normalized("\\begin{align}a&=b & c&=d\\\\ e&=f & g&=h\\end{align}"),
                       "\\begin{aligned}a&=b \\qquad  c=d\\\\ e&=f \\qquad  g=h\\end{aligned}")
        XCTAssertEqual(normalized("\\begin{aligned}a &= b \\\\ c &= d & e &= f \\end{aligned}"),
                       "\\begin{aligned}a &= b \\\\ c &= d \\qquad  e = f \\end{aligned}")
        XCTAssertEqual(normalized("\\begin{cases}a & b & c\\end{cases}"), "\\begin{cases}a & b \\qquad  c\\end{cases}")
        builds("\\begin{align}a&=b & c&=d\\\\ e&=f & g&=h\\end{align}")
        builds("\\begin{aligned}x &= 1 & y &= 2 & z &= 3\\end{aligned}")
        // 入れ子の環境の & は外側の列として数えない。
        XCTAssertEqual(normalized("\\begin{aligned}\\begin{cases}a & b\\end{cases}\\end{aligned}"),
                       "\\begin{aligned}\\begin{cases}a & b\\end{cases}&\\end{aligned}")
        // 波括弧の中の & も列区切りではない。
        XCTAssertEqual(normalized("\\begin{aligned}\\text{a & b}\\end{aligned}"),
                       "\\begin{aligned}\\text{a & b}&\\end{aligned}")
        builds("\\begin{equation}\n    \\begin{aligned}\n        \\log{u}=e^{-u}\\log{x} + \\log\\log{\\frac{1}{x}}\n    \\end{aligned}\n\\end{equation}")
        builds("\\begin{equation}\n    \\begin{cases}\n    \\displaystyle \\lim_{n\\to \\infty}{T_{n+1}}=T_{\\infty}\\\\\n    \\displaystyle \\lim_{n\\to \\infty}{T_n}=T_{\\infty}   \n\\end{cases}\n\n\\Rightarrow \\lim_{n\\to\\infty}{\\gamma_{n}}=T_{\\infty}=\\gamma_{\\infty}\n\\end{equation}")
    }

    func testTrailingRowBreaksAreDroppedButInnerBlankRowsStay() {
        XCTAssertEqual(normalized("x = y \\\\ "), "x = y ")
        XCTAssertEqual(normalized("x = y \\\\\n\\\\\n"), "x = y ")
        XCTAssertEqual(normalized("\\begin{aligned}a &= b \\\\\n\\end{aligned}"), "\\begin{aligned}a &= b \\end{aligned}")
        XCTAssertEqual(normalized("a \\\\ \\\\ b"), "a \\\\ \\\\ b")
        XCTAssertEqual(normalized("\\\\"), "")
        let withBreak = MarkdownMath.Formula(source: "", latex: "x = y \\\\", display: true)
        let without = MarkdownMath.Formula(source: "", latex: "x = y", display: true)
        XCTAssertEqual(MarkdownMathRenderer.image(withBreak)?.size.height,
                       MarkdownMathRenderer.image(without)?.size.height)
    }

    func testAliasesAndAddedSymbolsRender() {
        XCTAssertEqual(normalized("0\\lt x \\lt 1"), "0< x < 1")
        XCTAssertEqual(normalized("x\\lt0 \\gt y"), "x<0 > y")
        XCTAssertEqual(normalized("\\plusmn\\infty \\exist \\alpha"), "\\pm\\infty \\exists \\alpha")
        // 別名より長い名前のコマンドや、改行記号に続く文字は置き換えない。
        XCTAssertEqual(normalized("\\ltx \\\\lt"), "\\ltx \\\\lt")
        for latex in ["\\therefore c=a^c", "a \\because b", "T_n \\gtrless \\chi \\gtrless T_{n+1}", "a \\lessgtr b",
                      "\\underset{u}{\\argmax}({e^{-u}u})=1", "\\argmin_{x} f(x)",
                      "\\displaystyle \\lim_{x \\to \\plusmn\\infty}{f(x)} = 0",
                      "(\\exist \\alpha \\in \\mathbb{R^{+}}, \\alpha \\lt \\beta) \\Rightarrow \\#\\{x|\\mathcal{G}'(x)=0\\}=2"] {
            builds(latex)
            builds(latex, display: false)
        }
    }

    func testBracesAndSetsAreStackedWithAtop() {
        XCTAssertEqual(normalized("\\underbrace{x^2}_{n}", display: false),
                       "{{\\textstyle\\underline{x^2}} \\atop {\\scriptstyle n}}")
        XCTAssertEqual(normalized("\\underbrace{x^2}_{n}", display: true),
                       "{{\\displaystyle\\underline{x^2}} \\atop {\\scriptstyle n}}")
        XCTAssertEqual(normalized("\\displaystyle \\underbrace{x^2}_n = 2", display: false),
                       "\\displaystyle {{\\displaystyle\\underline{x^2}} \\atop {\\scriptstyle n}} = 2")
        XCTAssertEqual(normalized("{\\displaystyle a} \\underbrace{x}_{n}", display: false),
                       "{\\displaystyle a} {{\\textstyle\\underline{x}} \\atop {\\scriptstyle n}}")
        // 環境の中で宣言した書体はそのセルだけに効き、\\end の後や次のセルには漏れない。
        XCTAssertEqual(normalized("\\begin{aligned}\\scriptstyle a&=b\\end{aligned}\\underbrace{x}_y", display: true),
                       "\\begin{aligned}\\scriptstyle a&=b\\end{aligned}{{\\displaystyle\\underline{x}} \\atop {\\scriptstyle y}}")
        XCTAssertEqual(normalized("\\begin{aligned}\\scriptstyle a &= \\underbrace{x}_y \\\\ \\underbrace{p}_q &= r\\end{aligned}", display: true),
                       "\\begin{aligned}\\scriptstyle a &= {{\\displaystyle\\underline{x}} \\atop {\\scriptstyle y}} \\\\ {{\\displaystyle\\underline{p}} \\atop {\\scriptstyle q}} &= r\\end{aligned}")
        XCTAssertEqual(normalized("\\begin{aligned}\\scriptstyle \\underbrace{a}_b & \\begin{cases}\\underbrace{c}_d & e\\end{cases}\\end{aligned}", display: true),
                       "\\begin{aligned}\\scriptstyle {{\\scriptstyle\\underline{a}} \\atop {\\scriptscriptstyle b}} & \\begin{cases}{{\\textstyle\\underline{c}} \\atop {\\scriptstyle d}} & e\\end{cases}\\end{aligned}")
        XCTAssertEqual(normalized("\\begin{pmatrix}\\underbrace{a}_b & \\text{x & y}\\end{pmatrix}", display: true),
                       "\\begin{pmatrix}{{\\textstyle\\underline{a}} \\atop {\\scriptstyle b}} & \\text{x & y}\\end{pmatrix}")
        builds("\\begin{aligned}\\scriptstyle a&=b\\end{aligned}\\underbrace{x}_y")
        // 既存の \\atop・\\over・\\choose を含むグループは分数なので、中身は一段小さい書体にする。
        XCTAssertEqual(normalized("{\\underbrace{a}_b \\atop c}", display: true),
                       "{{{\\textstyle\\underline{a}} \\atop {\\scriptstyle b}} \\atop c}")
        XCTAssertEqual(normalized("\\underbrace{a}_b \\over c", display: false),
                       "{{\\scriptstyle\\underline{a}} \\atop {\\scriptscriptstyle b}} \\over c")
        XCTAssertEqual(normalized("{n \\choose \\underbrace{k}_m} \\underbrace{a}_b", display: true),
                       "{n \\choose {{\\textstyle\\underline{k}} \\atop {\\scriptstyle m}}} {{\\displaystyle\\underline{a}} \\atop {\\scriptstyle b}}")
        // 分子で宣言した書体は分母には及ばない。
        XCTAssertEqual(normalized("{\\scriptstyle a \\atop \\underbrace{x}_y}", display: true),
                       "{\\scriptstyle a \\atop {{\\textstyle\\underline{x}} \\atop {\\scriptstyle y}}}")
        XCTAssertEqual(normalized("\\displaystyle \\underbrace{a}_b \\over \\underbrace{x}_y", display: false),
                       "\\displaystyle {{\\displaystyle\\underline{a}} \\atop {\\scriptstyle b}} \\over {{\\scriptstyle\\underline{x}} \\atop {\\scriptscriptstyle y}}")
        // 入れ子のグループや環境・\\left の中の \\atop は、外側のグループを分数にしない。
        XCTAssertEqual(normalized("{{x \\atop y} \\begin{aligned}p \\atop q\\end{aligned} \\left( r \\atop s \\right) \\underbrace{a}_b}", display: true),
                       "{{x \\atop y} \\begin{aligned}p \\atop q&\\end{aligned} \\left( r \\atop s \\right) {{\\displaystyle\\underline{a}} \\atop {\\scriptstyle b}}}")
        builds("{\\underbrace{a}_b \\atop c} + {n \\choose \\underbrace{k}_m}")
        // 添字と分数の引数では一段小さい書体を使い、周囲より大きくならないようにする。
        XCTAssertEqual(normalized("x_{\\underbrace{a}_b}", display: false),
                       "x_{{{\\scriptstyle\\underline{a}} \\atop {\\scriptscriptstyle b}}}")
        XCTAssertEqual(normalized("x^{\\overset{a}{b}}", display: true),
                       "x^{{{\\scriptscriptstyle a} \\atop {\\scriptstyle b}}}")
        XCTAssertEqual(normalized("x_\\underbrace{a}_b", display: false),
                       "x_{{\\scriptstyle\\underline{a}} \\atop {\\scriptscriptstyle b}}")
        XCTAssertEqual(normalized("\\frac{\\underbrace{a}_b}{c}", display: true),
                       "\\frac{{{\\textstyle\\underline{a}} \\atop {\\scriptstyle b}}}{c}")
        XCTAssertEqual(normalized("\\frac{a}{\\underbrace{b}_c}", display: false),
                       "\\frac{a}{{{\\scriptstyle\\underline{b}} \\atop {\\scriptscriptstyle c}}}")
        XCTAssertEqual(normalized("x_{a}^{\\underbrace{b}_c} \\underbrace{d}_e", display: false),
                       "x_{a}^{{{\\scriptstyle\\underline{b}} \\atop {\\scriptscriptstyle c}}} {{\\textstyle\\underline{d}} \\atop {\\scriptstyle e}}")
        // 分数の引数が終わった後や、添字でない波括弧の中は元の書体に戻る。
        XCTAssertEqual(normalized("\\frac{a}{b} \\underbrace{c}_d", display: true),
                       "\\frac{a}{b} {{\\displaystyle\\underline{c}} \\atop {\\scriptstyle d}}")
        // 添字の直後がコマンドなら、その引数グループにも添字の書体を使う。
        XCTAssertEqual(normalized("x_\\sqrt{\\underbrace{a}_b}", display: false),
                       "x_\\sqrt{{{\\scriptstyle\\underline{a}} \\atop {\\scriptscriptstyle b}}}")
        XCTAssertEqual(normalized("x^\\frac{\\underbrace{a}_b}{\\underbrace{c}_d}", display: false),
                       "x^\\frac{{{\\scriptscriptstyle\\underline{a}} \\atop {\\scriptscriptstyle b}}}{{{\\scriptscriptstyle\\underline{c}} \\atop {\\scriptscriptstyle d}}}")
        XCTAssertEqual(normalized("x_\\mathbb{R} \\underbrace{a}_b", display: false),
                       "x_\\mathbb{R} {{\\textstyle\\underline{a}} \\atop {\\scriptstyle b}}")
        XCTAssertEqual(normalized("x_\\alpha \\underbrace{a}_b", display: false),
                       "x_\\alpha {{\\textstyle\\underline{a}} \\atop {\\scriptstyle b}}")
        XCTAssertEqual(normalized("\\frac{a}\\sqrt{\\underbrace{b}_c}", display: true),
                       "\\frac{a}\\sqrt{{{\\textstyle\\underline{b}} \\atop {\\scriptstyle c}}}")
        XCTAssertEqual(normalized("\\frac\\sqrt{\\underbrace{a}_b}{\\underbrace{c}_d}", display: true),
                       "\\frac\\sqrt{{{\\textstyle\\underline{a}} \\atop {\\scriptstyle b}}}{{{\\textstyle\\underline{c}} \\atop {\\scriptstyle d}}}")
        XCTAssertEqual(normalized("x_\\underbrace{a}_b^{\\underbrace{c}_d}", display: false),
                       "x_{{\\scriptstyle\\underline{a}} \\atop {\\scriptscriptstyle b}}^{{{\\scriptstyle\\underline{c}} \\atop {\\scriptscriptstyle d}}}")
        XCTAssertEqual(normalized("\\lim_{n\\to\\infty}{^n{x}} \\underbrace{a}_b", display: false),
                       "\\lim_{n\\to\\infty}{^n{x}} {{\\textstyle\\underline{a}} \\atop {\\scriptstyle b}}")
        XCTAssertEqual(normalized("\\text{a \\lt b}_\\sqrt", display: false), "\\text{a < b}_\\sqrt")
        // 色指定と \\left ... \\right の対も、添字トークンとしてひとまとまりに読む。
        XCTAssertEqual(normalized("x_\\color{red}{\\underbrace{a}_b}", display: false),
                       "x_\\color{red}{{{\\scriptstyle\\underline{a}} \\atop {\\scriptscriptstyle b}}}")
        XCTAssertEqual(normalized("x^\\textcolor{red}{\\underbrace{a}_b} \\underbrace{c}_d", display: false),
                       "x^\\textcolor{red}{{{\\scriptstyle\\underline{a}} \\atop {\\scriptscriptstyle b}}} {{\\textstyle\\underline{c}} \\atop {\\scriptstyle d}}")
        XCTAssertEqual(normalized("x_\\left(\\underbrace{a}_b\\right) \\underbrace{c}_d", display: false),
                       "x_\\left({{\\scriptstyle\\underline{a}} \\atop {\\scriptscriptstyle b}}\\right) {{\\textstyle\\underline{c}} \\atop {\\scriptstyle d}}")
        XCTAssertEqual(normalized("x_\\left\\{ \\left( a \\right) \\underbrace{b}_c \\right\\} \\underbrace{d}_e", display: true),
                       "x_\\left\\{ \\left( a \\right) {{\\scriptstyle\\underline{b}} \\atop {\\scriptscriptstyle c}} \\right\\} {{\\displaystyle\\underline{d}} \\atop {\\scriptstyle e}}")
        // \\left ... \\right の中で宣言した書体は、その中だけに効く。
        XCTAssertEqual(normalized("\\left(\\scriptstyle a\\right)\\underbrace{x}_y", display: true),
                       "\\left(\\scriptstyle a\\right){{\\displaystyle\\underline{x}} \\atop {\\scriptstyle y}}")
        XCTAssertEqual(normalized("\\left( \\scriptstyle \\left[ b \\right] \\underbrace{p}_q \\right) \\underbrace{x}_y", display: true),
                       "\\left( \\scriptstyle \\left[ b \\right] {{\\scriptstyle\\underline{p}} \\atop {\\scriptscriptstyle q}} \\right) {{\\displaystyle\\underline{x}} \\atop {\\scriptstyle y}}")
        XCTAssertEqual(normalized("\\left\\{ \\scriptstyle a \\right. \\underbrace{x}_y \\left( \\scriptstyle b", display: false),
                       "\\left\\{ \\scriptstyle a \\right. {{\\textstyle\\underline{x}} \\atop {\\scriptstyle y}} \\left( \\scriptstyle b")
        builds("\\left(\\scriptstyle a\\right)\\underbrace{x}_y")
        // SwiftMathが解釈するアクセントと書体のコマンドは、すべて引数ごと添字トークンに含める。
        for command in ["check", "acute", "grave", "breve", "widehat", "bm", "rm", "texttt", "mathbfit"] {
            XCTAssertEqual(normalized("x_\\\(command){\\underbrace{a}_b} \\underbrace{c}_d", display: false),
                           "x_\\\(command){{{\\scriptstyle\\underline{a}} \\atop {\\scriptscriptstyle b}}} {{\\textstyle\\underline{c}} \\atop {\\scriptstyle d}}",
                           command)
        }
        builds("x_\\check{\\underbrace{a}_b} + x^\\breve{\\underbrace{a}_b} + x_\\bm{\\underbrace{a}_b}")
        // 環境も \\end までを添字トークンとして読む。
        XCTAssertEqual(normalized("x_\\begin{aligned}\\underbrace{a}_b&=c\\end{aligned} \\underbrace{d}_e", display: true),
                       "x_\\begin{aligned}{{\\scriptstyle\\underline{a}} \\atop {\\scriptscriptstyle b}}&=c\\end{aligned} {{\\displaystyle\\underline{d}} \\atop {\\scriptstyle e}}")
        XCTAssertEqual(normalized("x^\\begin{cases}\\underbrace{a}_b & c\\end{cases}", display: true),
                       "x^\\begin{cases}{{\\textstyle\\underline{a}} \\atop {\\scriptstyle b}} & c\\end{cases}")
        builds("x_\\begin{aligned}\\underbrace{a}_b&=c\\end{aligned}")
        // \\right がない \\left は括弧だけを添字として扱い、残りは元の書体のまま。
        XCTAssertEqual(normalized("x_\\left( \\underbrace{a}_b", display: false),
                       "x_\\left( {{\\textstyle\\underline{a}} \\atop {\\scriptstyle b}}")
        builds("x_\\color{red}{\\underbrace{a}_b} + x_\\left(\\underbrace{a}_b\\right) + x^\\colorbox{yellow}{\\underbrace{a}_b}")
        // \\sqrt の任意引数は根号の一部として添字トークンに含める。
        XCTAssertEqual(normalized("x_\\sqrt[3]{\\underbrace{a}_b}", display: false),
                       "x_\\sqrt[3]{{{\\scriptstyle\\underline{a}} \\atop {\\scriptscriptstyle b}}}")
        // 根号の指数は最小の書体、被開法数は元の書体のまま。
        XCTAssertEqual(normalized("\\sqrt[\\underbrace{a}_b]{\\underbrace{c}_d}", display: true),
                       "\\sqrt[{{\\scriptscriptstyle\\underline{a}} \\atop {\\scriptscriptstyle b}}]{{{\\displaystyle\\underline{c}} \\atop {\\scriptstyle d}}}")
        // 指数の中の波括弧に守られた ] や \\] は終端ではない。
        XCTAssertEqual(normalized("\\sqrt[{]}+\\underbrace{a}_b]{x} \\underbrace{c}_d", display: true),
                       "\\sqrt[{]}+{{\\scriptscriptstyle\\underline{a}} \\atop {\\scriptscriptstyle b}}]{x} {{\\displaystyle\\underline{c}} \\atop {\\scriptstyle d}}")
        XCTAssertEqual(normalized("x_\\sqrt[\\]\\underbrace{a}_b]{\\underbrace{c}_d}", display: true),
                       "x_\\sqrt[\\]{{\\scriptscriptstyle\\underline{a}} \\atop {\\scriptscriptstyle b}}]{{{\\scriptstyle\\underline{c}} \\atop {\\scriptscriptstyle d}}}")
        // 閉じない [ は指数として扱わず、残りは元の書体のまま。
        XCTAssertEqual(normalized("\\sqrt[3 \\underbrace{a}_b", display: false),
                       "\\sqrt[3 {{\\textstyle\\underline{a}} \\atop {\\scriptstyle b}}")
        XCTAssertEqual(normalized("\\sqrt [3] {\\underbrace{c}_d} \\lt", display: false),
                       "\\sqrt[3] {{{\\textstyle\\underline{c}} \\atop {\\scriptstyle d}}} <")
        builds("\\sqrt[\\underbrace{a}_b]{\\underbrace{c}_d}")
        // 書体を固定する分数は、SwiftMathにある \\frac・\\binom に書体命令を付けて置き換え、
        // 引数の書体はその固定書体から導く。
        XCTAssertEqual(normalized("\\tfrac{\\underbrace{a}_b}{c}", display: true),
                       "{\\textstyle\\frac{{{\\scriptstyle\\underline{a}} \\atop {\\scriptscriptstyle b}}}{c}}")
        XCTAssertEqual(normalized("\\dfrac{\\underbrace{a}_b}{c}", display: false),
                       "{\\displaystyle\\frac{{{\\textstyle\\underline{a}} \\atop {\\scriptstyle b}}}{c}}")
        XCTAssertEqual(normalized("\\tbinom{n}{\\underbrace{k}_m} \\underbrace{a}_b", display: true),
                       "{\\textstyle\\binom{n}{{{\\scriptstyle\\underline{k}} \\atop {\\scriptscriptstyle m}}}} {{\\displaystyle\\underline{a}} \\atop {\\scriptstyle b}}")
        XCTAssertEqual(normalized("x_\\tfrac{a}{b} \\dbinom12", display: false),
                       "x_{\\textstyle\\frac{a}{b}} {\\displaystyle\\binom12}")
        builds("\\tfrac{\\underbrace{a}_b}{c} + \\dfrac{1}{2} + \\tbinom{n}{k} + \\dbinom{n}{k} + x_\\sqrt[3]{\\underbrace{a}_b}")
        builds("x_\\sqrt{\\underbrace{a}_b} + x^\\frac{\\underbrace{a}_b}{c} + \\frac\\sqrt{\\underbrace{a}_b}{c}")
        // 波括弧のない引数（`\\frac1{...}`・`\\frac\\alpha{...}`）の後も、残りの引数は分数の書体にする。
        XCTAssertEqual(normalized("\\frac1{\\underbrace{b}_c}", display: true),
                       "\\frac1{{{\\textstyle\\underline{b}} \\atop {\\scriptstyle c}}}")
        XCTAssertEqual(normalized("\\frac\\alpha{\\underbrace{b}_c}", display: true),
                       "\\frac\\alpha{{{\\textstyle\\underline{b}} \\atop {\\scriptstyle c}}}")
        XCTAssertEqual(normalized("\\frac{a}\\underbrace{b}_c", display: true),
                       "\\frac{a}{{\\textstyle\\underline{b}} \\atop {\\scriptstyle c}}")
        XCTAssertEqual(normalized("\\frac12{\\underbrace{b}_c}", display: true),
                       "\\frac12{{{\\displaystyle\\underline{b}} \\atop {\\scriptstyle c}}}")
        builds("\\frac1{\\underbrace{b}_c} + \\frac{a}\\underbrace{b}_c")
        XCTAssertEqual(normalized("\\frac12 \\underbrace{c}_d", display: false),
                       "\\frac12 {{\\textstyle\\underline{c}} \\atop {\\scriptstyle d}}")
        XCTAssertEqual(normalized("\\sqrt{\\underbrace{c}_d}", display: false),
                       "\\sqrt{{{\\textstyle\\underline{c}} \\atop {\\scriptstyle d}}}")
        for latex in ["x_{\\underbrace{a}_b}", "\\frac{\\underbrace{a}_{b}}{c} + x^{\\overset{a}{b}}"] {
            builds(latex)
            builds(latex, display: false)
        }
        XCTAssertEqual(normalized("\\underbrace{x^2}", display: false), "\\underline{x^2}")
        XCTAssertEqual(normalized("\\underbrace{x^2}^{a}", display: false), "\\underline{x^2}^{a}")
        XCTAssertEqual(normalized("\\overbrace{x+y}^{\\text{sum}}"),
                       "{{\\scriptstyle \\text{sum}} \\atop {\\displaystyle\\overline{x+y}}}")
        XCTAssertEqual(normalized("\\underset{u}{\\argmax}", display: false),
                       "{{\\textstyle \\argmax} \\atop {\\scriptstyle u}}")
        XCTAssertEqual(normalized("\\overset{\\text{def}}{=}"),
                       "{{\\scriptstyle \\text{def}} \\atop {\\displaystyle =}}")
        // 引数の中の別名と入れ子の括弧も書き換える。
        XCTAssertEqual(normalized("\\underbrace{a \\lt \\{b\\}}_{c}", display: false),
                       "{{\\textstyle\\underline{a < \\{b\\}}} \\atop {\\scriptstyle c}}")
        XCTAssertEqual(normalized("\\underbrace{x}_", display: false), "\\underline{x}_")
        XCTAssertEqual(normalized("\\underset{a}", display: false), "\\underset{a}")
        let tower = "\\displaystyle \\underbrace{\\sqrt{2}^{\\sqrt{2}^{\\sqrt{2}^{^{\\cdot^{\\cdot^{\\cdot}}}}}}}_{\\text{height:}~\\infty}=2"
        builds(tower, display: false)
        builds("\\mathcal{T}(a)= \\displaystyle \\lim_{n\\to\\infty}{^n{a}}=\\underbrace{a^{a^{a^{^{\\cdot^{\\cdot^{\\cdot}}}}}}}_{\\text{height:}~\\infty} = c", display: false)
        builds("\\min \\{~ x ~|~ L_{\\infty} = H_{\\infty} \\}  \\overset{\\text{def}}{=} x_0")
    }

    func testTetrationNoteFormulasRender() {
        for latex in [
            "\\begin{equation}\n\\mathcal{T}:U \\subset \\mathbb{R}^+ \\rightarrow V\\subset \\mathbb{R}^+; x \\mapsto \\mathcal{X} ~\\text{s.t.}~ (\\mathcal{X}=\\lim_{n\\to\\infty}{^n{x}}, ~ \\mathcal{X} \\ll \\infty)\n\\end{equation}",
            "\\begin{aligned}\n\\frac{u'}{u} &= \\frac{1}{c^2} \\left( 1-2c-\\log{c} \\right) \\\\\n\\therefore u'&= u\\cdot\\frac{1}{c^2} \\left( 1-2c-\\log{c} \\right)\\\\\n&= c^{\\frac{1}{c}-4} \\left( 1-2c-\\log{c} \\right)\n\\end{aligned}",
            "\\frac{\\text{d}p}{\\text{d}c}=c^{\\frac{1}{c}-4}\\left(1 - 2c - \\log{c} \\right) \\\\",
            "\\begin{equation}\n    \\begin{aligned}\n        \\mathcal{D} \\gt 0 &\\Leftrightarrow \\mathcal{G}'(u) \\lt 0\\\\\n        \\mathcal{D} = 0 &\\Leftrightarrow \\mathcal{G}'(u) = 0\n    \\end{aligned}\n\\end{equation}",
            "\\begin{equation}\n    \\begin{aligned}\n        \\begin{cases}\n            0 \\lt {e^{-u}u} \\le e^{-1}\\\\\n            \\underset{u}{\\argmax}({e^{-u}u})=1\n        \\end{cases}\n    \\end{aligned}\n\\end{equation}",
            "\\begin{equation}\n    \\begin{aligned}\n        \\mathcal{F}\\left(-\\frac{1}{\\log{x}}\\right)=-\\frac{1}{\\log{x}}-x^{-\\frac{1}{\\log{x}}}\n\n    \\end{aligned}\n\\end{equation}",
            "\\begin{aligned}\n    \\{x\\in \\mathbb{R}^+~|~e^{-e}\\le x \\lt 1 \\} &\\subset \\text{dom}(\\mathcal{T})\\\\\n    \\inf\\text{dom}(\\mathcal{T})&= e^{-e}\n\\end{aligned}",
        ] {
            builds(latex)
        }
        for latex in ["x \\lt e^{-e}", "0 \\lt {e^{-u}u} \\le e^{-1}", "T_{n} \\gtrless \\gamma_n \\gtrless T_{n+1}",
                      "\\color{red}{x} \\ne y"] {
            builds(latex, display: false)
        }
    }

    func testOriginalLaTeXStaysForAltTextWhileUnknownCommandsRemainLiteral() {
        let html = MarkdownHTMLExporter.render("$$\\begin{equation}0 \\lt x\\end{equation}$$")
        XCTAssertTrue(html.contains("class=\"math-block\""))
        XCTAssertTrue(html.contains("alt=\"\\begin{equation}0 \\lt x\\end{equation}\""))
        XCTAssertTrue(MarkdownRenderer.render("値は $0 \\lt x \\lt 1$ です").string.contains("\u{FFFC}"))
        XCTAssertTrue(MarkdownRenderer.render("$\\unknowncommand \\lt 1$").string.contains("$\\unknowncommand \\lt 1$"))
        let cache = PreviewRenderCache()
        XCTAssertTrue(cache.canRenderDisplayFormula(MarkdownMath.displayFormula("$$\n\\begin{equation}\n\\therefore c=a^c\n\\end{equation}\n$$")!))
        XCTAssertFalse(cache.canRenderDisplayFormula(MarkdownMath.displayFormula("$$\\begin{array}{cc}a&b\\end{array}$$")!))
    }

    func testCompatibilityFormulasAppearInActualPreviewLayout() throws {
        let source = "本文中に $x \\lt e^{-e}$ と書けます。\n\n$$\n\\begin{equation}\n\\therefore c=a^c\n\\end{equation}\n$$\n"
        let host = NSHostingView(rootView: MarkdownPreview(markdown: source, documentContext: DocumentContext(fileURL: nil)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = window.contentView?.bounds ?? .zero
        host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }

        func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { views(type, in: $0) }
        }
        let textViews = views(NSTextView.self, in: host).filter { $0.string.contains("\u{FFFC}") }
        XCTAssertEqual(textViews.count, 1)
        let labels = views(MTMathUILabel.self, in: host)
        XCTAssertEqual(labels.count, 1)
        XCTAssertNil(labels.first?.error)
        XCTAssertEqual(labels.first?.latex, "\n\\therefore c=a^c\n")
        XCTAssertGreaterThan(labels.first?.fittingSize.width ?? 0, 20)
    }
}
