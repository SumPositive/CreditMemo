import SwiftUI
import Foundation
import UIKit

// MARK: - URL

/// ヘルプドキュメント URL（言語別・fontScale パラメータ付き）
@MainActor
func helpDocURL() -> URL {
    let lang = Locale.current.language.languageCode?.identifier ?? "en"
    let base = lang == "ja"
        ? "https://docs.azukid.com/jp/sumpo/CreditMemo/creditmemo.html"
        : "https://docs.azukid.com/en/sumpo/CreditMemo/creditmemo.html"
    var components = URLComponents(string: base)!
    components.queryItems = [URLQueryItem(name: "fontScale", value: helpDocFontScaleValue())]
    return components.url!
}

/// FontScale 設定を Web 用の 3 段階文字列に変換する
@MainActor
private func helpDocFontScaleValue() -> String {
    let raw = UserDefaults.standard.string(forKey: AppStorageKey.fontScale) ?? FontScale.system.rawValue
    switch FontScale(rawValue: raw) ?? .system {
    case .standard: return "standard"
    case .large:    return "large"
    case .xLarge:   return "xLarge"
    case .system:
        // 自動設定時は現在の iOS 文字サイズを 3 段階へ丸める
        switch UIApplication.shared.preferredContentSizeCategory {
        case .extraSmall, .small, .medium, .large:
            return "standard"
        case .extraLarge, .extraExtraLarge, .extraExtraExtraLarge:
            return "large"
        default:
            return "xLarge"
        }
    }
}

// MARK: - 入力制約

let APP_MAX_AMOUNT: Decimal = 99_999_999
let APP_MAX_NAME_LEN   = 50
let APP_MAX_NOTE_LEN   = 200
let APP_MAX_PART_COUNT = 99   // 分割払い最大回数

// MARK: - 日付範囲

let APP_MIN_DATE = Calendar.current.date(from: DateComponents(year: 2000, month: 1, day: 1))!
let APP_MAX_DATE = Calendar.current.date(from: DateComponents(year: 2100, month: 12, day: 31))!

// MARK: - Layout

let COLOR_AMOUNT_POSITIVE: Color = .primary
let COLOR_AMOUNT_NEGATIVE: Color = .red

// MARK: - ブランドカラー
// 小豆色（azukid.com）を区切りに、金茶（未払）と グレージュ（済み）で状態を分ける
// ライト／ダークでそれぞれ明度を調整する

/// 未払アイコン: 金茶 #B8860B / dark #D4A848
let COLOR_UNPAID: Color = Color(uiColor: UIColor { trait in
    trait.userInterfaceStyle == .dark
        ? UIColor(red: 0.831, green: 0.659, blue: 0.282, alpha: 1)
        : UIColor(red: 0.722, green: 0.525, blue: 0.043, alpha: 1)
})

/// 済みアイコン: グレージュ #8B7E74 / dark #A89A8E
let COLOR_PAID: Color = Color(uiColor: UIColor { trait in
    trait.userInterfaceStyle == .dark
        ? UIColor(red: 0.659, green: 0.604, blue: 0.557, alpha: 1)
        : UIColor(red: 0.545, green: 0.494, blue: 0.455, alpha: 1)
})

/// 引き落とし境界線: 小豆色 #7A2E2E / dark #A14848
let COLOR_DEBIT_BOUNDARY: Color = Color(uiColor: UIColor { trait in
    trait.userInterfaceStyle == .dark
        ? UIColor(red: 0.631, green: 0.282, blue: 0.282, alpha: 1)
        : UIColor(red: 0.478, green: 0.180, blue: 0.180, alpha: 1)
})

/// ブランドクリーム（発光ライン・小型バッジの中央色）: #F5EBD8 / dark #F0E0BE
let COLOR_BRAND_CREAM: Color = Color(uiColor: UIColor { trait in
    trait.userInterfaceStyle == .dark
        ? UIColor(red: 0.941, green: 0.878, blue: 0.745, alpha: 1)
        : UIColor(red: 0.961, green: 0.922, blue: 0.847, alpha: 1)
})

let COLOR_SEPARATOR: Color       = Color(.separator)
