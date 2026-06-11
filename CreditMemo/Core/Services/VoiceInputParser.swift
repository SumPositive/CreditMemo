import Foundation

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
enum VoiceInputParser {
    /// 数値は金額、文字（名詞）はラベル
    static func parseAmountAndLabel(_ rawText: String) -> VoiceInputResult {
        let text = normalize(rawText)
        var result = VoiceInputResult()

        let labelText: String
        if let (amount, range) = JapaneseNumberParser.firstAmount(in: text) {
            result.amount = amount
            labelText = String(text[..<range.lowerBound]) + " " + String(text[range.upperBound...])
        } else {
            labelText = text
        }
        let combined = labelText
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "、。,.・"))
        if !combined.isEmpty { result.label = combined }
        return result
    }

    /// 認識テキストから決済手段を特定する。マッチ無しならカードは nil
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
        // 全角→半角に寄せる（数字・英字の取り違えを減らす）
        if let n = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) {
            return n
        }
        return s
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
