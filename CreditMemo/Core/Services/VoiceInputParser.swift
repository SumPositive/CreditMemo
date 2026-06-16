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

/// 音声認識テキストの解析
/// - parseAmountAndLabel: 数値を金額、それ以外をラベルにする
/// - parseCard: カード名／エイリアス／省略形を手段にする
/// 数値解析・助詞除去はロケール依存。ja-JP では漢数字と助詞も処理する
enum VoiceInputParser {
    /// 数値は金額、文字（名詞）はラベル
    /// 後勝ち上書き: 複数の数値があれば最後を金額、ラベルは数値間の区切りで分けた中の
    /// 最後の非空セグメントを採用する
    /// locale が ja-JP の時は漢数字・万・千・円も解釈する
    static func parseAmountAndLabel(_ rawText: String, locale: Locale = .current) -> VoiceInputResult {
        let text = normalize(rawText)
        var result = VoiceInputResult()
        let isJa = locale.language.languageCode?.identifier == "ja"

        let amounts = allAmounts(in: text, locale: locale)

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
        return result
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

    /// ロケールに応じて全数値を抽出する。ja-JP は JapaneseNumberParser、他は半角数字のみ
    private static func allAmounts(in text: String, locale: Locale) -> [(value: Decimal, range: Range<String.Index>)] {
        if locale.language.languageCode?.identifier == "ja" {
            return JapaneseNumberParser.allAmounts(in: text)
        }
        return allArabicAmounts(in: text)
    }

    /// "15", "1,500", "1.99", "$5", "5 dollars" を全件マッチする（非 ja ロケール用）
    /// 通貨記号プレフィックスと通貨語サフィックスは range に呑み込む（ラベル側に残さないため）
    private static func allArabicAmounts(in text: String) -> [(Decimal, Range<String.Index>)] {
        let pattern = #"(?:[$£€¥]\s*)?([0-9]+(?:[,][0-9]{3})*(?:\.[0-9]+)?)(?i:\s*(?:dollars?|cents?|bucks?|yen|euros?|pounds?))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var results: [(Decimal, Range<String.Index>)] = []
        for m in matches {
            guard m.numberOfRanges >= 2 else { continue }
            let raw = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: "")
            if let value = Decimal(string: raw), value > 0,
               let range = Range(m.range, in: text) {
                results.append((value, range))
            }
        }
        return results
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
