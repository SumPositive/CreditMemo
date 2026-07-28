import Foundation
import NaturalLanguage

struct VoiceInputResult {
    var amount: Decimal?
    var card: E1card?
    /// 認識テキストから手段判定に使われたトークン（カード名・既存エイリアス・新しい発話のいずれか）
    var matchedToken: String?
    /// matchedToken が VoiceAliasStore に既存だったか
    var matchedWasExistingAlias: Bool = false
    var label: String?

    var hasAnyField: Bool { amount != nil || card != nil || label != nil }
}

/// 「手段は」「ラベルは」で音声入力の対象項目を切り替える
enum VoiceInputPhaseSplitter {
    private enum Phase {
        case amountLabel
        case card
    }

    struct Sections: Equatable {
        var amountLabelTexts: [String] = []
        var cardTexts: [String] = []
        var endsInCardPhase = false
    }

    /// ja: 決済手段は / 手段は
    /// en: payment method is / method is / card is
    static let cardKeywordPattern = #"(?i)((?:決済)?手段は|(?:payment )?method is|card is)"#
    /// 手段入力後にラベルへ戻るためのキーワード。
    /// 助詞を省いた「ラベル」「label」だけの言い方にも対応する。
    /// ただし語中の一致（"トラベル"）や別の助詞が続く形（"ラベルを変更"）は
    /// キーワードとして扱わない
    static let labelKeywordPattern =
        #"(?i)(ラベルは|(?<![^\s、。,.])ラベル(?![はをがのにでもへと])|label is|(?<![a-z])label(?![a-z]))"#

    /// 「手段は」の後は 1 区切り分だけを手段として扱い、その後はラベルへ戻る。
    ///
    /// 手段の発話は「手段は 楽天カード」で終わるのが普通なので、
    /// それ以降まで手段扱いを続けると、後から言った金額や店名まで
    /// 手段の候補になってしまう。
    /// 明示的に「ラベルは」と言わなくても、金額と手段以外はラベルとして拾う
    static func split(_ texts: [String]) -> Sections {
        var phase = Phase.amountLabel
        var sections = Sections()

        for (index, text) in texts.enumerated() {
            let isLastText = index == texts.count - 1
            var cursor = text.startIndex
            while cursor < text.endIndex {
                let remaining = cursor..<text.endIndex
                let cardRange = text.range(
                    of: cardKeywordPattern,
                    options: .regularExpression,
                    range: remaining
                )
                let labelRange = text.range(
                    of: labelKeywordPattern,
                    options: .regularExpression,
                    range: remaining
                )
                let next = nextKeyword(card: cardRange, label: labelRange)

                guard let next else {
                    append(String(text[cursor...]), to: phase, sections: &sections)
                    break
                }

                append(
                    String(text[cursor..<next.range.lowerBound]),
                    to: phase,
                    sections: &sections
                )
                phase = next.phase
                cursor = next.range.upperBound
            }
            // 発話の区切り（ポーズ）で手段の入力は終わったとみなし、ラベルへ戻す。
            // 最後の区切りはまだ発話が続く可能性があるので、手段のまま残す
            // （手段入力中であることを画面に出すために endsInCardPhase を使う）
            if case .card = phase, !isLastText {
                phase = .amountLabel
            }
        }
        if case .card = phase {
            sections.endsInCardPhase = true
        }
        return sections
    }

    static func firstCardKeyword(in text: String) -> Range<String.Index>? {
        text.range(of: cardKeywordPattern, options: .regularExpression)
    }

    private static func nextKeyword(
        card: Range<String.Index>?,
        label: Range<String.Index>?
    ) -> (range: Range<String.Index>, phase: Phase)? {
        if let card, let label {
            return card.lowerBound < label.lowerBound
                ? (card, .card)
                : (label, .amountLabel)
        }
        if let card { return (card, .card) }
        if let label { return (label, .amountLabel) }
        return nil
    }

