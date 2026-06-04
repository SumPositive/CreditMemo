import Foundation
import SwiftUI

/// AppStorage キー定数
enum AppStorageKey {
    static let userLevel         = "setting.userLevel"
    static let appearanceMode    = "setting.appearanceMode"
    static let fontScale         = "setting.fontScale"
    static let tagSortMode       = "setting.tagSortMode"
    static let afterSaveAction   = "setting.afterSaveAction"
    static let openAddOnActive   = "setting.openAddOnActive"
    static let autoOpenAmountPad = "setting.autoOpenAmountPad"
    /// 「左へスワイプでコピー」のヒントを使用済みにしたか。コピーを1度でも行えば true
    static let copySwipeHintDone = "setting.copySwipeHintDone"
    /// 引き落とし日が土日祝なら翌営業日へ繰り下げる（日本ロケール・締日/支払日型のみ）
    static let shiftDueDateOffHoliday = "setting.shiftDueDateOffHoliday"
    static let paymentWindowDays = "setting.paymentWindowDays"
    static let exportFormat          = "setting.exportFormat"
    static let showCurrencySymbol    = "setting.showCurrencySymbol"
}

/// ユーザレベル
enum UserLevel: String, CaseIterable, Identifiable {
    case beginner = "beginner"
    case expert   = "expert"

    var id: String { rawValue }

    var localizedKey: String {
        switch self {
        case .beginner: "settings.userLevel.beginner"
        case .expert:   "settings.userLevel.expert"
        }
    }
}

/// 外観モード
enum AppearanceMode: String, CaseIterable, Identifiable {
    case automatic = "automatic"
    case light     = "light"
    case dark      = "dark"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .automatic: nil
        case .light:     .light
        case .dark:      .dark
        }
    }

    var localizedKey: String {
        switch self {
        case .automatic: "settings.appearance.automatic"
        case .light:     "settings.appearance.light"
        case .dark:      "settings.appearance.dark"
        }
    }
}

/// フォントサイズ倍率
enum FontScale: String, CaseIterable, Identifiable {
    case system   = "system"    // 自動　システム設定に合わせる
    case standard = "standard"  // 標準　1.0
    case large    = "large"     // 大　　1.5倍相当 (.xxxLarge)
    case xLarge   = "xLarge"    // 特大　2.0倍相当 (.accessibility2)

    var id: String { rawValue }

    var localizedKey: String {
        switch self {
        case .system:  "settings.fontScale.system"
        case .standard: "settings.fontScale.standard"
        case .large:    "settings.fontScale.large"
        case .xLarge:   "settings.fontScale.xLarge"
        }
    }

    var followsSystem: Bool {
        self == .system
    }

    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .system:   .large
        case .standard: .large
        case .large:    .xxxLarge
        case .xLarge:   .accessibility2
        }
    }

    /// 固定サイズ指定が必要なUI向けの補正倍率
    var uiScale: CGFloat {
        switch self {
        case .system:   1.0
        case .standard: 1.0
        case .large:    1.2
        case .xLarge:   1.35
        }
    }
}

/// アプリ内文字サイズ設定をシートにも明示適用する
struct AppFontScaleModifier: ViewModifier {
    let fontScale: FontScale

    func body(content: Content) -> some View {
        if fontScale.followsSystem {
            content
        } else {
            content.dynamicTypeSize(fontScale.dynamicTypeSize)
        }
    }
}

extension View {
    /// アプリ内文字サイズ設定を適用する
    func appFontScale(_ fontScale: FontScale) -> some View {
        modifier(AppFontScaleModifier(fontScale: fontScale))
    }
}

/// 新しい決済入力後の動作
enum AfterSaveAction: String, CaseIterable, Identifiable {
    case goBack      = "goBack"
    case continuous  = "continuous"
    case sameDayCard = "sameDayCard"
    case showHistory = "showHistory"

    var id: String { rawValue }

    var localizedKey: String {
        switch self {
        case .goBack:      "settings.afterSave.goBack"
        case .continuous:  "settings.afterSave.continuous"
        case .sameDayCard: "settings.afterSave.sameDayCard"
        case .showHistory: "settings.afterSave.showHistory"
        }
    }
}

/// 旧 GD_OptE4SortMode / GD_OptE5SortMode
enum SortMode: Int, CaseIterable, Identifiable {
    case recent = 0
    case count  = 1
    case amount = 2
    case name   = 3

    var id: Int { rawValue }

    var localizedKey: String {
        switch self {
        case .recent: "sort.recent"
        case .count:  "sort.count"
        case .amount: "sort.amount"
        case .name:   "sort.name"
        }
    }
}

/// 編集系画面が未保存変更を持つかどうかをアプリ全体で共有するクラス
/// ContentView の起動時新規追加ロジックがこれを参照してスキップ判定する
@Observable
final class AppEditingState {
    /// いずれかの編集画面に未保存変更がある場合は true
    var isEditingInProgress = false
}

/// アプリ全体で使う日付表示フォーマット
enum AppDateFormat {
    /// 単体表示: 年
    static func yearText(_ date: Date) -> String {
        yearFormatter.string(from: date)
    }

    /// 上段表示: 年(曜)
    static func yearWeekdayText(_ date: Date) -> String {
        if Locale.current.identifier.hasPrefix("ja") {
            return jaYearWeekdayFormatter.string(from: date)
        }
        if Locale.current.identifier.hasPrefix("en") {
            // en 2行表示: 1行目は "yyyy EEE"
            return enYearWeekdayTwoLineFormatter.string(from: date)
        }
        return date.formatted(.dateTime.year().weekday(.abbreviated))
    }

    /// 下段表示: 月/日
    static func monthDayText(_ date: Date) -> String {
        monthDayFormatter.string(from: date)
    }

    /// 単体表示: 曜日
    static func weekdayText(_ date: Date) -> String {
        if Locale.current.identifier.hasPrefix("ja") {
            return jaWeekdayFormatter.string(from: date)
        }
        if Locale.current.identifier.hasPrefix("en") {
            return enWeekdayFormatter.string(from: date)
        }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }

    /// 1行表示: 年 月/日(曜)
    static func singleLineText(_ date: Date) -> String {
        if Locale.current.identifier.hasPrefix("en") {
            // en 1行表示: "EEE, M/d yyyy"
            return enSingleLineFormatter.string(from: date)
        }
        return "\(yearText(date)) \(monthDayWeekdayText(date))"
    }

    /// 1行表示用: 月/日(曜)
    static func monthDayWeekdayText(_ date: Date) -> String {
        if Locale.current.identifier.hasPrefix("ja") {
            return jaMonthDayWeekdayFormatter.string(from: date)
        }
        if Locale.current.identifier.hasPrefix("en") {
            return enMonthDayWeekdayFormatter.string(from: date)
        }
        return date.formatted(.dateTime.month().day().weekday(.abbreviated))
    }

    private static let jaYearWeekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy(E)"
        return formatter
    }()

    private static let enYearWeekdayTwoLineFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "yyyy EEE"
        return formatter
    }()
    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "yyyy"
        return formatter
    }()

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "M/d"
        return formatter
    }()
    private static let jaWeekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "E"
        return formatter
    }()
    private static let enWeekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "EEE"
        return formatter
    }()
    private static let jaMonthDayWeekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d(E)"
        return formatter
    }()
    private static let enMonthDayWeekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "M/d(EEE)"
        return formatter
    }()
    private static let enSingleLineFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "EEE, M/d yyyy"
        return formatter
    }()
}
