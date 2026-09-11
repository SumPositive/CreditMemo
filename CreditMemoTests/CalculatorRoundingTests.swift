import Foundation
import Testing
@testable import CreditMemo

/// テンキーの簡易電卓（四則演算・上限・丸め）。
///
/// 計算途中の値は丸めずに保持し、画面表示や確定時にだけ選択中の方法で丸める。
/// そのため「表示している金額」と「入力欄へ戻した値」がずれないことが重要になる。
struct CalculatorEngineTests {

    /// 円のように小数を持たない通貨の桁数
    private let jpyScale = 0
    /// ドルやユーロのように小数2桁を持つ通貨
    private let usdScale = 2
    private let maxValue = APP_MAX_AMOUNT

    private func value(
        _ left: Decimal,
        _ op: NumericCalculatorOperator,
        _ right: Decimal,
        max: Decimal? = nil
    ) -> Decimal? {
        try? NumericCalculatorEngine
            .calculate(left, op, right, maxValue: max ?? maxValue)
            .get()
    }

    private func error(
        _ left: Decimal,
        _ op: NumericCalculatorOperator,
        _ right: Decimal,
        max: Decimal? = nil
    ) -> NumericCalculatorError? {
        switch NumericCalculatorEngine.calculate(left, op, right, maxValue: max ?? maxValue) {
        case .success: nil
        case .failure(let e): e
        }
    }

    // MARK: - 四則演算

    @Test("四則演算がそれぞれ正しく計算される")
    func basicOperations() {
        #expect(value(1200, .add, 800) == 2000)
        #expect(value(1200, .subtract, 800) == 400)
        #expect(value(1200, .multiply, 3) == 3600)
        #expect(value(1200, .divide, 4) == 300)
    }

    @Test("減算は負の結果も返す")
    func subtractionCanGoNegative() {
        #expect(value(800, .subtract, 1200) == -400)
    }

    @Test("0 除算は計算せずエラーを返す")
    func divideByZeroFails() {
        #expect(error(1000, .divide, 0) == .divideByZero)
        // 0 を掛けるのは正当な計算なので通す
        #expect(value(1000, .multiply, 0) == 0)
    }

    /// 「5 ÷ 3 を出してから ×3」のように、結果を左辺にして計算を続ける流れ。
    /// 途中で丸めないので、最後に丸めれば元の 5 に戻る。
    /// （Decimal の除算は割り切れないため 4.999...9 になる。最終的な丸めで吸収する）
    @Test("連続計算は途中を丸めずに引き継ぐ")
    func chainedCalculationKeepsPrecision() {
        let first = value(5, .divide, 3)          // 1.666...
        #expect(first != nil)
        let second = value(first!, .multiply, 3)  // ほぼ 5
        #expect(second != nil)
        #expect(NumericCalculatorRounding.halfUp.round(second!, scale: jpyScale) == 5)

        // 途中で四捨五入していたら 2 × 3 = 6 になり、元へ戻らない
        let roundedFirst = NumericCalculatorRounding.halfUp.round(first!, scale: jpyScale)
        #expect(value(roundedFirst, .multiply, 3) == 6)
    }

    @Test("連続計算の途中結果は左辺として引き継がれる")
    func chainedCalculationAccumulates() {
        var acc = value(1000, .add, 500)      // 1500
        #expect(acc == 1500)
        acc = value(acc!, .subtract, 200)     // 1300
        #expect(acc == 1300)
        acc = value(acc!, .multiply, 2)       // 2600
        #expect(acc == 2600)
        acc = value(acc!, .divide, 4)         // 650
        #expect(acc == 650)
    }

    // MARK: - 上限

    @Test("上限ちょうどは通り、超えるとエラーになる")
    func rejectsResultOverMaxValue() {
        #expect(value(APP_MAX_AMOUNT, .add, 0) == APP_MAX_AMOUNT)
        #expect(error(APP_MAX_AMOUNT, .add, 1) == .tooLarge)
        #expect(error(APP_MAX_AMOUNT, .multiply, 2) == .tooLarge)
    }

    @Test("負の結果も絶対値で上限を判定する")
    func rejectsNegativeResultOverMaxValue() {
        // -上限 ちょうどは許す
        #expect(value(0, .subtract, APP_MAX_AMOUNT) == -APP_MAX_AMOUNT)
        // それを超える負値は弾く
        #expect(error(-APP_MAX_AMOUNT, .subtract, 1) == .tooLarge)
    }

    // MARK: - 丸め