    private static func append(
        _ rawText: String,
        to phase: Phase,
        sections: inout Sections
    ) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch phase {
        case .card:
            sections.cardTexts.append(text)
        case .amountLabel:
            sections.amountLabelTexts.append(text)
        }
    }
}

/// 音声認識テキストの解析
/// - parseAmountAndLabel: 数値を金額、それ以外をラベルにする
/// - parseCard: カード名／エイリアス／省略形を手段にする
/// 数値解析・助詞除去はロケール依存。ja-JP では漢数字と助詞も処理する
enum VoiceInputParser {
    /// 数値は金額、文字（名詞）はラベル
    /// 後勝ち上書き: 複数の数値があれば最後を金額、ラベルは数値間の区切りで分けた中の
    /// 最後の非空セグメントを採用する
    /// locale が ja-JP の時は漢数字・万・千・円も解釈する
    /// - knownLabels: 過去の決済に実在するラベル。ここに一致する部分は金額として切り出さない
    ///   （"一蘭" "三千屋" のように、数値表記と区別できない店名を守る）
    static func parseAmountAndLabel(
        _ rawText: String,
        locale: Locale = .current,
        knownLabels: [String]
    ) -> VoiceInputResult {
        parseAmountAndLabel(rawText, locale: locale, knownLabels: KnownLabels(knownLabels))
    }

    /// 前処理済みラベルを使う版。部分認識のたびに呼ぶ場合はこちらを使い、
    /// KnownLabels はシートを開く時点で 1 回だけ作る
    static func parseAmountAndLabel(
        _ rawText: String,
        locale: Locale = .current,
        knownLabels: KnownLabels = .none
    ) -> VoiceInputResult {
        let text = normalize(rawText)
        var result = VoiceInputResult()
        let isJa = locale.language.languageCode?.identifier == "ja"

        // 実在ラベルと重なる範囲は、数値表記として解釈しない
        let matchedLabel = bestKnownLabelMatch(in: text, knownLabels: knownLabels)
        let amounts = allAmounts(in: text, locale: locale)
            .filter { amount in matchedLabel.map { !$0.range.overlaps(amount.range) } ?? true }

        if let last = amounts.last {
            result.amount = last.value

            // 数値で区切られたセグメントを集めて、後ろから順に最初の非空を採用する
            var segments: [Substring] = []
            var cursor = text.startIndex
            for amt in amounts {
                segments.append(text[cursor..<amt.range.lowerBound])
                cursor = amt.range.upperBound
            }
            segments.append(text[cursor..<text.endIndex])

            for seg in segments.reversed() {
                let cleaned = cleanLabel(String(seg))
                let refined = refineLabel(cleaned, isJa: isJa)
                if !refined.isEmpty {
                    result.label = refined
                    break
                }
            }
        } else {
            // 数値が無ければ全文をラベル候補にする
            let cleaned = cleanLabel(text)
            let refined = refineLabel(cleaned, isJa: isJa)
            if !refined.isEmpty { result.label = refined }
        }

        // 履歴のラベルに一致したなら、認識テキストの断片ではなく保存済みの表記を採る。
        // "えーと三千屋で1500円" のフィラーや助詞を落として "三千屋" に揃える
        if let matchedLabel,
           !amounts.contains(where: { $0.range.overlaps(matchedLabel.range) }) {
            result.label = matchedLabel.label
        }
        return result
    }

    /// 間を置いた発話では、最後に言い直したラベルだけを採用する
    /// 金額だけの言い直しでは、それまでのラベルを消さない
    static func parseAmountAndLabel(
        _ rawText: String,
        pauseSeparatedTexts: [String],
        locale: Locale = .current,
        knownLabels: KnownLabels = .none
    ) -> VoiceInputResult {
        var result = parseAmountAndLabel(rawText, locale: locale, knownLabels: knownLabels)
        guard 1 < pauseSeparatedTexts.count else { return result }

        for text in pauseSeparatedTexts.reversed() {
            let restatement = parseAmountAndLabel(
                text,
                locale: locale,
                knownLabels: knownLabels
            )
            if let label = restatement.label {
                result.label = label
                break
            }
        }
        return result
    }

