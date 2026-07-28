import Foundation

/// CJK 圏の音声テキストから金額（Decimal）を抽出する
///
/// 半角数字・漢数字・その混在を、位取りで一体として解釈する。
/// 例: "1500" "1,500" "1.5万" "1万2千3百4十" "一万2千3百4十" "千五百" "一億2千万"
///
/// 日本語に加え、同じ位取り体系を使う繁体字（萬/千）と韓国語（만/천）も扱う。
/// これらのロケールでも "1만2천" のような表記が 1 と 2000 に割れると、
/// 音声解析側の後勝ち採用で下位桁だけが金額になってしまうため。
///
/// 半角数字と漢数字を別々に走査すると "1万2千3百4十" が 12,300 / 4 / 10 のように
/// 分割され、音声解析側の後勝ち採用で下位桁だけが金額になってしまう。
/// そのため数字（半角・漢数字）と単位（十百千万億）の連なりを 1 つのまとまりとして
/// 取り出し、位取り解析で 1 つの金額に組み立てる。
enum JapaneseNumberParser {
    /// 認識テキストに出現する全ての金額を、文字範囲付きで返す（出現順）
    static func allAmounts(in text: String) -> [(value: Decimal, range: Range<String.Index>)] {
        var results: [(value: Decimal, range: Range<String.Index>)] = []
        var cursor = text.startIndex

        while cursor < text.endIndex {
            guard let start = text[cursor...].firstIndex(where: { isNumericStart($0) }) else { break }
            // 数字・単位・桁区切りが続く限りを 1 つのまとまりとして取り出す
            let end = numericRunEnd(in: text, from: start)
            let run = text[start..<end]

            // 数値の直後（空白を挟む場合も含む）にある通貨単位を探す
            let currencyUnitEnd = currencyUnitEndIndex(in: text, after: end)
            let hasCurrencyUnit = currencyUnitEnd != nil
            if let value = parseNumericRun(run), value > 0,
               !isLikelyPartOfWord(run: run, hasCurrencyUnit: hasCurrencyUnit, text: text, end: end) {
                // 通貨単位（円/원/元）と接頭の通貨記号も範囲へ含め、ラベル側へ残さない
                let rangeStart = currencySymbolStartIndex(in: text, before: start)
                let rangeEnd = currencyUnitEnd ?? end
                results.append((value, rangeStart..<rangeEnd))
            }
            cursor = end > cursor ? end : text.index(after: cursor)
        }
        return results
    }

    /// 認識テキストから最初に出現する金額と、その文字範囲を返す（互換用）
    static func firstAmount(in text: String) -> (value: Decimal, range: Range<String.Index>)? {
        allAmounts(in: text).first
    }

    /// 金額ではなく語の一部（店名など）とみなすか判定する。
    ///
    /// 「一蘭」「三井住友」「万代」「千疋屋」「三丁目」のように、
    /// 漢数字・単位が 1 文字だけあって直後に普通の文字が続く形は、
    /// 金額ではなく名前の一部である可能性が高い。
    /// 一方「千円」は同じ 1 文字でも通貨単位が続くので金額として扱う。
    ///
    /// 半角数字を含む場合（"1500" や "5個"）は数量表現として書かれているので対象外にする。
    /// ここで弾かないと、金額を誤るだけでなくラベルからも先頭文字が欠ける
    private static func isLikelyPartOfWord(
        run: Substring,
        hasCurrencyUnit: Bool,
        text: String,
        end: String.Index
    ) -> Bool {
        // 通貨単位が続くなら金額（"千円" "三千円"）
        if hasCurrencyUnit { return false }
        // 半角数字を含むものは数量表現として扱う（"1500" "5個"）
        if run.contains(where: isDigitChar) { return false }
        // 直後に文字が無い（"千五百" のように文末で終わる）なら金額
        guard end < text.endIndex else { return false }
        // 直後が空白・数字・単位なら金額の続き
        let next = text[end]
        guard !next.isWhitespace, !isNumericBody(next) else { return false }
        // ここまで来たら「漢数字だけの並び＋普通の文字」。
        // "一蘭" だけでなく "七十七銀行" "八十二銀行" のような
        // 数を含む固有名詞も金額にしない（実在の銀行名で誤認が起きる）
        return true
    }

