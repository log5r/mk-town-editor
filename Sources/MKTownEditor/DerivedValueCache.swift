import Foundation

/// 入力が変わった時だけ値を計算し直す。
///
/// シートの `@State` に保持し、`body` から何度参照しても同じ入力では再計算しない。
/// 参照型なので、キャッシュの更新そのものはビューの再描画を引き起こさない。
@MainActor
final class DerivedValueCache<Input: Equatable, Value> {
    private var cached: (input: Input, value: Value)?
    private(set) var computationCount = 0

    func value(for input: Input, _ compute: (Input) -> Value) -> Value {
        if let cached, cached.input == input { return cached.value }
        let value = compute(input)
        cached = (input, value)
        computationCount += 1
        return value
    }
}