    /// 過去の決済に実在するラベルが本文の先頭に現れる範囲を返す。
    ///
    /// "一蘭" "千疋屋" のように数値表記と見分けのつかない店名は、
    /// 構造だけでは金額と区別できない（"三千" と "七十七" は同じ形）。
    /// 利用者が実際に使っているラベルなら店名と判断してよいので、
    /// その範囲を金額解析から除外する。
    ///
    /// 一致の強さで順位付けし、最も確からしい 1 件だけを守る：
    /// 1. 完全一致（発話全体がそのラベル）
    /// 2. 前方一致（一致した割合が高いほど優先）
    /// 3. 部分一致（同上）
    /// 部分一致まで見るのは、認識が途中で崩れた発話でも店名を拾えるようにするため。
    /// ただし一致割合を見ることで、長い発話に短いラベルが偶然含まれる場合は弱く扱う。
    ///
    /// この処理は部分認識のたびに走るので、
    /// 先頭文字が本文に無いラベルを先に落として比較回数を抑える
    private static func bestKnownLabelMatch(
        in text: String,
        knownLabels: KnownLabels
    ) -> (label: String, range: Range<String.Index>)? {
        guard !knownLabels.isEmpty, !text.isEmpty else { return nil }
        let textCharacters = Set(text.lowercased())
        var bestScore = 0.0
        var best: (label: String, range: Range<String.Index>)?

        for entry in knownLabels.entries {
            // 先頭文字すら本文に無ければ、どの一致にもなり得ない
            guard textCharacters.contains(entry.head) else { continue }

            guard let (score, range) = matchScore(of: entry, in: text) else { continue }
            // 同点なら長いラベルを優先する（"三千屋" が "三千" に負けないように）
            if score > bestScore
                || (score == bestScore && entry.length > (best?.label.count ?? 0)) {
                bestScore = score
                best = (entry.text, range)
            }
        }
        return best
    }

    /// ラベルと本文の一致の強さ。大きいほど確からしい
    private static func matchScore(
        of entry: KnownLabels.Entry,
        in text: String
    ) -> (score: Double, range: Range<String.Index>)? {
        let label = entry.text
        // 一致した部分が発話全体に占める割合。同種の一致では長いほど強い
        let coverage = Double(entry.length) / Double(max(text.count, 1))

        if text.compare(label, options: .caseInsensitive) == .orderedSame {
            return (1000, text.startIndex..<text.endIndex)
        }
        if let prefix = text.range(of: label, options: [.caseInsensitive, .anchored]) {
            return (100 + coverage, prefix)
        }
        // 部分一致は誤って拾いやすい（"コンビニ" の中の "ニ" など）。
        // 一定の長さと、発話に対する占有率がある場合だけ採用する
        guard entry.length >= minimumPartialMatchLength, coverage >= minimumPartialCoverage else {
            return nil
        }
        if let partial = text.range(of: label, options: .caseInsensitive) {
            return (10 + coverage, partial)
        }
        return nil
    }

    /// 部分一致として認める最小のラベル長（1 文字は偶然一致しやすい）
    private static let minimumPartialMatchLength = 2
    /// 部分一致として認める、発話全体に対する最小の占有率。
    /// "コンビニで1500円"(9文字) の中の "パー"(2文字) のような弱い一致を落とす
    private static let minimumPartialCoverage = 0.2

    /// 照合用に前処理済みの履歴ラベル。
    ///
    /// 部分認識のたびに毎回「空白除去・小文字化・金額表記かの判定」を
    /// やり直すと履歴件数に比例して重くなるため、シートを開く時点で一度だけ作る。
    /// 特に金額表記かの判定は数値解析を伴うので、使い回す効果が大きい
    struct KnownLabels {
        struct Entry {
            let text: String
            /// 先頭文字（小文字化済み）。本文に含まれるかの足切りに使う
            let head: Character
            /// 文字数。coverage 計算と部分一致の足切りに使う
            let length: Int
        }