    /// 金額であることを示す通貨単位（日本語=円 / 繁体字=元 / 韓国語=원）
    private static func isCurrencyUnit(_ c: Character) -> Bool {
        c == "円" || c == "元" || c == "원"
    }

    /// 数値の直後にある通貨単位の終端を返す（無ければ nil）。
    /// "1500 円" のように空白を挟む形もラベルへ残さないよう範囲に含める
    private static func currencyUnitEndIndex(
        in text: String,
        after end: String.Index
    ) -> String.Index? {
        var index = end
        while index < text.endIndex, text[index] == " " {
            index = text.index(after: index)
        }
        guard index < text.endIndex, isCurrencyUnit(text[index]) else { return nil }
        return text.index(after: index)
    }

    /// 接頭の通貨記号（¥ ₩ NT$ $ など）の開始位置を返す。
    /// 記号がラベル側に残ると "¥" だけのラベルができてしまう
    private static func currencySymbolStartIndex(
        in text: String,
        before start: String.Index
    ) -> String.Index {
        var index = start
        // 記号と数値の間の空白（"¥ 1500"）も取り込む
        while index > text.startIndex {
            let previous = text.index(before: index)
            if text[previous] == " " {
                index = previous
            } else {
                break
            }
        }
        guard index > text.startIndex else { return start }
        let symbolEnd = index
        // 単体記号（¥ ₩ $ …）を 1 文字巻き戻す
        let previous = text.index(before: index)
        guard Self.currencySymbols.contains(text[previous]) else { return start }
        index = previous
        // "NT$" のように記号の前に付く通貨コードも取り込む
        for prefix in Self.currencySymbolPrefixes {
            if let range = text.range(of: prefix, options: [.backwards, .caseInsensitive],
                                      range: text.startIndex..<index),
               range.upperBound == index {
                index = range.lowerBound
                break
            }
        }
        return index < symbolEnd ? index : start
    }

    /// 数値の前に付く通貨記号
    private static let currencySymbols: Set<Character> = ["¥", "₩", "$", "＄", "£", "€"]
    /// 記号の直前に付く通貨コード（"NT$" の "NT" など）
    private static let currencySymbolPrefixes = ["NT", "HK", "US"]

    // MARK: - まとまりの切り出し

    private static let kanjiDigit: [Character: Decimal] = [
        "〇": 0, "零": 0,
        "一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
        "六": 6, "七": 7, "八": 8, "九": 9
    ]
    /// 十/百/千 は万・億の中での位取りに使う小単位。
    /// 繁体字（zh-Hant）とハングル（ko）の同義字も同じ位取りとして扱う
    private static let smallUnit: [Character: Decimal] = [
        "十": 10, "百": 100, "千": 1000,
        "십": 10, "백": 100, "천": 1000,   // ko
    ]
    /// 万/億 は区切りとなる大単位（萬 は繁体字、만/억 はハングル）
    private static let bigUnit: [Character: Decimal] = [
        "万": 10000, "億": 100_000_000,
        "萬": 10000,                      // zh-Hant
        "만": 10000, "억": 100_000_000,   // ko
    ]

    private static func isDigitChar(_ c: Character) -> Bool {
        c.isASCII && c.isNumber
    }

    /// まとまりの開始になりうる文字（数字そのもの、または「千五百」のように単位で始まる形）
    private static func isNumericStart(_ c: Character) -> Bool {
        isDigitChar(c) || kanjiDigit[c] != nil || smallUnit[c] != nil || bigUnit[c] != nil
    }

    /// まとまりを構成する文字（開始文字に加え、桁区切りと小数点も含む）
    private static func isNumericBody(_ c: Character) -> Bool {
        isNumericStart(c) || c == "," || c == "."
    }

