import Foundation
import SwiftData
import Testing
@testable import CreditMemo

@MainActor
struct VoiceInputParserTests {
    private static let ja = Locale(identifier: "ja_JP")
    private static let en = Locale(identifier: "en_US")

    // MARK: - 金額

    @Test("ja では漢数字・単位付き表記も金額として解釈する", arguments: [
        ("1500円", Decimal(1_500)),
        ("1,500円", Decimal(1_500)),
        ("1.5万", Decimal(15_000)),
        ("1万2千", Decimal(12_000)),
        ("一万二千", Decimal(12_000)),
        ("一万2千", Decimal(12_000)),
        ("十二万三千四百五十六", Decimal(123_456)),
    ])
    func parsesJapaneseAmount(input: String, expected: Decimal) {
        let result = VoiceInputParser.parseAmountAndLabel(input, locale: Self.ja)
        #expect(result.amount == expected)
    }

    /// normalize が全角 ASCII を半角化するので、全角数字でも金額になる
    @Test("全角数字も金額として解釈する", arguments: [
        ("１５００", Decimal(1_500)),
        ("１，５００円", Decimal(1_500)),
        ("１万２千", Decimal(12_000)),
    ])
    func parsesFullwidthAmount(input: String, expected: Decimal) {
        let result = VoiceInputParser.parseAmountAndLabel(input, locale: Self.ja)
        #expect(result.amount == expected)
    }

    @Test("数値が複数あれば最後を金額に採用する")
    func adoptsLastAmountAmongMany() {
        let result = VoiceInputParser.parseAmountAndLabel("3000円と1500円", locale: Self.ja)
        #expect(result.amount == Decimal(1_500))
    }

    @Test("金額が無ければ amount は nil のまま")
    func leavesAmountNilWithoutNumber() {
        let result = VoiceInputParser.parseAmountAndLabel("コンビニ", locale: Self.ja)
        #expect(result.amount == nil)
    }

    // MARK: - ラベル

    @Test("金額を除いた部分がラベルになる")
    func extractsLabelBesideAmount() {
        let result = VoiceInputParser.parseAmountAndLabel("スーパーで1万2千円", locale: Self.ja)
        #expect(result.amount == Decimal(12_000))
        // 金額表記はラベル側に残らない（末尾の助詞は現状そのまま残る）
        #expect(result.label == "スーパーで")
    }

    @Test("金額だけの発話ならラベルは付かない")
    func leavesLabelNilForAmountOnly() {
        let result = VoiceInputParser.parseAmountAndLabel("1500円", locale: Self.ja)
        #expect(result.amount == Decimal(1_500))
        #expect(result.label == nil)
    }

    @Test("金額が無ければ全文がラベル候補になる")
    func usesWholeTextAsLabelWithoutAmount() {
        let result = VoiceInputParser.parseAmountAndLabel("コンビニ", locale: Self.ja)
        #expect(result.label == "コンビニ")
    }

    @Test("hasAnyField は金額・ラベルのどちらか有れば true")
    func reportsHasAnyField() {
        #expect(VoiceInputParser.parseAmountAndLabel("1500円", locale: Self.ja).hasAnyField)
        #expect(VoiceInputParser.parseAmountAndLabel("コンビニ", locale: Self.ja).hasAnyField)
        #expect(!VoiceInputParser.parseAmountAndLabel("", locale: Self.ja).hasAnyField)
    }

    // MARK: - 非 ja ロケール

    @Test("en では半角数字のみ解釈し、漢数字は金額にしない")
    func parsesArabicOnlyForEnglishLocale() {
        #expect(VoiceInputParser.parseAmountAndLabel("15 dollars", locale: Self.en).amount == Decimal(15))
        #expect(VoiceInputParser.parseAmountAndLabel("$1,500", locale: Self.en).amount == Decimal(1_500))
        #expect(VoiceInputParser.parseAmountAndLabel("一万二千", locale: Self.en).amount == nil)
    }

    @Test("en では単位付き漢字を金額に含めない（1万 は 1 と読む）")
    func ignoresKanjiUnitForEnglishLocale() {
        #expect(VoiceInputParser.parseAmountAndLabel("1万", locale: Self.en).amount == Decimal(1))
    }

    // MARK: - カード判定

    @Test("カード名が含まれていれば決済手段を特定する")
    func matchesCardByName() throws {
        let context = try TestStore.makeContext()
        let card = TestFixtures.makeCard(name: "楽天カード", in: context)

        let result = VoiceInputParser.parseCard("楽天カードで1500円", cards: [card])
        #expect(result.card?.id == card.id)
        #expect(result.matchedToken == "楽天カード")
        #expect(result.matchedWasExistingAlias == false)
    }

    @Test("カード名が無ければ手段は nil のまま")
    func leavesCardNilWithoutMatch() throws {
        let context = try TestStore.makeContext()
        let card = TestFixtures.makeCard(name: "楽天カード", in: context)

        let result = VoiceInputParser.parseCard("コンビニで1500円", cards: [card])
        #expect(result.card == nil)
        #expect(result.matchedToken == nil)
    }

    @Test("省略形の発話でもカード名の部分一致で特定する")
    func matchesCardByAbbreviation() throws {
        let context = try TestStore.makeContext()
        let card = TestFixtures.makeCard(name: "楽天カード", in: context)

        let result = VoiceInputParser.parseCard("楽天", cards: [card])
        #expect(result.card?.id == card.id)
    }
}
