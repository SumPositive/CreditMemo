import Foundation
import SwiftData
import Testing
@testable import CreditMemo

@MainActor
struct VoiceInputParserTests {
    private static let ja = Locale(identifier: "ja_JP")
    private static let en = Locale(identifier: "en_US")
    private static let de = Locale(identifier: "de_DE")
    private static let ko = Locale(identifier: "ko_KR")
    private static let zhHant = Locale(identifier: "zh_Hant_TW")

    // MARK: - 金額

    @Test("ja では漢数字・単位付き表記も金額として解釈する", arguments: [
        ("1500円", Decimal(1_500)),
        ("1,500円", Decimal(1_500)),
        ("1.5万", Decimal(15_000)),
        ("1万2千", Decimal(12_000)),
        ("一万二千", Decimal(12_000)),
        ("一万2千", Decimal(12_000)),
        ("十二万三千四百五十六", Decimal(123_456)),
        // 十の位・一の位まで続く混在表記（下位桁だけ採用されないこと）
        ("1万2千3百4十", Decimal(12_340)),
        ("一万2千3百4十", Decimal(12_340)),
        ("1万2千340", Decimal(12_340)),
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
        ("１万２千３百４十", Decimal(12_340)),
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

    @Test("間を置いてラベルを言い直したら最後のラベルを採用する")
    func adoptsRestatedLabelAfterPause() {
        let result = VoiceInputParser.parseAmountAndLabel(
            "1500円 コンビニ スーパー",
            pauseSeparatedTexts: ["1500円 コンビニ", "スーパー"],
            locale: Self.ja
        )
        #expect(result.amount == Decimal(1_500))
        #expect(result.label == "スーパー")
    }

    @Test("金額だけを言い直しても先のラベルを保持する")
    func keepsLabelWhenOnlyAmountIsRestated() {
        let result = VoiceInputParser.parseAmountAndLabel(
            "1500円 コンビニ 2000円",
            pauseSeparatedTexts: ["1500円 コンビニ", "2000円"],
            locale: Self.ja
        )
        #expect(result.amount == Decimal(2_000))
        #expect(result.label == "コンビニ")
    }

    @Test("短い語間は同じ発話、長い無音は言い直しへ分割する")
    func splitsTranscriptAtRestatementPause() {
        let text = "1500円 コンビニ スーパー"
        let source = text as NSString
        let segments = [
            SpeechTranscriptSegmenter.Segment(
                range: source.range(of: "1500円"),
                timestamp: 0,
                duration: 0.5
            ),
            SpeechTranscriptSegmenter.Segment(
                range: source.range(of: "コンビニ"),
                timestamp: 0.7,
                duration: 0.5
            ),
            SpeechTranscriptSegmenter.Segment(
                range: source.range(of: "スーパー"),
                timestamp: 2.0,
                duration: 0.5
            ),
        ]

        let results = SpeechTranscriptSegmenter.split(text, segments: segments)

        #expect(results == ["1500円 コンビニ", "スーパー"])
    }

    /// 言い直しで置く間は 0.4〜0.6 秒程度になる。
    /// ここで分割されないと "スーパー カフェ" が 1 つのラベルへ連結され、
    /// 言い換えたつもりが追記になってしまう
    @Test("言い直しの短い間でも発話を分割する", arguments: [0.45, 0.6, 1.0])
    func splitsAtShortRestatementPause(gap: TimeInterval) {
        let text = "スーパー カフェ"
        let source = text as NSString
        let segments = [
            SpeechTranscriptSegmenter.Segment(
                range: source.range(of: "スーパー"),
                timestamp: 0,
                duration: 0.35
            ),
            SpeechTranscriptSegmenter.Segment(
                range: source.range(of: "カフェ"),
                timestamp: 0.35 + gap,
                duration: 0.35
            ),
        ]

        #expect(SpeechTranscriptSegmenter.split(text, segments: segments) == ["スーパー", "カフェ"])
    }

    /// 部分認識では timestamp / duration が全て 0 で届くことがある。
    /// その状態を「語間 0 秒」と誤解して連結し続けないよう、
    /// タイムスタンプが使えるかを呼び出し側が判定できる必要がある
    @Test("タイムスタンプが全て 0 なら使用不可と判定する")
    func detectsUnusableTimestamps() {
        let text = "スーパー カフェ"
        let source = text as NSString
        let zeroSegments = [
            SpeechTranscriptSegmenter.Segment(
                range: source.range(of: "スーパー"), timestamp: 0, duration: 0
            ),
            SpeechTranscriptSegmenter.Segment(
                range: source.range(of: "カフェ"), timestamp: 0, duration: 0
            ),
        ]
        #expect(!SpeechTranscriptSegmenter.hasUsableTimestamps(zeroSegments))
        // タイムスタンプが 0 のままでは、どれだけ間を置いても分割できない
        #expect(SpeechTranscriptSegmenter.split(text, segments: zeroSegments) == ["スーパー カフェ"])

        let timedSegments = [
            SpeechTranscriptSegmenter.Segment(
                range: source.range(of: "スーパー"), timestamp: 0, duration: 0.35
            ),
            SpeechTranscriptSegmenter.Segment(
                range: source.range(of: "カフェ"), timestamp: 1.0, duration: 0.35
            ),
        ]
        #expect(SpeechTranscriptSegmenter.hasUsableTimestamps(timedSegments))
    }

    // MARK: - 実時間ベースの分割（タイムスタンプが使えないとき）

    /// 認識は "食" → "食費" のように語の途中でも伸びる。
    /// 文字が増えただけで区切ると単語が割れてしまう
    @Test("認識途中で間が空いても単語を割らない")
    func doesNotSplitInsideWord() {
        // 語の途中で間が空くケース。文字は増えるが新しい語ではない
        #expect(phrases(from: [("食", 0.0), ("食費", 0.5)]) == ["食費"])
        #expect(phrases(from: [("スー", 0.0), ("スーパー", 0.6)]) == ["スーパー"])
        #expect(
            phrases(from: [("2860", 0.0), ("2860タ", 0.4), ("2860タクシー", 0.4)])
                == ["2860タクシー"]
        )
    }

    /// 認識更新の並びを実時間分割へ通し、区切られた発話を返す
    private func phrases(from updates: [(text: String, gap: TimeInterval)]) -> [String] {
        var splitter = SpeechTranscriptSegmenter.WallClockSplitter()
        var now = Date()
        var result: [String] = []
        for update in updates {
            now = now.addingTimeInterval(update.gap)
            result = splitter.append(update.text, at: now)
        }
        return result
    }

    /// 新しい語（空白を挟んで足される）は、間が空いていれば別の発話にする
    @Test("間を置いて新しい語を言えば発話を分ける")
    func splitsWhenNewWordFollowsPause() {
        #expect(
            phrases(from: [
                ("1500円", 0.0), ("1500円 スーパー", 0.2), ("1500円 スーパー カフェ", 1.0),
            ]) == ["1500円 スーパー", "カフェ"]
        )
        // ガイド文の例（金額と店名を続けて言う）は、金額とラベルに分かれる
        #expect(
            phrases(from: [
                ("960円", 0.0), ("960円 食", 0.5), ("960円 食費", 0.5),
            ]) == ["960円", "食費"]
        )
    }

    /// 語間が短ければ、間を置いていないので 1 つの発話のまま
    @Test("短い語間では発話を分けない")
    func keepsPhraseWhenGapIsShort() {
        #expect(
            phrases(from: [
                ("1500円", 0.0), ("1500円 スーパー", 0.15), ("1500円 スーパー マーケット", 0.15),
            ]) == ["1500円 スーパー マーケット"]
        )
    }

    /// 聞き取りを開始し直したら状態を持ち越さない
    @Test("reset で区切り状態を捨てる")
    func resetClearsSplitterState() {
        var splitter = SpeechTranscriptSegmenter.WallClockSplitter()
        var now = Date()
        _ = splitter.append("スーパー", at: now)
        now = now.addingTimeInterval(1.0)
        _ = splitter.append("スーパー カフェ", at: now)

        splitter.reset()
        #expect(splitter.append("コンビニ", at: now) == ["コンビニ"])
    }

    /// 一続きの店名（語間はごく短い）は分割しない。
    /// 分割してしまうと "スーパー マーケット" が "マーケット" だけになる
    @Test("一続きの発話は語間で分割しない", arguments: [0.05, 0.1, 0.2])
    func keepsContinuousSpeechTogether(gap: TimeInterval) {
        let text = "スーパー マーケット"
        let source = text as NSString
        let segments = [
            SpeechTranscriptSegmenter.Segment(
                range: source.range(of: "スーパー"),
                timestamp: 0,
                duration: 0.35
            ),
            SpeechTranscriptSegmenter.Segment(
                range: source.range(of: "マーケット"),
                timestamp: 0.35 + gap,
                duration: 0.35
            ),
        ]

        #expect(SpeechTranscriptSegmenter.split(text, segments: segments) == ["スーパー マーケット"])
    }

    /// 間を置いて言い換えたら、追記ではなく上書きになる
    @Test("間を置いた言い換えでラベルが上書きされる")
    func restatedLabelOverwritesPrevious() {
        let text = "1500円 スーパー カフェ"
        let source = text as NSString
        let segments = [
            SpeechTranscriptSegmenter.Segment(
                range: source.range(of: "1500円"),
                timestamp: 0,
                duration: 0.35
            ),
            SpeechTranscriptSegmenter.Segment(
                range: source.range(of: "スーパー"),
                timestamp: 0.45,
                duration: 0.35
            ),
            // 言い直しの間（0.5 秒）
            SpeechTranscriptSegmenter.Segment(
                range: source.range(of: "カフェ"),
                timestamp: 1.3,
                duration: 0.35
            ),
        ]
        let pauseTexts = SpeechTranscriptSegmenter.split(text, segments: segments)
        let sections = VoiceInputPhaseSplitter.split(pauseTexts)
        let result = VoiceInputParser.parseAmountAndLabel(
            sections.amountLabelTexts.joined(separator: " "),
            pauseSeparatedTexts: sections.amountLabelTexts,
            locale: Self.ja
        )

        #expect(result.amount == Decimal(1_500))
        // 追記（"スーパー カフェ"）ではなく、言い直した方だけを採る
        #expect(result.label == "カフェ")
    }

    @Test("手段入力後にラベルはと言えばラベルへ戻る")
    func returnsToLabelPhaseAfterCard() {
        let sections = VoiceInputPhaseSplitter.split([
            "1500円 コンビニ 手段は 楽天カード ラベルは スーパー",
        ])
        let result = VoiceInputParser.parseAmountAndLabel(
            sections.amountLabelTexts.joined(separator: " "),
            pauseSeparatedTexts: sections.amountLabelTexts,
            locale: Self.ja
        )

        #expect(sections.amountLabelTexts == ["1500円 コンビニ", "スーパー"])
        #expect(sections.cardTexts == ["楽天カード"])
        #expect(!sections.endsInCardPhase)
        #expect(result.amount == Decimal(1_500))
        #expect(result.label == "スーパー")
    }

    /// 助詞を省いた「ラベル」だけでもラベルへ戻る。
    /// 区切り記号が残っても、最終的なラベルからは取り除かれる
    @Test("ラベルとだけ言ってもラベルへ戻る", arguments: [
        "1500円 手段は 楽天カード ラベル スーパー",
        "1500円 手段は 楽天カード ラベル、スーパー",
    ])
    func returnsToLabelPhaseWithBareKeyword(text: String) {
        let sections = VoiceInputPhaseSplitter.split([text])
        #expect(sections.cardTexts == ["楽天カード"])
        #expect(!sections.endsInCardPhase)

        let result = VoiceInputParser.parseAmountAndLabel(
            sections.amountLabelTexts.joined(separator: " "),
            pauseSeparatedTexts: sections.amountLabelTexts,
            locale: Self.ja
        )
        #expect(result.amount == Decimal(1_500))
        #expect(result.label == "スーパー")
    }

    /// 語中に含まれる「ラベル」はキーワードにしない（"トラベル" が壊れない）
    @Test("語中のラベルはキーワードとして扱わない", arguments: [
        "トラベル 1500円", "手段は VISA トラベル",
    ])
    func doesNotTreatEmbeddedLabelWordAsKeyword(text: String) {
        let sections = VoiceInputPhaseSplitter.split([text])
        // "トラベル" が分割されず、そのまま残る
        let joined = (sections.amountLabelTexts + sections.cardTexts).joined(separator: " ")
        #expect(joined.contains("トラベル"))
    }

    /// 発話の区切り（ポーズ）で手段の入力は終わり、以降はラベル扱いに戻る。
    /// 「ラベルは」と言わなくても、金額と手段以外はラベルとして拾う
    @Test("ポーズを挟めば手段の後はラベルへ戻る")
    func returnsToLabelPhaseAfterPause() {
        let sections = VoiceInputPhaseSplitter.split([
            "1500円 手段は 楽天カード",
            "スーパー",
        ])
        #expect(sections.amountLabelTexts == ["1500円", "スーパー"])
        #expect(sections.cardTexts == ["楽天カード"])
        #expect(!sections.endsInCardPhase)
    }

    /// 手段の後に言った金額まで手段扱いにしない
    @Test("手段の後の金額はラベル側で解釈する")
    func amountAfterCardPhaseGoesToAmountSection() {
        let sections = VoiceInputPhaseSplitter.split([
            "手段は 楽天カード",
            "コンビニ",
            "500円",
        ])
        #expect(sections.amountLabelTexts == ["コンビニ", "500円"])
        #expect(sections.cardTexts == ["楽天カード"])
    }

    @Test("ラベルへ戻った後に手段はと言えば再び手段へ進む")
    func returnsToCardPhaseAgain() {
        let sections = VoiceInputPhaseSplitter.split([
            "1500円 コンビニ 手段は 楽天カード",
            "ラベルは スーパー",
            "手段は ビザカード",
        ])

        #expect(sections.amountLabelTexts == ["1500円 コンビニ", "スーパー"])
        #expect(sections.cardTexts == ["楽天カード", "ビザカード"])
        #expect(sections.endsInCardPhase)
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

    /// 数字を含む店名は金額にせず、名称をそのままラベルに残す。
    /// 修正前は "一蘭" が金額1＋ラベル"蘭" になり、店名が壊れていた
    @Test("数字を含む店名は金額にせずラベルに残す", arguments: [
        "一蘭", "三井住友", "万代", "千疋屋", "三丁目", "七十七銀行",
    ])
    func keepsNumericStoreNameAsLabel(name: String) {
        let result = VoiceInputParser.parseAmountAndLabel(name, locale: Self.ja)
        #expect(result.amount == nil)
        #expect(result.label == name)
    }

    // MARK: - 過去の決済ラベルによる保護

    /// 構造だけでは金額と区別できない店名（"三千屋" と "三千" は同じ形）でも、
    /// 過去の決済で実際に使っているラベルなら店名として扱う
    @Test("履歴にあるラベルと完全一致するなら金額にしない", arguments: [
        "三千屋", "七十七銀行", "一蘭", "万代", "千疋屋",
    ])
    func protectsKnownLabelAtPrefix(name: String) {
        let result = VoiceInputParser.parseAmountAndLabel(
            name, locale: Self.ja, knownLabels: [name]
        )
        #expect(result.amount == nil)
        #expect(result.label == name)
    }

    /// 一致したら認識テキストの断片ではなく、保存済みラベルの表記を採る。
    /// フィラーや助詞が落ちて、同じ店が常に同じラベルで記録される
    @Test("一致した履歴ラベルの表記を採用する", arguments: [
        ("三千屋 1500円", Decimal(1_500), "三千屋"),
        ("三千屋で三千円", Decimal(3_000), "三千屋"),
        ("えーと三千屋で1500円", Decimal(1_500), "三千屋"),
        ("七十七銀行で3000円", Decimal(3_000), "七十七銀行"),
        ("1500円 三千屋", Decimal(1_500), "三千屋"),
    ])
    func adoptsStoredLabelSpelling(
        input: String,
        expectedAmount: Decimal,
        expectedLabel: String
    ) {
        let result = VoiceInputParser.parseAmountAndLabel(
            input, locale: Self.ja, knownLabels: ["三千屋", "七十七銀行"]
        )
        #expect(result.amount == expectedAmount)
        #expect(result.label == expectedLabel)
    }

    /// 大小文字のゆれも保存済みの表記に揃う（同じ店が別ラベルにならない）
    @Test("大小文字のゆれを保存済み表記に正規化する", arguments: [
        "starbucksで500円", "STARBUCKSで500円",
    ])
    func normalizesCaseToStoredLabel(input: String) {
        let result = VoiceInputParser.parseAmountAndLabel(
            input, locale: Self.ja, knownLabels: ["Starbucks"]
        )
        #expect(result.amount == Decimal(500))
        #expect(result.label == "Starbucks")
    }

    /// 弱い部分一致（長い発話の中の短いラベル）では置き換えない。
    /// "コンビニ" の中の "ニ" で置き換わると、かえって不正確になる
    @Test("弱い部分一致では履歴ラベルを採用しない", arguments: [
        ("コンビニで1500円", ["ニ"], "コンビニで"),
        ("スーパーマーケットで1500円", ["パー"], "スーパーマーケットで"),
    ])
    func ignoresWeakPartialMatch(
        input: String,
        knownLabels: [String],
        expectedLabel: String
    ) {
        let result = VoiceInputParser.parseAmountAndLabel(
            input, locale: Self.ja, knownLabels: knownLabels
        )
        #expect(result.amount == Decimal(1_500))
        #expect(result.label == expectedLabel)
    }

    /// 一致の強さで順位付けする（完全一致 > 前方一致 > 部分一致、同種なら一致割合が高い方）
    @Test("より強く一致するラベルを優先する")
    func prefersStrongerLabelMatch() {
        // "三千" も "三千屋" も前方一致するが、一致割合の高い "三千屋" を採る
        let result = VoiceInputParser.parseAmountAndLabel(
            "三千屋で1500円", locale: Self.ja, knownLabels: ["三千", "三千屋"]
        )
        #expect(result.amount == Decimal(1_500))
        #expect(result.label == "三千屋")
    }

    /// 数値表記そのもののラベルを守ると、同じ金額を言えなくなるので対象外にする
    @Test("数値だけのラベルは保護しない", arguments: [
        ("1500円", ["1500"], Decimal(1_500)),
        ("三千円", ["三千"], Decimal(3_000)),
        ("一万二千円", ["一万"], Decimal(12_000)),
    ])
    func doesNotProtectPurelyNumericLabels(
        input: String,
        knownLabels: [String],
        expected: Decimal
    ) {
        let result = VoiceInputParser.parseAmountAndLabel(
            input, locale: Self.ja, knownLabels: knownLabels
        )
        #expect(result.amount == expected)
    }

    /// 履歴を渡さない既定の呼び出しは従来どおり動く
    @Test("履歴なしでも従来の判定で動く")
    func worksWithoutKnownLabels() {
        #expect(VoiceInputParser.parseAmountAndLabel("一蘭", locale: Self.ja).amount == nil)
        #expect(VoiceInputParser.parseAmountAndLabel("1500円 パン", locale: Self.ja).amount == Decimal(1_500))
    }

    /// 店名＋金額なら、金額を取りつつ店名も欠けさせない
    @Test("店名に数字が含まれても金額とラベルを両立する", arguments: [
        ("一蘭で1000円", Decimal(1_000), "一蘭で"),
        ("三井住友で1500円", Decimal(1_500), "三井住友で"),
        ("七十七銀行で3000円", Decimal(3_000), "七十七銀行で"),
        ("千疋屋 3000円", Decimal(3_000), "千疋屋"),
    ])
    func extractsAmountWithoutTruncatingStoreName(
        input: String,
        expectedAmount: Decimal,
        expectedLabel: String
    ) {
        let result = VoiceInputParser.parseAmountAndLabel(input, locale: Self.ja)
        #expect(result.amount == expectedAmount)
        #expect(result.label == expectedLabel)
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

    /// de は小数点「,」・桁区切り「.」で en と逆。記号を決め打ちすると
    /// "12,50"(=12.50) が 12 と 50 に割れ、後勝ち採用で 50 になってしまう
    @Test("de は小数点/桁区切りが逆でも正しく読む", arguments: [
        ("12,50", Decimal(string: "12.5")!),
        ("12,50 Euro", Decimal(string: "12.5")!),
        ("1.234,56", Decimal(string: "1234.56")!),
        ("1.500", Decimal(1_500)),
        ("1.234.567", Decimal(1_234_567)),
    ])
    func parsesGermanSeparators(input: String, expected: Decimal) {
        #expect(VoiceInputParser.parseAmountAndLabel(input, locale: Self.de).amount == expected)
    }

    /// 数値解釈は NumberFormatter に任せているので、ロケールの記法に合わない
    /// 表記は金額として採用しない（de に en 記法の "12.50" を渡しても誤読しない）
    @Test("ロケールの記法に合わない表記は金額にしない")
    func rejectsNotationForeignToLocale() {
        #expect(VoiceInputParser.parseAmountAndLabel("12.50", locale: Self.de).amount == nil)
        // 桁区切りの桁数が不正な表記も採用しない
        #expect(VoiceInputParser.parseAmountAndLabel("1,23", locale: Self.en).amount == nil)
    }

    /// generatesDecimalNumbers により Double を経由しないので、小数がそのまま保たれる
    @Test("小数の精度が Double 経由で失われない", arguments: [
        ("0.1", "0.1"), ("3.99", "3.99"), ("1,234.56", "1234.56"),
    ])
    func keepsDecimalPrecision(input: String, expected: String) {
        let amount = VoiceInputParser.parseAmountAndLabel(input, locale: Self.en).amount
        #expect(amount == Decimal(string: expected))
    }

    /// 複数の金額があるときは従来どおり最後を採用する（連結してしまわない）
    @Test("非 CJK でも複数金額は分けて最後を採用する")
    func stillSplitsMultipleAmountsInNonCJK() {
        #expect(VoiceInputParser.parseAmountAndLabel("$10 and $20", locale: Self.en).amount == Decimal(20))
        #expect(VoiceInputParser.parseAmountAndLabel("10 Euro und 20 Euro", locale: Self.de).amount == Decimal(20))
    }

    /// 通貨の目印が無い数字が空白だけで複数並ぶ形は、どれが金額とも決められない。
    /// 電話番号などを誤って金額にしないよう、全ロケールで読み取らない
    @Test("単位も区切りも無い数字の羅列は金額にしない", arguments: [
        "ja_JP", "ko_KR", "zh_Hant_TW", "en_US", "de_DE",
    ])
    func rejectsBareNumberSequences(localeID: String) {
        let locale = Locale(identifier: localeID)
        #expect(VoiceInputParser.parseAmountAndLabel("1500 2000", locale: locale).amount == nil)
        #expect(VoiceInputParser.parseAmountAndLabel("03 1234 5678", locale: locale).amount == nil)
    }

    /// 羅列でも「単独の数字」は従来どおり金額として読む
    @Test("単位が無くても単独の数字は金額として読む")
    func stillReadsSingleBareNumber() {
        #expect(VoiceInputParser.parseAmountAndLabel("1500", locale: Self.en).amount == Decimal(1_500))
        #expect(VoiceInputParser.parseAmountAndLabel("1500", locale: Self.ja).amount == Decimal(1_500))
        #expect(VoiceInputParser.parseAmountAndLabel("3.99", locale: Self.en).amount == Decimal(string: "3.99"))
    }

    /// 通貨の目印がある金額があれば、目印なしの数字はラベル側へ残す
    @Test("通貨の目印がある金額を優先し、他の数字はラベルに残す")
    func prefersAmountsWithCurrencyMarker() {
        let result = VoiceInputParser.parseAmountAndLabel("Store 24 12 dollars", locale: Self.en)
        #expect(result.amount == Decimal(12))
        // 金額でない 24 は店名の一部として残る
        #expect(result.label == "Store 24")
    }

    /// ko は만/천、zh-Hant は萬/千で位取りする。ja と同じ体系なので分割させない
    @Test("ko の 만/천 表記を 1 つの金額として読む", arguments: [
        ("1만2천", Decimal(12_000)),
        ("1만 2천원", Decimal(12_000)),
        ("3만5천원", Decimal(35_000)),
        ("1억2천만", Decimal(120_000_000)),
        ("12340", Decimal(12_340)),
    ])
    func parsesKoreanUnits(input: String, expected: Decimal) {
        let result = VoiceInputParser.parseAmountAndLabel(input, locale: Self.ko)
        #expect(result.amount == expected)
        // 通貨単位（원）がラベル側へ残らない
        #expect(result.label == nil)
    }

    @Test("zh-Hant の 萬/千 表記を 1 つの金額として読む", arguments: [
        ("1萬2千", Decimal(12_000)),
        ("一萬二千", Decimal(12_000)),
        ("3萬5千元", Decimal(35_000)),
        ("12340", Decimal(12_340)),
    ])
    func parsesTraditionalChineseUnits(input: String, expected: Decimal) {
        let result = VoiceInputParser.parseAmountAndLabel(input, locale: Self.zhHant)
        #expect(result.amount == expected)
        // 通貨単位（元）がラベル側へ残らない
        #expect(result.label == nil)
    }

    /// 通貨単位・通貨記号は金額の範囲に含め、ラベル側へ残さない。
    /// 残ると "円" や "¥" だけのラベルが保存されてしまう
    @Test("通貨単位・記号がラベルに残らない", arguments: [
        ("ja_JP", "1500円"), ("ja_JP", "1500 円"), ("ja_JP", "1万2千 円"),
        ("ja_JP", "¥1500"), ("ja_JP", "¥ 1500"),
        ("ko_KR", "1500원"), ("ko_KR", "1500 원"), ("ko_KR", "1만 2천원"), ("ko_KR", "₩1500"),
        ("zh_Hant_TW", "1500元"), ("zh_Hant_TW", "1500 元"), ("zh_Hant_TW", "3萬5千元"),
        ("zh_Hant_TW", "NT$1500"), ("zh_Hant_TW", "NT$ 1500"),
    ])
    func doesNotLeaveCurrencyMarkerInLabel(localeID: String, input: String) {
        let result = VoiceInputParser.parseAmountAndLabel(
            input, locale: Locale(identifier: localeID)
        )
        #expect(result.amount != nil)
        #expect(result.label == nil)
    }

    /// 通貨記号を取り込んでも、店名は欠けさせない
    @Test("通貨単位を含む発話でも店名は残る", arguments: [
        ("ja_JP", "コンビニ ¥1500", "コンビニ"),
        ("ja_JP", "スーパーで1500 円", "スーパーで"),
        ("ko_KR", "편의점 1500원", "편의점"),
        ("zh_Hant_TW", "超商 1500元", "超商"),
    ])
    func keepsStoreNameWithCurrencyMarker(
        localeID: String,
        input: String,
        expectedLabel: String
    ) {
        let result = VoiceInputParser.parseAmountAndLabel(
            input, locale: Locale(identifier: localeID)
        )
        #expect(result.amount == Decimal(1_500))
        #expect(result.label == expectedLabel)
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

    @Test("間を置いて手段を言い直したら最後の手段を採用する")
    func adoptsRestatedCardAfterPause() throws {
        let context = try TestStore.makeContext()
        let first = TestFixtures.makeCard(name: "楽天カード", in: context)
        let last = TestFixtures.makeCard(name: "ビザカード", in: context)

        let result = VoiceInputParser.parseCard(
            "楽天カード ビザカード",
            pauseSeparatedTexts: ["楽天カード", "ビザカード"],
            cards: [first, last]
        )

        #expect(result.card?.id == last.id)
        #expect(result.matchedToken == "ビザカード")
    }

    @Test("手段として特定できない言い直しでは先の手段を保持する")
    func keepsCardWhenRestatementDoesNotMatch() throws {
        let context = try TestStore.makeContext()
        let card = TestFixtures.makeCard(name: "楽天カード", in: context)

        let result = VoiceInputParser.parseCard(
            "楽天カード 別のカード",
            pauseSeparatedTexts: ["楽天カード", "別のカード"],
            cards: [card]
        )

        #expect(result.card?.id == card.id)
        #expect(result.matchedToken == "楽天カード")
    }
}
