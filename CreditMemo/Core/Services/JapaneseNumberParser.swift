import Foundation

/// 日本語音声テキストから金額（Decimal）を抽出する
/// 半角数字混じり（"1500" "1,500" "1.5万" "1万2千"）と純漢数字（"千五百" "一万二千"）に対応
enum JapaneseNumberParser {
    /// 認識テキストに出現する全ての金額を、文字範囲付きで返す
    /// 半角数字パターンと漢数字パターンを両方走査し、位置順にソートする
    static func allAmounts(in text: String) -> [(value: Decimal, range: Range<String.Index>)] {
        var results: [(Decimal, Range<String.Index>)] = []
        results.append(contentsOf: scanArabicAll(in: text))
        results.append(contentsOf: scanKanjiAll(in: text))
        return results.sorted { $0.1.lowerBound < $1.1.lowerBound }
    }

    /// 認識テキストから最初に出現する金額と、その文字範囲を返す（互換用）
    static func firstAmount(in text: String) -> (value: Decimal, range: Range<String.Index>)? {
        allAmounts(in: text).first
    }

    // MARK: - Arabic + 単位

    /// "1500" "1,500" "1.5万" "1万" "1500円" などを全てマッチさせる
    private static func scanArabicAll(in text: String) -> [(Decimal, Range<String.Index>)] {
        let pattern = #"([0-9,]+(?:\.[0-9]+)?)\s*(万|千)?\s*円?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var results: [(Decimal, Range<String.Index>)] = []
        for m in matches {
            guard m.numberOfRanges >= 2 else { continue }
            let numStr = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: "")
            guard let base = Decimal(string: numStr), base > 0 else { continue }
            var value = base
            if m.range(at: 2).location != NSNotFound {
                let unit = ns.substring(with: m.range(at: 2))
                if unit == "万" { value = base * 10000 }
                else if unit == "千" { value = base * 1000 }
            }
            if let range = Range(m.range, in: text) {
                results.append((value, range))
            }
        }
        return results
    }

    // MARK: - 漢数字

    private static let kanjiDigitSet: Set<Character> = ["〇", "零", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "百", "千", "万", "億"]

    /// 漢数字シーケンスを全て検出する
    private static func scanKanjiAll(in text: String) -> [(Decimal, Range<String.Index>)] {
        var results: [(Decimal, Range<String.Index>)] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard let first = text[cursor...].firstIndex(where: { kanjiDigitSet.contains($0) }) else { break }
            var end = first
            while end < text.endIndex, kanjiDigitSet.contains(text[end]) {
                end = text.index(after: end)
            }
            let segment = String(text[first..<end])
            if !segment.isEmpty, let value = parseKanjiNumber(segment), value > 0 {
                var rangeEnd = end
                if rangeEnd < text.endIndex, text[rangeEnd] == "円" {
                    rangeEnd = text.index(after: rangeEnd)
                }
                results.append((value, first..<rangeEnd))
            }
            cursor = end
        }
        return results
    }

    private static func parseKanjiNumber(_ s: String) -> Decimal? {
        let digit: [Character: Decimal] = [
            "〇": 0, "零": 0,
            "一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
            "六": 6, "七": 7, "八": 8, "九": 9
        ]
        let smallUnit: [Character: Decimal] = ["十": 10, "百": 100, "千": 1000]
        let bigUnit:   [Character: Decimal] = ["万": 10000, "億": 100_000_000]

        var total: Decimal = 0
        var smallSection: Decimal = 0
        var current: Decimal = 0

        for ch in s {
            if let d = digit[ch] {
                current = d
            } else if let u = smallUnit[ch] {
                // 「十」「百」「千」の前に数字が無ければ 1 とみなす
                smallSection += (current == 0 ? 1 : current) * u
                current = 0
            } else if let u = bigUnit[ch] {
                let combined = smallSection + current
                total += (combined == 0 ? 1 : combined) * u
                smallSection = 0
                current = 0
            }
        }
        total += smallSection + current
        return total
    }
}
