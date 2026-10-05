import SwiftUI
import Foundation
import UIKit

// MARK: - App Store

/// App Store のアプリID
let APP_STORE_ID = "432458298"

/// レビュー入力欄を開いた状態で App Store アプリを表示する。
/// https:// だと Safari が先に受け取り、リダイレクトで action= が落ちて
/// 「アドレスが無効です」になるため、App Store を直接指す itms-apps:// を使う
let APP_REVIEW_URL = URL(string: "itms-apps://apps.apple.com/app/id\(APP_STORE_ID)?action=write-review")

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

/// 保存と集計では端末の暦設定に左右されない西暦を使う
enum AppCalendar {
    static var gregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        // 暦は西暦に固定し、週の開始曜日だけ端末設定を反映する
        calendar.firstWeekday = Calendar.autoupdatingCurrent.firstWeekday
        calendar.minimumDaysInFirstWeek = Calendar.autoupdatingCurrent.minimumDaysInFirstWeek
        return calendar
    }

    /// 端末の言語・地域のまま、暦だけ西暦にしたロケール
    static var locale: Locale { gregorianLocale(.autoupdatingCurrent) }

    /// ロケールの暦を西暦に差し替える。
    /// 和暦・民国暦のロケールのままテンプレートから書式を作ると紀元（G）が入り、
    /// 西暦で書くと「西暦2026年」「AD 2026」「西元 2026年」になるため
    static func gregorianLocale(_ base: Locale) -> Locale {
        var components = Locale.Components(locale: base)
        components.calendar = .gregorian
        return Locale(components: components)
    }
}

let APP_MIN_DATE = AppCalendar.gregorian.date(from: DateComponents(year: 2000, month: 1, day: 1))!
let APP_MAX_DATE = AppCalendar.gregorian.date(from: DateComponents(year: 2100, month: 12, day: 31))!

// MARK: - Layout

let COLOR_AMOUNT_POSITIVE: Color = .primary
let COLOR_AMOUNT_NEGATIVE: Color = .red

// MARK: - 配色
// 未払／済みの帯色・アイコン色は BadgeTheme (Environment) から取得する。
// 各 View で `@Environment(\.badgeTheme) private var badgeTheme` を宣言して使う。

let COLOR_SEPARATOR: Color       = Color(.separator)
