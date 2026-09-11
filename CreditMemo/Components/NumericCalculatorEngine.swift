//
//  テンキーの簡易電卓の計算部分
//  View から切り離し、四則演算・上限判定・丸めを単体で確かめられるようにする
//

import Foundation

/// 計算できなかった理由。View 側でエラー文言に対応づける
enum NumericCalculatorError: Error, Equatable {
    /// 0 で割ろうとした
    case divideByZero
    /// 結果が扱える金額の上限を超えた
    case tooLarge

    /// 表示に使う文字列カタログのキー
    var localizedKey: String {
        switch self {
        case .divideByZero: "calculator.error.divideByZero"
        case .tooLarge:     "calculator.error.tooLarge"
        }
    }
}

/// テンキーの計算規則をまとめた入れ物。状態を持たないので単体で検証できる
enum NumericCalculatorEngine {

    /// 二項演算を行い、上限を超えていないか確かめる。
    /// - Parameters:
    ///   - left: 左辺（計算途中の値は丸めずに渡す）
    ///   - operation: 演算子
    ///   - right: 右辺
    ///   - maxValue: 扱える金額の絶対値の上限
    /// - Returns: 計算結果。0 除算と上限超過は `NumericCalculatorError` を返す
    static func calculate(
        _ left: Decimal,
        _ operation: NumericCalculatorOperator,
        _ right: Decimal,
        maxValue: Decimal
    ) -> Result<Decimal, NumericCalculatorError> {
        let result: Decimal
        switch operation {
        case .divide:
            guard right != 0 else { return .failure(.divideByZero) }
            result = left / right
        case .multiply:
            result = left * right
        case .subtract:
            result = left - right
        case .add:
            result = left + right
        }

        // 負の金額も同じ大きさまで許すため、絶対値で判定する
        let magnitude = result < 0 ? -result : result
        guard magnitude <= maxValue else { return .failure(.tooLarge) }
        return .success(result)
    }
}
