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

/// 認識テキストを 金額・手段・ラベル に振り分ける
/// 1. キーワード方式（「金額」「ラベル」「決済手段」「手段」）を優先する。値が妥当なものだけ採用する
/// 2. キーワードが無い／全部無効な時は、位置方式にフォールバック
enum VoiceInputParser {
    static func parse(_ rawText: String, cards: [E1card]) -> VoiceInputResult {
        let text = normalize(rawText)
        if let r = parseByKeyword(text, cards: cards) {
            return r
        }
        return parseByPosition(text, cards: cards)
    }

    // MARK: - キーワード方式

    private enum KeywordField {
        case amount, card, label
    }

    /// 設定キーワード。長い順で先取り（"決済手段" → "手段" の重なりを避ける）
    private static let setKeywords: [(token: String, field: KeywordField)] = [
        ("決済手段", .card),
        ("ラベル",   .label),
        ("金額",     .amount),
        ("手段",     .card),
    ]

    private static func parseByKeyword(_ text: String, cards: [E1card]) -> VoiceInputResult? {
        // 1. 全キーワードの出現位置を集める（長い順で先取り）
        var candidatePool: [(range: Range<String.Index>, field: KeywordField)] = []
        for kw in setKeywords {
            var cursor = text.startIndex
            while let r = text.range(of: kw.token, range: cursor..<text.endIndex) {
                if !candidatePool.contains(where: { $0.range.overlaps(r) }) {
                    candidatePool.append((r, kw.field))
                }
                cursor = r.upperBound
            }
        }
        guard !candidatePool.isEmpty else { return nil }
        candidatePool.sort { $0.range.lowerBound < $1.range.lowerBound }

        let candidates = cardMatchCandidates(cards: cards)

        // 2. 各キーワードの値を検証する。無効なキーワードを取り除き、値の境界を再計算するループ
        while true {
            var newPool: [(Range<String.Index>, KeywordField)] = []
            var removed = false
            for (i, kw) in candidatePool.enumerated() {
                let valueStart = kw.range.upperBound
                let valueEnd = (i + 1 < candidatePool.count) ? candidatePool[i + 1].range.lowerBound : text.endIndex
                let value = trimJP(String(text[valueStart..<valueEnd]))
                let valid: Bool
                switch kw.field {
                case .amount:
                    valid = JapaneseNumberParser.firstAmount(in: value) != nil
                case .card:
                    valid = findCardMatch(in: value, candidates: candidates) != nil
                case .label:
                    valid = !value.isEmpty
                }
                if valid {
                    newPool.append((kw.range, kw.field))
                } else {
                    removed = true
                }
            }
            candidatePool = newPool
            if !removed { break }
        }

        guard !candidatePool.isEmpty else { return nil }

        // 3. 値を確定して result を組み立てる
        var result = VoiceInputResult()
        for (i, kw) in candidatePool.enumerated() {
            let valueStart = kw.range.upperBound
            let valueEnd = (i + 1 < candidatePool.count) ? candidatePool[i + 1].range.lowerBound : text.endIndex
            let value = trimJP(String(text[valueStart..<valueEnd]))
            switch kw.field {
            case .amount:
                if let (a, _) = JapaneseNumberParser.firstAmount(in: value), a > 0 {
                    result.amount = a
                }
            case .card:
                if let m = findCardMatch(in: value, candidates: candidates) {
                    result.card = m.card
                    result.matchedToken = m.token
                    result.matchedWasExistingAlias = m.wasExistingAlias
                }
            case .label:
                result.label = value
            }
        }
        return result
    }

    /// 助詞・句読点・空白を両端から落とす
    private static func trimJP(_ s: String) -> String {
        let drop = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "、。,.・はがをにのでへと"))
        return s.trimmingCharacters(in: drop)
    }

    // MARK: - 位置方式（フォールバック）
    // 手段はキーワード明示時のみ表示するため、位置パースでは手段判定をしない
    // 金額があればそれを抽出し、残りをラベルにする

    private static func parseByPosition(_ text: String, cards: [E1card]) -> VoiceInputResult {
        _ = cards
        var result = VoiceInputResult()

        let labelText: String
        if let (amount, range) = JapaneseNumberParser.firstAmount(in: text) {
            result.amount = amount
            labelText = (String(text[..<range.lowerBound]) + " " + String(text[range.upperBound...]))
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

    /// 1 セグメント内で手段にあたる発話を探す。3 つの戦略を順に試す
    /// 1. 候補トークンが segment の部分文字列（長い順）
    /// 2. segment 全体がトークンの部分文字列（省略形を許容）
    /// 3. segment の各単語とトークンを双方向で比較
    private static func findCardMatch(
        in segment: String,
        candidates: [(token: String, card: E1card, isAlias: Bool)]
    ) -> CardMatch? {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 戦略 1: 完全に segment 内に含まれる
        for c in candidates {
            if let r = segment.range(of: c.token, options: .caseInsensitive) {
                return CardMatch(card: c.card, token: c.token, wasExistingAlias: c.isAlias, range: r)
            }
        }

        // 戦略 2: segment 全体が候補トークンの部分文字列（"楽天" → "楽天カード"）
        for c in candidates {
            if c.token.localizedCaseInsensitiveContains(trimmed),
               let r = segment.range(of: trimmed, options: .caseInsensitive) {
                // 入力された発話をそのままトークンとして学習対象にする
                return CardMatch(card: c.card, token: trimmed, wasExistingAlias: false, range: r)
            }
        }

        // 戦略 3: segment の各単語と候補を双方向で比較
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
        // 長い順で先にマッチさせる（"楽天プレミアム" を "楽天" より先に）
        return list.sorted { $0.0.count > $1.0.count }
    }
}
