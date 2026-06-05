//
//  初期データ投入処理
//  初回起動時の決済手段、口座、タグのサンプル登録をまとめる
//

import Foundation
import SwiftData

@MainActor
enum SeedData {
    struct CardPreset {
        var name: String
        var note: String = ""
        var closingDay: Int16
        var payDay: Int16
        var payMonth: Int16
    }

    struct BankPreset {
        var name: String
    }

    struct CategoryPreset {
        var name: String
    }

    static func seedIfNeeded(context: ModelContext) {
        let count = (try? context.fetchCount(FetchDescriptor<E1card>())) ?? 0
        guard count == 0 else { return }
        let bankPresets = localizedBankPresets()
        let cardPresets = localizedCardPresets()
        let categoryPresets = localizedCategoryPresets()

        // 引き落とし口座プリセット
        for (row, b) in bankPresets.enumerated() {
            let bank = E8bank(
                zName: b.name,
                nRow: Int32(row)
            )
            context.insert(bank)
        }

        // 決済方法プリセット
        for (row, p) in cardPresets.enumerated() {
            let card = E1card(
                zName: p.name,
                zNote: p.note,
                nRow: Int32(row),
                // プリセットは常に正規形の値をそのまま保存する
                nClosingDay: p.closingDay,
                nPayDay: p.payDay,
                nPayMonth: p.payMonth
            )
            context.insert(card)
        }

        // タグプリセット
        for p in categoryPresets {
            let tag = E5tag(
                zName: p.name,
                sortName: p.name
            )
            context.insert(tag)
        }
        try? context.save()
    }

    /// 現在の表示言語に合わせたプリセット一覧を返す
    static func presetsForCurrentLocale() -> [CardPreset] {
        localizedCardPresets()
    }

    /// 現在の表示言語に合わせた口座プリセット一覧を返す
    static func bankPresetsForCurrentLocale() -> [BankPreset] {
        localizedBankPresets()
    }

    /// 現在の表示言語に合わせたタグプリセット一覧を返す
    static func categoryPresetsForCurrentLocale() -> [CategoryPreset] {
        localizedCategoryPresets()
    }

    // MARK: - Private

    /// 言語ごとに初期プリセットを切り替える
    private static func localizedCardPresets() -> [CardPreset] {
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        if lang == "ja" {
            return japaneseCardPresets()
        }
        return westernCardPresets()
    }

    /// 言語ごとに口座プリセットを切り替える
    private static func localizedBankPresets() -> [BankPreset] {
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        if lang == "ja" {
            return japaneseBankPresets()
        }
        return westernBankPresets()
    }

    /// 言語ごとにタグプリセットを切り替える
    private static func localizedCategoryPresets() -> [CategoryPreset] {
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        if lang == "ja" {
            return japaneseCategoryPresets()
        }
        return westernCategoryPresets()
    }

    /// 日本向けの代表的な決済方法
    private static func japaneseCardPresets() -> [CardPreset] {
        [
            // N日後型プリセット: 住民税の分納など、支払日＝利用日として運用
            CardPreset(
                name: "当日払",
                note: "例えば家賃の決済に使用します。引き落とし日を利用日として登録します。繰り返しを「翌月」にすれば自動的に次の決済が作成されます。",
                closingDay: 0,
                payDay: 0,
                payMonth: 0
            ),
            // 締日/支払日型プリセット
            CardPreset(name: "VIEWカード", closingDay: 5, payDay: 4, payMonth: 1),
            CardPreset(name: "PayPayカード", closingDay: 29, payDay: 27, payMonth: 1),
            CardPreset(name: "楽天カード", closingDay: 29, payDay: 27, payMonth: 1),
            CardPreset(name: "イオンカード", closingDay: 10, payDay: 2, payMonth: 1),
            CardPreset(name: "ｄカード", closingDay: 15, payDay: 10, payMonth: 1),
            CardPreset(name: "三井住友カード", closingDay: 15, payDay: 10, payMonth: 1),
            CardPreset(name: "AMEXカード", closingDay: 20, payDay: 10, payMonth: 1),
            // 追加: 日本の主要カード（発行数上位クラス）
            CardPreset(name: "JCBカード", closingDay: 15, payDay: 10, payMonth: 1),
            CardPreset(name: "セゾンカード", closingDay: 10, payDay: 4, payMonth: 1),
            CardPreset(name: "エポスカード", closingDay: 4, payDay: 4, payMonth: 1),
            CardPreset(name: "オリコカード", closingDay: 27, payDay: 27, payMonth: 1),
            CardPreset(name: "ライフカード", closingDay: 5, payDay: 3, payMonth: 1),
            CardPreset(name: "UCカード", closingDay: 10, payDay: 5, payMonth: 1),
            CardPreset(name: "三菱UFJカード", closingDay: 15, payDay: 10, payMonth: 1),
            CardPreset(name: "アプラスカード", closingDay: 27, payDay: 27, payMonth: 1),
            CardPreset(name: "NICOSカード", closingDay: 5, payDay: 27, payMonth: 1),
            CardPreset(name: "ジャックスカード", closingDay: 15, payDay: 10, payMonth: 1),
        ]
    }

