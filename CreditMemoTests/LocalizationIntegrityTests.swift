import Foundation
import Testing
@testable import CreditMemo

/// Localizable.xcstrings の整合性を JSON として直接検証する。
/// - 翻訳済みキーが対応全言語をそろえているか
/// - 書式指定子（%@ / %lld など）の引数型が全言語で一致するか（不一致は String(format:) の crash 要因）
///
/// リソースはコンパイル時パス(#filePath)からリポジトリ相対で読む（ローカルの xcodebuild test 前提）。
struct LocalizationIntegrityTests {
    /// アプリが対応する言語（プロジェクトの knownRegions から Base を除いたもの）
    private static let expectedLanguages: Set<String> = ["de", "en", "ja", "ko", "zh-Hant"]

    private func loadStrings() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CreditMemoTests/
            .deletingLastPathComponent()   // リポジトリルート
            .appendingPathComponent("CreditMemo/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["strings"] as? [String: Any]) ?? [:]
    }

    // 翻訳が1つでも入っているキーは、対応する全言語に非空の訳を持つ
    @Test("翻訳済みキーは全対応言語をそろえている")
    func everyLocalizedKeyCoversAllLanguages() throws {
        let strings = try loadStrings()
        #expect(!strings.isEmpty)

        var missing: [String] = []
        for (key, value) in strings {
            guard let entry = value as? [String: Any],
                  let locs = entry["localizations"] as? [String: Any],
                  !locs.isEmpty else {
                // ローカライズを持たないキー（"—" や "%@" 等、キー文字列をそのまま表示）は対象外
                continue
            }
            for lang in Self.expectedLanguages {
                let unit = (locs[lang] as? [String: Any])?["stringUnit"] as? [String: Any]
                let val = unit?["value"] as? String
                if val == nil || val?.isEmpty == true {
                    missing.append("\(key) [\(lang)]")
                }
            }
        }
        #expect(missing.isEmpty, "訳が欠けているキー: \(missing.sorted().prefix(30).joined(separator: ", "))")
    }

    // 各キーの書式指定子（引数型）が全言語で一致する
    @Test("書式指定子が全言語で一致する")
    func formatSpecifiersMatchAcrossLanguages() throws {
        let strings = try loadStrings()

        var mismatches: [String] = []
        for (key, value) in strings {
            guard let entry = value as? [String: Any],
                  let locs = entry["localizations"] as? [String: Any] else { continue }
            var perLang: [String: [String]] = [:]
            for (lang, lv) in locs {
                guard let unit = (lv as? [String: Any])?["stringUnit"] as? [String: Any],
                      let val = unit["value"] as? String else { continue }
                perLang[lang] = formatSpecifiers(in: val)
            }
            // 言語間で引数型の並びが割れていたら不一致
            let distinct = Set(perLang.values.map { $0.joined(separator: ",") })
            if distinct.count > 1 {
                let detail = perLang
                    .map { "\($0.key)=[\($0.value.joined(separator: " "))]" }
                    .sorted().joined(separator: " / ")
                mismatches.append("\(key): \(detail)")
            }
        }
        #expect(mismatches.isEmpty, "書式指定子不一致: \(mismatches.sorted().prefix(20).joined(separator: " | "))")
    }

    /// 位置指定(%1$)・フラグ・幅・精度を無視し、引数型(%@ / %lld 等)だけを昇順で返す。
    /// %% はリテラルなので除外する。
    private func formatSpecifiers(in text: String) -> [String] {
        let pattern = "%(?:\\d+\\$)?[-+0#]*\\d*(?:\\.\\d+)?((?:ll|l|hh|h|z|j|t|q|L)?[@dDiuUxXoOfeEgGcCsSpaAF%])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var result: [String] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let full = ns.substring(with: m.range)
            if full == "%%" { continue }
            let type = ns.substring(with: m.range(at: 1))
            result.append("%" + type)
        }
        return result.sorted()
    }
}
