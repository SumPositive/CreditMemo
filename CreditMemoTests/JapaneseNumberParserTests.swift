import Foundation
import Testing
@testable import CreditMemo

struct JapaneseNumberParserTests {
    // MARK: - 半角数字

    @Test("半角数字と桁区切り・円をそのまま読む", arguments: [
        ("1500", Decimal(1_500)),
        ("1,500", Decimal(1_500)),
        ("1500円", Decimal(1_500)),
        ("1,500円", Decimal(1_500)),
    ])
    func parsesArabicAmounts(input: String, expected: Decimal) {
        #expect(JapaneseNumberParser.firstAmount(in: input)?.value == expected)
    }

    // MARK: - 単位付き

    @Test("単位付きの半角数字を読む", arguments: [
        ("1万", Decimal(10_000)),
        ("2千", Decimal(2_000)),
        ("1.5万", Decimal(15_000)),
    ])
    func parsesArabicWithUnit(input: String, expected: Decimal) {
        #expect(JapaneseNumberParser.firstAmount(in: input)?.value == expected)
    }

    /// 修正前は "1万" と "2千" が別々の金額になり、後勝ち採用で 2,000 円になっていた
    @Test("単位が連なる 1万2千 を 1 つの金額として読む", arguments: [
        ("1万2千", Decimal(12_000)),
        ("1万2千円", Decimal(12_000)),
        ("1万2千3百", Decimal(12_300)),
    ])
    func parsesChainedUnitsAsSingleAmount(input: String, expected: Decimal) {
        let all = JapaneseNumberParser.allAmounts(in: input)
        // 分割されていないこと自体を検証する（後勝ち採用でも同じ値になる）
        #expect(all.count == 1)
        #expect(all.last?.value == expected)
    }

    // MARK: - 漢数字

    @Test("純漢数字を読む", arguments: [
        ("千五百", Decimal(1_500)),
        ("一万二千", Decimal(12_000)),
        ("一万二千円", Decimal(12_000)),
        ("十万", Decimal(100_000)),
        ("十二万三千四百五十六", Decimal(123_456)),
    ])
    func parsesKanjiAmounts(input: String, expected: Decimal) {
        let all = JapaneseNumberParser.allAmounts(in: input)
        #expect(all.count == 1)
        #expect(all.last?.value == expected)
    }

    /// 漢数字（上位桁）と半角数字（下位桁）の混在も 1 つの金額にまとめる
    @Test("一万2千のような混在表記を 1 つの金額として読む")
    func parsesMixedKanjiAndArabic() {
        let all = JapaneseNumberParser.allAmounts(in: "一万2千")
        #expect(all.count == 1)
        #expect(all.last?.value == Decimal(12_000))
    }

    // MARK: - 複数金額

    @Test("数値が複数ある文章では、出現順に全件返す")
    func returnsAllAmountsInOrder() {
        let all = JapaneseNumberParser.allAmounts(in: "3000円と1500円")
        #expect(all.map(\.value) == [Decimal(3_000), Decimal(1_500)])
    }

    @Test("文中に混ざった漢数字と半角数字も出現順に全件返す")
    func returnsMixedAmountsInOrder() {
        let all = JapaneseNumberParser.allAmounts(in: "三千円のコーヒーと5000円の本")
        #expect(all.map(\.value) == [Decimal(3_000), Decimal(5_000)])
    }

    @Test("文中に埋もれた金額も拾う")
    func parsesAmountInsideSentence() {
        #expect(JapaneseNumberParser.firstAmount(in: "スーパーで1万2千円")?.value == Decimal(12_000))
    }

    // MARK: - 金額なし

    @Test("金額が無い、または 0 の場合は何も返さない", arguments: ["", "abc", "コンビニ", "0", "0円"])
    func returnsNothingWithoutAmount(input: String) {
        #expect(JapaneseNumberParser.allAmounts(in: input).isEmpty)
        #expect(JapaneseNumberParser.firstAmount(in: input) == nil)
    }

    // MARK: - range

    @Test("返す range は金額表記全体を指し、単位や円も含む")
    func rangeCoversWholeAmountExpression() throws {
        let text = "スーパーで1万2千円"
        let first = try #require(JapaneseNumberParser.firstAmount(in: text))
        #expect(String(text[first.range]) == "1万2千円")
    }
}