    /// 英語環境では欧米の代表的な決済方法を初期表示する
    private static func westernCardPresets() -> [CardPreset] {
        [
            // N日後型プリセット
            CardPreset(name: "Same-Day Payment", closingDay: 0, payDay: 0, payMonth: 0),
            CardPreset(name: "Net 7", closingDay: 0, payDay: 7, payMonth: 0),
            CardPreset(name: "Net 14", closingDay: 0, payDay: 14, payMonth: 0),
            CardPreset(name: "Net 30", closingDay: 0, payDay: 30, payMonth: 0),
            // 締日/支払日型プリセット
            CardPreset(name: "Visa", closingDay: 27, payDay: 27, payMonth: 1),
            CardPreset(name: "Mastercard", closingDay: 27, payDay: 27, payMonth: 1),
            CardPreset(name: "American Express", closingDay: 27, payDay: 27, payMonth: 1),
            CardPreset(name: "Klarna", closingDay: 27, payDay: 27, payMonth: 1),
        ]
    }

    /// 日本の主要口座プリセット（引き落とし設定向け）
    private static func japaneseBankPresets() -> [BankPreset] {
        [
            BankPreset(name: "住信SBIネット銀行"),
            BankPreset(name: "楽天銀行"),
            BankPreset(name: "PayPay銀行"),
            BankPreset(name: "ソニー銀行"),
            BankPreset(name: "三菱UFJ銀行"),
            BankPreset(name: "三井住友銀行"),
            BankPreset(name: "みずほ銀行"),
            BankPreset(name: "ゆうちょ銀行"),
            BankPreset(name: "りそな銀行"),
            BankPreset(name: "埼玉りそな銀行"),
        ]
    }

    /// 欧米の主要口座プリセット（引き落とし設定向け）
    private static func westernBankPresets() -> [BankPreset] {
        [
            BankPreset(name: "JPMorgan Chase"),
            BankPreset(name: "Bank of America"),
            BankPreset(name: "Citibank"),
            BankPreset(name: "Wells Fargo"),
            BankPreset(name: "HSBC"),
            BankPreset(name: "Barclays"),
            BankPreset(name: "Lloyds Bank"),
            BankPreset(name: "Santander"),
            BankPreset(name: "BNP Paribas"),
            BankPreset(name: "Deutsche Bank"),
        ]
    }

    /// 日本向けタグプリセット
    private static func japaneseCategoryPresets() -> [CategoryPreset] {
        [
            CategoryPreset(name: "チャージ"),
            CategoryPreset(name: "ETC"),
            CategoryPreset(name: "注意"),
            CategoryPreset(name: "重要"),
        ]
    }

    /// 英語環境向けタグプリセット
    private static func westernCategoryPresets() -> [CategoryPreset] {
        [
            CategoryPreset(name: "Top-up"),
            CategoryPreset(name: "Toll"),
            CategoryPreset(name: "Caution"),
            CategoryPreset(name: "Important"),
        ]
    }
}
