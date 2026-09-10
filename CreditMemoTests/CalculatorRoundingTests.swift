import Foundation
import Testing
@testable import CreditMemo

/// テンキーの四則演算で使う丸め（NumericCalculatorRounding）。
///
/// 計算途中の値は丸めずに保持し、画面表示や確定時にだけ選択中の方法で丸める。
/// そのため「表示している金額」と「入力欄へ戻した値」がずれないことが重要になる。
struct CalculatorRoundingTests {

    /// 円のように小数を持たない通貨の桁数
    private let jpyScale = 0

    @Test("丸め方法ごとに、割り切れない結果を期待どおり丸める")
    func roundsAccordingToMode() {
        // 5 ÷ 2 = 2.5（ちょうど半分。方法ごとに結果が分かれる）
        let half = Decimal(5) / Decimal(2)
        #expect(NumericCalculatorRounding.up.round(half, scale: jpyScale) == 3)
        #expect(NumericCalculatorRounding.halfUp.round(half, scale: jpyScale) == 3)
        #expect(NumericCalculatorRounding.down.round(half, scale: jpyScale) == 2)

        // 5 ÷ 3 = 1.666...（半分未満ではないので四捨五入は切り上がる）
        let third = Decimal(5) / Decimal(3)
        #expect(NumericCalculatorRounding.up.round(third, scale: jpyScale) == 2)
        #expect(NumericCalculatorRounding.halfUp.round(third, scale: jpyScale) == 2)
        #expect(NumericCalculatorRounding.down.round(third, scale: jpyScale) == 1)

        // 1 ÷ 3 = 0.333...（切り上げだけが 1 になる）
        let small = Decimal(1) / Decimal(3)
        #expect(NumericCalculatorRounding.up.round(small, scale: jpyScale) == 1)
        #expect(NumericCalculatorRounding.halfUp.round(small, scale: jpyScale) == 0)
        #expect(NumericCalculatorRounding.down.round(small, scale: jpyScale) == 0)
    }

    /// 演算子をBSで取り消して左辺を再編集するとき、入力欄へ戻す値は
    /// 画面に出ていた金額と一致していなければならない。
    /// （以前は常に四捨五入していたため、切り捨て選択時に 2.5 → 3 とずれていた）
    @Test("演算子の取り消しで戻す値が、表示していた金額と一致する")
    func restoredValueMatchesDisplayedAmount() {
        let left = Decimal(5) / Decimal(2)   // 5 ÷ 2 の途中結果（未丸め）

        for mode in NumericCalculatorRounding.allCases {
            // 画面に出している金額
            let displayed = mode.round(left, scale: jpyScale)
            // 入力欄へ戻すときも同じ方法で確定する
            let restored = mode.round(left, scale: jpyScale)
            #expect(displayed == restored,
                    "丸め方法 \(mode.rawValue) で表示と入力値がずれている")
        }

        // 切り捨てのときに 3 ではなく 2 が戻ることを具体値でも確かめる
        #expect(NumericCalculatorRounding.down.round(left, scale: jpyScale) == 2)
    }

    /// 負の金額での丸め方向を明示しておく。
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
    }

    /// 小数を持つ通貨（2桁）でも、指定した桁で丸められること
    @Test("小数2桁の通貨でも指定桁で丸める")
    func roundsWithFractionDigits() {
        let value = Decimal(string: "1.005")!

        #expect(NumericCalculatorRounding.up.round(value, scale: 2) == Decimal(string: "1.01"))
        #expect(NumericCalculatorRounding.down.round(value, scale: 2) == Decimal(string: "1.00"))
    }
}
