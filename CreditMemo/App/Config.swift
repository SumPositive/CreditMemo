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

// MARK: - 配色
// 未払／済みの帯色・アイコン色は BadgeTheme (Environment) から取得する。
// 各 View で `@Environment(\.badgeTheme) private var badgeTheme` を宣言して使う。

let COLOR_SEPARATOR: Color       = Color(.separator)