        let entries: [Entry]
        var isEmpty: Bool { entries.isEmpty }

        static let none = KnownLabels(entries: [])

        init(entries: [Entry]) {
            self.entries = entries
        }

        /// 生のラベル配列から、照合に必要な情報を前計算して作る
        init(_ labels: [String]) {
            entries = labels.compactMap { raw in
                let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                // 数値表記そのもののラベル（"1500" など）は守らない。
                // 守ると同じ数字を金額として言えなくなる
                guard !label.isEmpty, !VoiceInputParser.isPureAmountExpression(label) else { return nil }
                guard let head = label.lowercased().first else { return nil }
                return Entry(text: label, head: head, length: label.count)
            }
        }
    }

    /// ラベル全体が金額表記だけで構成されているか（"1500" "三千" など）
    fileprivate static func isPureAmountExpression(_ label: String) -> Bool {
        guard let first = JapaneseNumberParser.allAmounts(in: label).first else { return false }
        return first.range.lowerBound == label.startIndex && first.range.upperBound == label.endIndex
    }

    // MARK: - Label refinement

    /// ラベル精製: NLTagger で名詞だけ抽出 → 空ならロケール別の関数語/助詞を剥がす
    private static func refineLabel(_ s: String, isJa: Bool) -> String {
        let nouns = extractNouns(s)
        if !nouns.isEmpty { return nouns }
        return isJa
            ? stripLeadingJapaneseParticles(s)
            : stripLeadingEnglishFunctionWords(s)
    }