    /// start から数字・単位が続く終端を返す。末尾の "," "." 空白は含めない。
    ///
    /// "1만 2천원" のように単位の間に空白を挟む表記があるため、
    /// 空白の直後に数字・単位が続く場合はまとまりを継続する
    /// （ここで切ると 1 と 2000 に割れ、後勝ち採用で 2,000 になってしまう）
    private static func numericRunEnd(in text: String, from start: String.Index) -> String.Index {
        var end = start
        while end < text.endIndex {
            let ch = text[end]
            if isNumericBody(ch) {
                end = text.index(after: end)
                continue
            }
            // 空白は、その先に数字・単位が続くときだけまとまりの一部として跨ぐ
            if ch == " " {
                var lookahead = end
                while lookahead < text.endIndex, text[lookahead] == " " {
                    lookahead = text.index(after: lookahead)
                }
                if lookahead < text.endIndex, isNumericStart(text[lookahead]) {
                    end = lookahead
                    continue
                }
            }
            break
        }
        // "1,500円と" の "と" 直前など、区切り文字や空白で終わる場合は巻き戻す
        while end > start {
            let prev = text.index(before: end)
            if text[prev] == "," || text[prev] == "." || text[prev] == " " {
                end = prev
            } else {
                break
            }
        }
        return end
    }

    // MARK: - 位取り解析

    /// 数字（半角・漢数字）と単位の連なりを 1 つの金額に組み立てる。
    ///
    /// 「万」「億」で区切り、その中を 十/百/千 で位取りする標準的な読み方に従う。
    /// 半角数字と漢数字は同じ「数」として扱うので、混在しても結果は変わらない。
    /// 単位を伴わない小数（"1.5"）や桁区切り（"1,500"）はそのままの数値として読む。
    private static func parseNumericRun(_ run: Substring) -> Decimal? {
        var total: Decimal = 0        // 万・億で確定した分
        var section: Decimal = 0      // 現在の大単位セクション内で確定した分
        var current: Decimal?         // 直前に読んだ数（単位待ち）
        var sawAnyNumber = false
        var index = run.startIndex

        while index < run.endIndex {
            let ch = run[index]

            // 半角数字の並び（桁区切り・小数点を含む）をまとめて 1 つの数として読む
            if isDigitChar(ch) {
                var end = index
                var literal = ""
                while end < run.endIndex, isDigitChar(run[end]) || run[end] == "," || run[end] == "." {
                    // 小数点は後ろに数字が続くときだけ数の一部として扱う
                    if run[end] == "." {
                        let next = run.index(after: end)
                        guard next < run.endIndex, isDigitChar(run[next]) else { break }
                    }
                    if run[end] != "," { literal.append(run[end]) }
                    end = run.index(after: end)
                }
                guard let value = Decimal(string: literal) else { return nil }
                // 単位を挟まず数が続くのは "1..5" のような壊れた入力。
                // 黙って足し合わせると誤った金額になるので読み取らない
                if current != nil { return nil }
                current = value
                sawAnyNumber = true
                index = end
                continue
            }

            if let digit = kanjiDigit[ch] {
                // "一二三" のように単位を挟まず漢数字が続く並びは、位取りとして
                // 解釈できない（"二〇二四" のような数字列表記も同様）。
                // 誤った金額を返すより読み取らない方が安全
                if current != nil { return nil }
                current = digit
                sawAnyNumber = true
                index = run.index(after: index)
                continue
            }

            if let unit = smallUnit[ch] {
                // 「千五百」のように単位の前に数が無ければ 1 とみなす
                section += (current ?? 1) * unit
                current = nil
                sawAnyNumber = true
                index = run.index(after: index)
                continue
            }

            if let unit = bigUnit[ch] {
                // 「一億2千万」→ 億で確定した分に、続く「2千万」を足す
                let combined = section + (current ?? 0)
                total += (combined == 0 ? 1 : combined) * unit
                section = 0
                current = nil
                sawAnyNumber = true
                index = run.index(after: index)
                continue
            }

            index = run.index(after: index)
        }

        guard sawAnyNumber else { return nil }
        return total + section + (current ?? 0)
    }
}
