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
    /// 起動（再表示）時に自動で開く画面の選択。旧 openAddOnActive を包含する
    static let launchAction      = "setting.launchAction"
    /// Siri 起動後に音声入力シートを自動で開く
    static let openVoiceInputOnActive = "setting.openVoiceInputOnActive"
    static let autoOpenAmountPad = "setting.autoOpenAmountPad"
    /// 2回払い入力を有効にする
    static let enableTwoPayments = "setting.enableTwoPayments"
    /// 音声入力を使う（既定 ON、日本ロケールのみ表示）
    static let enableVoiceInput  = "setting.enableVoiceInput"
    /// 音声入力の改善用に匿名診断を共有する
    static let shareVoiceInputDiagnostics = "setting.shareVoiceInputDiagnostics"
    /// 「左へスワイプでコピー」のヒントを使用済みにしたか。コピーを1度でも行えば true
    static let copySwipeHintDone = "setting.copySwipeHintDone"
    /// 新しい決済画面「決済一覧からコピー（類似決済）」セクションの開閉状態を保持する。
    /// 一度畳めば次回以降も畳んだまま開く。既定は展開（true）
    static let similarSectionExpanded = "setting.similarSectionExpanded"
    /// 引き落とし日が土日祝なら翌営業日へ繰り下げる（日本ロケール・締日/支払日型のみ）
    static let shiftDueDateOffHoliday = "setting.shiftDueDateOffHoliday"
    static let paymentWindowDays = "setting.paymentWindowDays"
    static let exportFormat          = "setting.exportFormat"
    static let showCurrencySymbol    = "setting.showCurrencySymbol"
    /// 引き落とし状況の配色プリセット
    static let badgePreset           = "setting.display.badgePreset"
    /// 引き落とし状況バッジの中央バンド高さ（base size 64 換算で 8..24）
    static let badgeMiddleHeight     = "setting.display.badgeMiddleHeight"
    /// 古い履歴の自動整理提案：次に提案してよい日時（referenceDate からの秒）。
    /// 「あとで」を選ぶと一定期間先へ進め、その日まで提案しない
    static let retentionSuggestSnoozeUntil = "setting.retention.suggestSnoozeUntil"
}

/// 古い履歴の自動整理提案のパラメータ（判断代行のためアプリ側で固定）
enum RetentionSuggest {
    /// 提案の基準となる保持年数（この年数より古い＝整理対象）
    static let years = 3
    /// 提案を出し始める古い決済の件数しきい値
    static let thresholdCount = 100
    /// 「あとで」を選んだあと、次に提案するまでの間隔（日）
    static let snoozeDays = 30
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

/// 起動（フォアグラウンド復帰）時に自動で開く画面
/// 旧・真偽値設定 openAddOnActive を包含し、選択肢に一般化したもの
enum LaunchAction: String, CaseIterable, Identifiable {
    case none            = "none"            // 何もしない（既定）
    case mainMenu        = "mainMenu"        // 主画面へ戻す
    case voiceNewPayment = "voiceNewPayment" // 音声で新しい決済
    case newPayment      = "newPayment"      // 新しい決済
    case paymentList     = "paymentList"     // 決済一覧

    var id: String { rawValue }

    var localizedKey: String {
        switch self {
        case .none:            "settings.launchAction.none"
        case .mainMenu:        "settings.launchAction.mainMenu"
        case .voiceNewPayment: "settings.launchAction.voiceNewPayment"
        case .newPayment:      "settings.launchAction.newPayment"
        case .paymentList:     "settings.launchAction.paymentList"
        }
    }

    /// 旧設定 openAddOnActive からの移行を含めて現在値を解決する。
    /// - 新キーが保存済みならそれを採用
    /// - 未保存かつ旧設定が ON なら .newPayment（旧挙動を維持）
    /// - それ以外は .none
    static func resolve(defaults: UserDefaults = .standard) -> LaunchAction {
        if let raw = defaults.string(forKey: AppStorageKey.launchAction),
           let action = LaunchAction(rawValue: raw) {
            return action
        }
        if defaults.bool(forKey: AppStorageKey.openAddOnActive) {
            return .newPayment
        }
        return .none
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
    /// 年を先頭に読む大エンディアン文化（日本語・中国語・韓国語）かどうか。
    /// 段組み日付で「年→月日→曜日」順にするか「曜日→月日→年」順にするかの判定に使う。
    static var usesYearFirstLayout: Bool {
        guard let code = Locale.current.language.languageCode?.identifier else { return false }
        return ["ja", "zh", "ko"].contains(code)
    }

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

    /// 1行表示の日付
    static func singleLineText(_ date: Date) -> String {
        if usesYearFirstLayout {
            // 日中韓（大エンディアン）: 年 → 月日(曜)
            return "\(yearText(date)) \(monthDayWeekdayText(date))"
        }
        // 西欧(en/de/fr/es…): 年の位置も含めて地域の並びに任せる（独 "Fr., 5.6.2026" 等）
        return westernSingleLineFormatter.string(from: date)
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

    /// 自動ロケールのテンプレート方式フォーマッタ。
    /// フィールドの並び順・区切り記号は地域（en_US は月→日、独仏西などは日→月）に追従する
    private static func autoTemplateFormatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    private static let jaYearWeekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy(E)"
        return formatter
    }()

    // en を含む非 ja ロケールは並び順を地域へ追従させる
    private static let enYearWeekdayTwoLineFormatter = autoTemplateFormatter("yyyyEEE")
    // 年のみは並び順の問題がなく、ja テンプレートだと「2026年」になるため数字だけの固定書式にする
    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "yyyy"
        return formatter
    }()
    private static let monthDayFormatter = autoTemplateFormatter("Md")
    private static let jaWeekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "E"
        return formatter
    }()
    private static let enWeekdayFormatter = autoTemplateFormatter("EEE")
    private static let jaMonthDayWeekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d(E)"
        return formatter
    }()
    private static let enMonthDayWeekdayFormatter = autoTemplateFormatter("MdEEE")
    // 西欧の1行表示。年・月日・曜日の並びを地域へ完全に委ねる（年は末尾に来る）
    private static let westernSingleLineFormatter = autoTemplateFormatter("yyyyMdEEE")
}
