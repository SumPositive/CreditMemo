import Foundation

/// 日本語音声テキストから金額（Decimal）を抽出する
/// 半角数字混じり（"1500" "1,500" "1.5万" "1万2千"）と純漢数字（"千五百" "一万二千"）に対応
enum JapaneseNumberParser {
    /// 認識テキストに出現する全ての金額を、文字範囲付きで返す
    /// 半角数字パターンと漢数字パターンを両方走査し、位置順にソートする
    static func allAmounts(in text: String) -> [(value: Decimal, range: Range<String.Index>)] {
        let arabic = scanArabicAll(in: text)
        // 漢数字スキャンは "1万2千" の "万" "千" のような、
        // 既に半角数字側で読み取った単位文字を単独の数として拾ってしまう。
        // 半角数字マッチと重なる漢数字マッチは捨てる
        let kanji = scanKanjiAll(in: text).filter { k in
            !arabic.contains { $0.1.overlaps(k.1) }
        }
        let merged = (arabic + kanji).sorted { $0.1.lowerBound < $1.1.lowerBound }
        return mergeKanjiArabicPairs(merged, in: text)
    }

    /// "一万2千" のような漢数字（上位桁）＋半角数字（下位桁）の並びを 1 つの金額へまとめる。
    /// 別々の金額のままだと後勝ち採用で下位桁だけが金額になってしまう
    private static func mergeKanjiArabicPairs(
        _ items: [(Decimal, Range<String.Index>)],
        in text: String
    ) -> [(value: Decimal, range: Range<String.Index>)] {
        var results: [(Decimal, Range<String.Index>)] = []
        var index = 0
        while index < items.count {
            let current = items[index]
            // 直後に隙間なく続き、上位桁が下位桁より大きい組だけを合算する
            if index + 1 < items.count {
                let next = items[index + 1]
                if current.1.upperBound == next.1.lowerBound,
                   isKanjiOnly(text[current.1]),
                   current.0 > next.0 {
                    results.append((current.0 + next.0, current.1.lowerBound..<next.1.upperBound))
                    index += 2
                    continue
                }
            }
            results.append(current)
            index += 1
        }
        return results.map { (value: $0.0, range: $0.1) }
    }

    private static func isKanjiOnly(_ s: Substring) -> Bool {
        !s.isEmpty && s.allSatisfy { kanjiDigitSet.contains($0) || $0 == "円" }
    }

    /// 認識テキストから最初に出現する金額と、その文字範囲を返す（互換用）
    static func firstAmount(in text: String) -> (value: Decimal, range: Range<String.Index>)? {
        allAmounts(in: text).first
    }

    // MARK: - Arabic + 単位

    /// "1500" "1,500" "1.5万" "1万" "1500円" に加え、
    /// "1万2千" のような単位の連なりも 1 つの金額としてマッチさせる。
    /// 「万」の後ろに「N千」が続く形を 1 マッチに含めないと、
    /// 1万 と 2千 が別々の金額になり後勝ち採用で 2,000 円になってしまう
    private static func scanArabicAll(in text: String) -> [(Decimal, Range<String.Index>)] {
        // 例: "1万2千3百" → base=1 unit=万 に、以降の "N千" "N百" を順に足す
        let pattern = #"([0-9,]+(?:\.[0-9]+)?)\s*(万|千)?\s*((?:[0-9,]+(?:\.[0-9]+)?\s*(?:千|百)\s*)*)円?"#
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
            // "1万2千3百" の下位桁。単位付きの上位桁があるときだけ足し込む
            if m.range(at: 2).location != NSNotFound, m.range(at: 3).location != NSNotFound {
                value += tailValue(ns.substring(with: m.range(at: 3)))
            }
            if let range = Range(m.range, in: text) {
                results.append((value, range))
            }
        }
        return results
    }

    /// "2千3百" のような下位桁の連なりを合計する
    private static func tailValue(_ s: String) -> Decimal {
        let pattern = #"([0-9,]+(?:\.[0-9]+)?)\s*(千|百)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let ns = s as NSString
        var total: Decimal = 0
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges >= 3 else { continue }
            let numStr = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: "")
            guard let n = Decimal(string: numStr), n > 0 else { continue }
            total += n * (ns.substring(with: m.range(at: 2)) == "千" ? 1000 : 100)
        }
        return total
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