    private static func extractNouns(_ s: String) -> String {
        guard !s.isEmpty else { return "" }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = s
        var nouns: [String] = []
        tagger.enumerateTags(
            in: s.startIndex..<s.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitWhitespace, .omitPunctuation, .omitOther]
        ) { tag, range in
            if tag == .noun {
                let token = String(s[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty { nouns.append(token) }
            }
            return true
        }
        return nouns.joined(separator: " ")
    }

    private static let jaLeadingParticles: [String] = [
        "から", "まで", "より", "への", "での", "には", "とは",
        "の", "で", "に", "を", "は", "が", "へ", "と", "や", "も"
    ]

    private static func stripLeadingJapaneseParticles(_ s: String) -> String {
        var result = s
        var changed = true
        while changed {
            changed = false
            for p in jaLeadingParticles where result.hasPrefix(p) {
                result = String(result.dropFirst(p.count))
                changed = true
                break
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let enLeadingFunctionWords: Set<String> = [
        "a", "an", "the", "of", "for", "to", "on", "at", "in", "with", "by", "from"
    ]

    private static func stripLeadingEnglishFunctionWords(_ s: String) -> String {
        let words = s.split(whereSeparator: { $0.isWhitespace })
        var i = 0
        while i < words.count, enLeadingFunctionWords.contains(words[i].lowercased()) {
            i += 1
        }
        return words[i...].joined(separator: " ")
    }

    private static func cleanLabel(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
         .trimmingCharacters(in: .whitespacesAndNewlines)
         .trimmingCharacters(in: CharacterSet(charactersIn: "、。,.・"))
    }

    /// 認識テキストから決済手段を特定する。マッチ無しならカードは nil
    /// カード名のマッチングはロケール非依存（文字列比較ベース）
    static func parseCard(_ rawText: String, cards: [E1card]) -> VoiceInputResult {
        let text = normalize(rawText)
        var result = VoiceInputResult()
        let candidates = cardMatchCandidates(cards: cards)
        if let m = findCardMatch(in: text, candidates: candidates) {
            result.card = m.card
            result.matchedToken = m.token
            result.matchedWasExistingAlias = m.wasExistingAlias
        }
        return result
    }

    /// 間を置いた発話では、最後に言い直した手段を採用する
    /// マッチしない言い直しでは、それまでに特定できた手段を保持する
    static func parseCard(
        _ rawText: String,
        pauseSeparatedTexts: [String],
        cards: [E1card]
    ) -> VoiceInputResult {
        guard 1 < pauseSeparatedTexts.count else {
            return parseCard(rawText, cards: cards)
        }

        for text in pauseSeparatedTexts.reversed() {
            let restatement = parseCard(text, cards: cards)
            if restatement.card != nil {
                return restatement
            }
        }
        return parseCard(rawText, cards: cards)
    }

    // MARK: - Helpers

    private static func normalize(_ s: String) -> String {
        // 全角の ASCII（数字・英字・記号）と全角スペースだけ半角化する
        // applyingTransform(.fullwidthToHalfwidth) はカタカナまで半角化するので使わない
        var result = ""
        for ch in s {
            guard let scalar = ch.unicodeScalars.first else {
                result.append(ch)
                continue
            }
            let v = scalar.value
            if v >= 0xFF01, v <= 0xFF5E, let half = UnicodeScalar(v - 0xFEE0) {
                // 全角 ASCII → 半角 ASCII（U+FF01–U+FF5E を 0xFEE0 引いて U+0021–U+007E へ）
                result.append(Character(half))
            } else if v == 0x3000 {
                // 全角スペース → 半角スペース
                result.append(" ")
            } else {
                // それ以外（カタカナ・ひらがな・漢字など）はそのまま
                result.append(ch)
            }
        }
        return result
    }

    /// 位取り単位（万・千など）を使う CJK ロケール。
    /// "1만2천" のような表記を割らずに読むため、専用パーサへ回す
    private static let cjkNumeralLanguages: Set<String> = ["ja", "ko", "zh"]

    /// ロケールに応じて全数値を抽出する。
    /// CJK は JapaneseNumberParser（位取り解析）、他は半角数字のみ
    private static func allAmounts(in text: String, locale: Locale) -> [(value: Decimal, range: Range<String.Index>)] {
        if let code = locale.language.languageCode?.identifier,
           cjkNumeralLanguages.contains(code) {
            return JapaneseNumberParser.allAmounts(in: text)
        }
        return allArabicAmounts(in: text, locale: locale)
    }

    /// "15", "1,500", "1.99", "$5", "5 dollars" を全件マッチする（非 CJK ロケール用）
    /// 通貨記号プレフィックスと通貨語サフィックスは range に呑み込む（ラベル側に残さないため）
    ///
    /// 数値そのものの解釈は NumberFormatter に任せる。
    /// 小数点と桁区切りはロケールで逆になり（en: 1,234.56 / de: 1.234,56）、
    /// インド式のような不均等な桁区切り（1,23,456）もあるため、
    /// 記号を自前で入れ替えるとロケールを増やしたときに破綻する。
    /// 正規表現は「どこからどこまでが数値表記か」の切り出しだけに使う
    private static func allArabicAmounts(
        in text: String,
        locale: Locale
    ) -> [(Decimal, Range<String.Index>)] {
        let formatter = decimalFormatter(for: locale)
        let decimalSep = locale.decimalSeparator ?? "."
        let groupingSep = locale.groupingSeparator ?? ","
        // 区切り記号は正規表現メタ文字になりうるのでエスケープする
        let dec = NSRegularExpression.escapedPattern(for: decimalSep)
        let grp = NSRegularExpression.escapedPattern(for: groupingSep)
        // 桁区切りは 3 桁固定にせず、インド式（1,23,456）も切り出せるようにする
        let pattern = "(?:[$£€¥]\\s*)?([0-9]+(?:\(grp)[0-9]+)*(?:\(dec)[0-9]+)?)"
            + "(?i:\\s*(?:dollars?|cents?|bucks?|yen|euros?|eur|pounds?|won|yuan))?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        // (値, 範囲, 通貨の目印が付いているか)
        var results: [(Decimal, Range<String.Index>, Bool)] = []
        for m in matches {
            guard m.numberOfRanges >= 2 else { continue }
            // 直前が数字や区切り記号なら、より大きな数値表記の切れ端。
            // de で "1,234.56" を読むと "1,234" が採られて ".56" が残るが、
            // その "56" を別の金額として拾うと後勝ち採用で 56 になってしまう
            let start = m.range(at: 1).location
            if start > 0 {
                let prev = ns.substring(with: NSRange(location: start - 1, length: 1))
                if prev.rangeOfCharacter(from: .decimalDigits) != nil
                    || prev == decimalSep || prev == groupingSep {
                    continue
                }
            }
            let literal = ns.substring(with: m.range(at: 1))
            // ロケールの記法として妥当な表記だけを金額にする
            // （de で "12.50" のような en 記法は解釈せず読み飛ばす）
            guard let number = formatter.number(from: literal) as? NSDecimalNumber else { continue }
            let value = number.decimalValue
            // 通貨記号・通貨語が付いているか（全体マッチが数値部より広ければ付いている）
            let hasCurrencyMarker = m.range.length > m.range(at: 1).length
            if value > 0, let range = Range(m.range, in: text) {
                results.append((value, range, hasCurrencyMarker))
            }
        }
        // 通貨の目印が無い数字が空白だけで複数並ぶ形（"1500 2000"、電話番号など）は、
        // どれが金額とも決められない。誤って最後の数字を採用するより読み取らない。
        // CJK 側の位取り解析も同じ方針なので、ロケールで挙動を揃える
        if results.count > 1, results.allSatisfy({ !$0.2 }) {
            return []
        }
        // 通貨の目印がある金額が1つでもあれば、目印なしの数字は候補から外す
        // （"Store 24 12 dollars" の 24 をラベル側に残す）
        if results.contains(where: { $0.2 }) {
            return results.filter { $0.2 }.map { ($0.0, $0.1) }
        }
        return results.map { ($0.0, $0.1) }
    }

    /// 数値解釈用の NumberFormatter。
    /// generatesDecimalNumbers で Double を経由させず、Decimal の精度を保つ
    private static func decimalFormatter(for locale: Locale) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.generatesDecimalNumbers = true
        return formatter
    }

    private struct CardMatch {
        let card: E1card
        let token: String
        let wasExistingAlias: Bool
        let range: Range<String.Index>
    }

    /// セグメント内で手段にあたる発話を探す。3 戦略を順に試す
    /// 1. 候補トークンが segment の部分文字列（長い順）
    /// 2. segment 全体がトークンの部分文字列（省略形を許容）
    /// 3. segment の各単語とトークンを双方向で比較
    private static func findCardMatch(
        in segment: String,
        candidates: [(token: String, card: E1card, isAlias: Bool)]
    ) -> CardMatch? {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for c in candidates {
            if let r = segment.range(of: c.token, options: .caseInsensitive) {
                return CardMatch(card: c.card, token: c.token, wasExistingAlias: c.isAlias, range: r)
            }
        }

        for c in candidates {
            if c.token.localizedCaseInsensitiveContains(trimmed),
               let r = segment.range(of: trimmed, options: .caseInsensitive) {
                return CardMatch(card: c.card, token: trimmed, wasExistingAlias: false, range: r)
            }
        }

        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "、。,.・"))
        let words = segment.components(separatedBy: separators).filter { !$0.isEmpty }
        for word in words {
            for c in candidates {
                let hit = c.token.localizedCaseInsensitiveContains(word) || word.localizedCaseInsensitiveContains(c.token)
                if hit, let r = segment.range(of: word, options: .caseInsensitive) {
                    return CardMatch(card: c.card, token: word, wasExistingAlias: false, range: r)
                }
            }
        }
        return nil
    }

    private static func cardMatchCandidates(cards: [E1card]) -> [(token: String, card: E1card, isAlias: Bool)] {
        var list: [(String, E1card, Bool)] = []
        for card in cards {
            let name = card.zName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { list.append((name, card, false)) }
            for alias in VoiceAliasStore.aliases(forCardID: card.id) {
                let a = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                if !a.isEmpty { list.append((a, card, true)) }
            }
        }
        // 長い順で先にマッチさせる
        return list.sorted { $0.0.count > $1.0.count }
    }
}