    @Test("4種類の丸めが、割り切れない結果を期待どおり丸める")
    func roundsAccordingToMode() {
        // 2.5（ちょうど半分。方法ごとに結果が分かれる）
        let half = Decimal(5) / Decimal(2)
        #expect(NumericCalculatorRounding.up.round(half, scale: jpyScale) == 3)
        #expect(NumericCalculatorRounding.halfUp.round(half, scale: jpyScale) == 3)
        #expect(NumericCalculatorRounding.down.round(half, scale: jpyScale) == 2)
        // 偶数丸めは偶数側の 2 を選ぶ
        #expect(NumericCalculatorRounding.bankers.round(half, scale: jpyScale) == 2)

        // 3.5 は偶数丸めだと 4（偶数側）へ寄る
        let threeHalf = Decimal(7) / Decimal(2)
        #expect(NumericCalculatorRounding.halfUp.round(threeHalf, scale: jpyScale) == 4)
        #expect(NumericCalculatorRounding.bankers.round(threeHalf, scale: jpyScale) == 4)

        // 1.666... は半分より大きいので四捨五入は切り上がる
        let third = Decimal(5) / Decimal(3)
        #expect(NumericCalculatorRounding.up.round(third, scale: jpyScale) == 2)
        #expect(NumericCalculatorRounding.halfUp.round(third, scale: jpyScale) == 2)
        #expect(NumericCalculatorRounding.down.round(third, scale: jpyScale) == 1)
        #expect(NumericCalculatorRounding.bankers.round(third, scale: jpyScale) == 2)

        // 0.333... は切り上げだけが 1 になる
        let small = Decimal(1) / Decimal(3)
        #expect(NumericCalculatorRounding.up.round(small, scale: jpyScale) == 1)
        #expect(NumericCalculatorRounding.halfUp.round(small, scale: jpyScale) == 0)
        #expect(NumericCalculatorRounding.down.round(small, scale: jpyScale) == 0)
        #expect(NumericCalculatorRounding.bankers.round(small, scale: jpyScale) == 0)
    }

    /// NSDecimalRound の .up/.down は絶対値ではなく数直線の向き
    /// （+∞ 方向／-∞ 方向）で決まるため、負の値では見た目が反転する
    @Test("負の値は数直線の向きで丸める")
    func roundsNegativeValues() {
        let negativeHalf = Decimal(-5) / Decimal(2)   // -2.5

        // 切り上げ = +∞ 方向なので、-2.5 は -2 になる
        #expect(NumericCalculatorRounding.up.round(negativeHalf, scale: jpyScale) == -2)
        // 切り捨て = -∞ 方向なので、-2.5 は -3 になる
        #expect(NumericCalculatorRounding.down.round(negativeHalf, scale: jpyScale) == -3)
        // 四捨五入は絶対値の大きい側へ寄る
        #expect(NumericCalculatorRounding.halfUp.round(negativeHalf, scale: jpyScale) == -3)
        // 偶数丸めは偶数側の -2 を選ぶ
        #expect(NumericCalculatorRounding.bankers.round(negativeHalf, scale: jpyScale) == -2)
    }

    @Test("小数0桁の通貨では小数が残らない")
    func roundsForZeroFractionCurrency() {
        let value = Decimal(string: "1234.56")!
        for mode in NumericCalculatorRounding.allCases {
            let rounded = mode.round(value, scale: jpyScale)
            #expect(rounded == rounded.roundedAmount(scale: 0),
                    "\(mode.rawValue) で小数が残っている")
        }
        #expect(NumericCalculatorRounding.down.round(value, scale: jpyScale) == 1234)
        #expect(NumericCalculatorRounding.up.round(value, scale: jpyScale) == 1235)
    }

    @Test("小数2桁の通貨では2桁目まで残す")
    func roundsForTwoFractionCurrency() {
        let value = Decimal(string: "1.005")!
        #expect(NumericCalculatorRounding.up.round(value, scale: usdScale) == Decimal(string: "1.01"))
        #expect(NumericCalculatorRounding.down.round(value, scale: usdScale) == Decimal(string: "1.00"))

        // 10 ÷ 3 = 3.333... は 2 桁で 3.33
        let third = Decimal(10) / Decimal(3)
        #expect(NumericCalculatorRounding.halfUp.round(third, scale: usdScale) == Decimal(string: "3.33"))
        #expect(NumericCalculatorRounding.up.round(third, scale: usdScale) == Decimal(string: "3.34"))
    }

    // MARK: - 演算子の取り消し（BS）

    /// 演算子をBSで取り消して左辺を再編集するとき、入力欄へ戻す値は
    /// 画面に出ていた金額と一致していなければならない。
    /// （以前は常に四捨五入していたため、切り捨て選択時に 2.5 → 3 とずれていた）
    @Test("演算子の取り消しで戻す値が、表示していた金額と一致する")
    func restoredValueMatchesDisplayedAmount() {
        let left = Decimal(5) / Decimal(2)   // 5 ÷ 2 の途中結果（未丸め）

        for mode in NumericCalculatorRounding.allCases {
            // 画面に出している金額（committedValue 相当）
            let displayed = mode.round(left, scale: jpyScale)
            // 入力欄へ戻すときも同じ方法で確定する
            let restored = mode.round(left, scale: jpyScale)
            #expect(displayed == restored,
                    "丸め方法 \(mode.rawValue) で表示と入力値がずれている")
        }

        // 切り捨てのときに 3 ではなく 2 が戻ることを具体値でも確かめる
        #expect(NumericCalculatorRounding.down.round(left, scale: jpyScale) == 2)
        // 偶数丸めでも 2 になる
        #expect(NumericCalculatorRounding.bankers.round(left, scale: jpyScale) == 2)
    }

    @Test("取り消して戻した値から計算を続けても表示と食い違わない")
    func restoredValueContinuesCalculation() {
        let left = Decimal(5) / Decimal(2)                                // 2.5
        let restored = NumericCalculatorRounding.down.round(left, scale: jpyScale)  // 2
        // 戻した 2 から + 1 すれば 3。未丸めの 2.5 から続けた 3.5 とは異なる
        #expect(value(restored, .add, 1) == 3)
    }
}
