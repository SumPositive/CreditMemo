import Foundation
import Testing
@testable import CreditMemo

/// Localizable.xcstrings の整合性を JSON として直接検証する。
/// - 翻訳済みキーが対応全言語をそろえているか
/// - 翻訳状態（state）が全て translated か（new / needs_review の取りこぼし検出）
/// - 抽出状態（extractionState）に stale が残っていないか（Xcode の警告要因）
/// - 書式指定子（%@ / %lld など）の引数型が全言語で一致するか（不一致は String(format:) の crash 要因）
///
/// リソースはコンパイル時パス(#filePath)からリポジトリ相対で読む（ローカルの xcodebuild test 前提）。
/// 実機ではリポジトリのファイルへ到達できないため、これらの検証はスキップする
/// （実行先の誤りは CreditMemoTests.requiresSimulator が知らせる）。
struct LocalizationIntegrityTests {
    /// リポジトリのリソースを読めるか（シミュレータ／Mac 上の実行かどうか）
    static let canReadRepositoryResources = FileManager.default.fileExists(
        atPath: repositoryResourceURL.path
    )

    private static var repositoryResourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CreditMemoTests/
            .deletingLastPathComponent()   // リポジトリルート
            .appendingPathComponent("CreditMemo/Resources/Localizable.xcstrings")
    }

    /// アプリが対応する言語（プロジェクトの knownRegions から Base を除いたもの）
    private static let expectedLanguages: Set<String> = ["de", "en", "ja", "ko", "zh-Hant"]

    /// リリース品質として許容する翻訳状態。
    /// new = 未翻訳、needs_review = 要確認（Xcode が機械翻訳や原文変更時に付ける）
    private static let acceptableStates: Set<String> = ["translated"]

    private func loadStrings() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.repositoryResourceURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["strings"] as? [String: Any]) ?? [:]
    }

    // 翻訳が1つでも入っているキーは、対応する全言語に非空の訳を持つ
    @Test(
        "翻訳済みキーは全対応言語をそろえている",
        .enabled(if: canReadRepositoryResources)
    )
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

    /// extractionState: stale は「ソースから抽出されなくなったキー」。
    /// Xcode が警告を出すので残さない。対処は 2 つだけ：
    /// - 動的に組み立てるなどで実際に使っているキー → manual（意図的に保持する印）
    /// - 本当に使っていないキー → カタログから削除
    ///
    /// stale のまま放置すると、未使用キーの蓄積と本当に消し忘れたキーの区別がつかなくなる
    @Test(
        "抽出状態に stale が残っていない",
        .enabled(if: canReadRepositoryResources)
    )
    func noStaleExtractionStateRemains() throws {
        let strings = try loadStrings()
        #expect(!strings.isEmpty)

        var stale: [String] = []
        for (key, value) in strings {
            guard let entry = value as? [String: Any] else { continue }
            if entry["extractionState"] as? String == "stale" {
                stale.append(key)
            }
        }
        #expect(
            stale.isEmpty,
            """
            extractionState が stale のキーが \(stale.count) 件あります。
            実際に使っているなら manual に、使っていないなら削除してください:
            \(stale.sorted().joined(separator: "\n"))
            """
        )
    }

    // 利用者向け文言は translated 以外の状態を残さない。
    // 値が非空でも state が new / needs_review なら未確認の訳なので、リリース品質としては不可
    @Test(
        "翻訳状態が全て translated になっている",
        .enabled(if: canReadRepositoryResources)
    )
    func everyLocalizationIsMarkedTranslated() throws {
        let strings = try loadStrings()
        #expect(!strings.isEmpty)

        var unfinished: [String] = []
        for (key, value) in strings {
            guard let entry = value as? [String: Any],
                  let locs = entry["localizations"] as? [String: Any] else { continue }
            for lang in Self.expectedLanguages {
                guard let unit = (locs[lang] as? [String: Any])?["stringUnit"] as? [String: Any] else {
                    // 訳そのものの欠落は everyLocalizedKeyCoversAllLanguages 側で検出する
                    continue
                }
                // state 未指定は translated 扱い（Xcode が省略することがある）
                let state = (unit["state"] as? String) ?? "translated"
                if !Self.acceptableStates.contains(state) {
                    unfinished.append("\(key) [\(lang)] = \(state)")
                }
            }
        }
        // 取りこぼしを潰せるよう、件数と該当キーを一覧で出す
        #expect(
            unfinished.isEmpty,
            """
            未完了の翻訳が \(unfinished.count) 件あります:
            \(unfinished.sorted().joined(separator: "\n"))
            """
        )
    }

    // 各キーの書式指定子（引数型）が全言語で一致する
    @Test(
        "書式指定子が全言語で一致する",
        .enabled(if: canReadRepositoryResources)
    )
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
