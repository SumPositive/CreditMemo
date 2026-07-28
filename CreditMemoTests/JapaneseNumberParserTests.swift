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

    /// 修正前は "1万" と "2千" が別々の金額になり、後勝ち採用で 2,000 円になっていた。
    /// 十の位・一の位まで続く形も 1 つにまとまる（12,300 / 4 / 10 に割れない）
    @Test("単位が連なる表記を 1 つの金額として読む", arguments: [
        ("1万2千", Decimal(12_000)),
        ("1万2千円", Decimal(12_000)),
        ("1万2千3百", Decimal(12_300)),
        ("1万2千3百4十", Decimal(12_340)),
        ("1万2千3百4十5", Decimal(12_345)),
        // 上位桁が単位付き、下位桁が単位なしの数字で続く形
        ("1万2千340", Decimal(12_340)),
        ("1万2340", Decimal(12_340)),
    ])
    func parsesChainedUnitsAsSingleAmount(input: String, expected: Decimal) {
        let all = JapaneseNumberParser.allAmounts(in: input)
        // 分割されていないこと自体を検証する（後勝ち採用でも同じ値になる）
        #expect(all.count == 1)
        #expect(all.last?.value == expected)
    }

    /// 漢数字と半角数字がどの桁で混ざっても、位取りは同じに解釈される
    @Test("漢数字と半角数字の混在も 1 つの金額として読む", arguments: [
        ("一万2千3百4十", Decimal(12_340)),
        ("一万2千", Decimal(12_000)),
        ("1万二千", Decimal(12_000)),
        ("一億2千万", Decimal(120_000_000)),
    ])
    func parsesMixedKanjiArabicNotation(input: String, expected: Decimal) {
        let all = JapaneseNumberParser.allAmounts(in: input)
        #expect(all.count == 1)
        #expect(all.last?.value == expected)
    }

    /// 億を含む大きい単位も位取りで解釈する
    @Test("億の位取りを解釈する", arguments: [
        ("一億", Decimal(100_000_000)),
        ("1億", Decimal(100_000_000)),
        ("一億二千万", Decimal(120_000_000)),
        ("3億5千万", Decimal(350_000_000)),
    ])
    func parsesOkuUnit(input: String, expected: Decimal) {
        #expect(JapaneseNumberParser.firstAmount(in: input)?.value == expected)
    }

    /// 単位を挟まずに数が連続する並びは位取りとして解釈できないので読み取らない。
    /// 黙って足し合わせる／上書きすると誤った金額になる
    @Test("位取りとして解釈できない数字の並びは読み取らない", arguments: [
        "一二三",      // 単位なしの漢数字列
        "二〇二四",    // 年などの数字列表記
        "1..5",        // 壊れた小数
    ])
    func rejectsUnparsableDigitSequences(input: String) {
        #expect(JapaneseNumberParser.allAmounts(in: input).isEmpty)
    }

    /// 単位の間の空白は 1 つの金額として跨ぐ（"1万 2千" が 1万 と 2千 に割れない）
    @Test("単位の間に空白があっても 1 つの金額として読む", arguments: [
        ("1万 2千", Decimal(12_000)),
        ("1万 2千 3百", Decimal(12_300)),
    ])
    func joinsAmountAcrossSpacesBetweenUnits(input: String, expected: Decimal) {
        let all = JapaneseNumberParser.allAmounts(in: input)
        #expect(all.count == 1)
        #expect(all.last?.value == expected)
    }

    /// 単位を伴わない数字が空白だけで並ぶ形は、1つの金額とも複数の金額とも決められない。
    /// 誤った値を採用するより読み取らない（"1500円 2000円" のように単位があれば読む）
    @Test("単位なしの数字が空白で並ぶ場合は読み取らない")
    func rejectsBareSpaceSeparatedNumbers() {
        #expect(JapaneseNumberParser.allAmounts(in: "1500 2000").isEmpty)
        // 単位（円）があれば、それぞれ別の金額として読む
        #expect(JapaneseNumberParser.allAmounts(in: "1500円 2000円").map(\.value)
                == [Decimal(1_500), Decimal(2_000)])
    }

    // MARK: - 店名など、金額でない漢数字

    /// 漢数字だけの並びに普通の文字が続く形は、店名・地名の一部として扱う。
    /// 金額を誤るだけでなく、ラベルからも先頭文字が欠けてしまう
    /// （"一蘭" が金額1＋ラベル"蘭" になっていた）
    @Test("数字を含む店名・地名を金額として読み取らない", arguments: [
        "一蘭", "三井住友", "万代", "千疋屋", "三丁目",
        // 実在の銀行名。位取りとして解釈できてしまう並び
        "七十七銀行", "八十二銀行", "十六銀行", "百五銀行",
    ])
    func doesNotReadNumericStoreNamesAsAmount(input: String) {
        #expect(JapaneseNumberParser.allAmounts(in: input).isEmpty)
    }

    /// 通貨単位が続く場合は 1 文字でも金額として読む（"千円"）
    @Test("通貨単位が続けば金額として読む", arguments: [
        ("千円", Decimal(1_000)),
        ("万円", Decimal(10_000)),
        ("三千円", Decimal(3_000)),
    ])
    func readsAmountWhenCurrencyUnitFollows(input: String, expected: Decimal) {
        #expect(JapaneseNumberParser.firstAmount(in: input)?.value == expected)
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
