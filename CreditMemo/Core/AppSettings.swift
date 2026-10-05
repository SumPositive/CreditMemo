import Foundation
import SwiftUI

/// AppStorage キー定数
enum AppStorageKey {
    static let userLevel         = "setting.userLevel"
    static let appearanceMode    = "setting.appearanceMode"
    static let fontScale         = "setting.fontScale"
    static let tagSortMode       = "setting.tagSortMode"
    static let afterSaveAction   = "setting.afterSaveAction"
    /// テンキーの丸め方法。既定は四捨五入
    static let calculatorRounding = "setting.calculatorRounding"
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
    /// 「よくある決済」カプセル帯の表示行数（1〜10）。ハンドルのドラッグで変更・永続化。既定3
    static let frequentPaymentRows = "setting.frequentPaymentRows"
    /// 新しい決済の入力補助（なし／決済一覧からコピー／よくある決済）。既定はよくある決済
    static let newPaymentAssist = "setting.newPaymentAssist"
    /// 「よくある決済」ラベル抽出期間（月数：3/6/12/24/36）。既定12（1年）
    static let frequentPeriod = "setting.frequentPeriod"
    /// 「よくある決済」金額付きカプセルを出す条件（しない／3回以上／5回以上）。既定3回以上
    static let frequentAmountRule = "setting.frequentAmountRule"
    /// 「よくある決済」カプセルの並び順（よく使う順／最近使った順）。既定よく使う順
    static let frequentSortOrder = "setting.frequentSortOrder"
    /// 「よくある決済」に繰り返し決済も含めるか。既定 false（従来どおり除外）
    static let frequentIncludeRepeat = "setting.frequentIncludeRepeat"
    /// 「よくある決済」候補にする最小利用回数（1/2/3）。既定1
    static let frequentMinUses = "setting.frequentMinUses"
    /// 金額付きカプセルがあるとき、金額なしの基本カプセルを隠すか。既定 false
    static let frequentHideBaseWhenAmounts = "setting.frequentHideBaseWhenAmounts"
    /// 「よくある決済」ラベル一覧の並べ方（均等／左寄せ／中央寄せ／右寄せ）。既定は均等
    static let frequentAlignment = "setting.frequentAlignment"
    /// カプセルに決済手段の色（IDから一意生成）を表示するか。既定 false
    static let frequentShowCardColor = "setting.frequentShowCardColor"
    /// 一度きりの設定移行：テンキー自動表示を強制OFFにする処理を実行済みか（v○○更新時対応）
    static let didForceOffAutoOpenAmountPad = "setting.didForceOffAutoOpenAmountPad"
    /// 引き落とし日が土日祝なら翌営業日へ繰り下げる（日本ロケール・締日/支払日型のみ）
    static let shiftDueDateOffHoliday = "setting.shiftDueDateOffHoliday"
    static let paymentWindowDays = "setting.paymentWindowDays"
    /// 引き落とし状況で最後に選んだ集計タブ、初期値は口座
    static let paymentGroupMode = "setting.paymentGroupMode"
    /// 引き落とし状況で最後に選んだ絞り込み種別
    static let paymentFilterMode = "setting.paymentFilterMode"
    /// 引き落とし状況で最後に選んだ決済手段ID
    static let paymentFilterCardID = "setting.paymentFilterCardID"
    /// 引き落とし状況で最後に選んだ口座ID
    static let paymentFilterBankID = "setting.paymentFilterBankID"
    /// 引き落とし状況で最後に選んだタグID
    static let paymentFilterTagID = "setting.paymentFilterTagID"
    /// 照合途中として保存した請求合計
    static let reconciliationProgressAmounts = "reconciliation.progressAmounts"
    /// 通常画面のバナー広告を表示する、初期値はOFF
    static let showBannerAds = "setting.showBannerAds"
    static let exportFormat          = "setting.exportFormat"
    static let showCurrencySymbol    = "setting.showCurrencySymbol"
    /// 引き落とし状況の配色プリセット
    static let badgePreset           = "setting.display.badgePreset"
    /// 引き落とし状況バッジの中央バンド高さ（base size 64 換算で 8..24）
    static let badgeMiddleHeight     = "setting.display.badgeMiddleHeight"
    /// 履歴のタグ絞り込みの一致条件（OR／AND）。既定はOR
    static let tagMatchMode      = "setting.tagMatchMode"
    /// 古い履歴の自動整理提案：次に提案してよい日時（referenceDate からの秒）。
    /// 「あとで」を選ぶと一定期間先へ進め、その日まで提案しない
    static let retentionSuggestSnoozeUntil = "setting.retention.suggestSnoozeUntil"
}

/// 引落確定額をアプリ起動中だけ保持する
@Observable
final class ConfirmedDebitAmountSessionStore {
    nonisolated(unsafe) static let shared = ConfirmedDebitAmountSessionStore()

    /// 手段と口座は同じIDでも混同しないよう別スコープにする
    enum Scope: Hashable {
        case card(String)
        case bank(String)
    }

    private struct Key: Hashable {
        let scope: Scope
        let date: Date
    }

    private var amounts: [Key: Decimal] = [:]

    func amount(for scope: Scope, date: Date) -> Decimal? {
        amounts[key(for: scope, date: date)]
    }

    func setAmount(_ amount: Decimal, for scope: Scope, date: Date) {
        amounts[key(for: scope, date: date)] = amount
    }

    func removeAmount(for scope: Scope, date: Date) {
        amounts.removeValue(forKey: key(for: scope, date: date))
    }

    /// 同じ引落日を時刻差で別扱いしないよう日初へそろえる
    private func key(for scope: Scope, date: Date) -> Key {
        Key(scope: scope, date: AppCalendar.gregorian.startOfDay(for: date))
    }
}

/// 照合途中の請求合計を再起動後も復元する
@Observable
final class ReconciliationProgressStore {
    nonisolated(unsafe) static let shared = ReconciliationProgressStore()

    private var amounts: [String: String]

    private init() {
        amounts = UserDefaults.standard.dictionary(
            forKey: AppStorageKey.reconciliationProgressAmounts
        ) as? [String: String] ?? [:]
    }

    func amount(forCardID cardID: String, date: Date) -> Decimal? {
        guard let value = amounts[key(forCardID: cardID, date: date)] else { return nil }
        return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
    }

    func setAmount(_ amount: Decimal, forCardID cardID: String, date: Date) {
        amounts[key(forCardID: cardID, date: date)] = NSDecimalNumber(decimal: amount).stringValue
        save()
    }

    func removeAmount(forCardID cardID: String, date: Date) {
        amounts.removeValue(forKey: key(forCardID: cardID, date: date))
        save()
    }

    /// 保存中の照合途中を（決済手段ID, 引き落とし日）で列挙する
    var entries: [(cardID: String, date: Date)] {
        amounts.keys.compactMap { key in
            // 決済手段IDに区切り文字が含まれても壊れないよう、最後の区切りで分ける
            guard let separator = key.lastIndex(of: "|"),
                  let interval = TimeInterval(key[key.index(after: separator)...]) else { return nil }
            return (String(key[..<separator]), Date(timeIntervalSinceReferenceDate: interval))
        }
    }

    /// 照合途中をすべて破棄する（データ取込で請求が作り直されたときなど）
    func removeAll() {
        guard !amounts.isEmpty else { return }
        amounts.removeAll()
        save()
    }

    /// 同じ引落日を時刻差で別扱いしない識別子へそろえる
    private func key(forCardID cardID: String, date: Date) -> String {
        let day = AppCalendar.gregorian.startOfDay(for: date)
        return "\(cardID)|\(day.timeIntervalSinceReferenceDate)"
    }

    /// 照合途中の請求合計を設定領域へ保存する
    private func save() {
        UserDefaults.standard.set(amounts, forKey: AppStorageKey.reconciliationProgressAmounts)
    }
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

/// 起動時に一度だけ実行する設定移行。
/// 起動経路（AppMain）から切り離してテストできるよう、UserDefaults を差し替え可能にする
enum OneTimeSettingsMigration {
    /// 一度きりの設定移行を必要なら適用する。実行済みフラグで二重適用を防ぐ。
    ///
    /// 現状の内容：「よくある決済」カプセル導入に合わせ、テンキー自動表示を強制OFFにする
    /// （新旧ユーザーとも1回だけ。以降は設定で自由にON/OFFでき、その値は上書きしない）。
    /// - Returns: 実際に移行を適用したら true、実行済みで何もしなければ false
    @discardableResult
    static func applyIfNeeded(defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: AppStorageKey.didForceOffAutoOpenAmountPad) else {
            return false
        }
        defaults.set(false, forKey: AppStorageKey.autoOpenAmountPad)
        defaults.set(true, forKey: AppStorageKey.didForceOffAutoOpenAmountPad)
        return true
    }
}

/// 新しい決済画面で、金額欄の上に出す入力補助。
/// 「よくある決済」カプセルか、「決済一覧からコピー」セクションかを選ぶ（既定はよくある決済）。
enum NewPaymentAssist: String, CaseIterable, Identifiable {
    case none        = "none"          // 補助なし
    case copyFromList = "copyFromList" // 決済一覧からコピー（類似候補）
    case frequent    = "frequent"      // よくある決済（既定）

    var id: String { rawValue }

    var localizedKey: String {
        switch self {
        case .none:         "settings.newPaymentAssist.none"
        case .copyFromList: "settings.newPaymentAssist.copyFromList"
        case .frequent:     "settings.newPaymentAssist.frequent"
        }
    }
}

/// 「よくある決済」候補のラベル抽出期間（この期間内の実績だけを集計対象にする）。
enum FrequentPeriod: Int, CaseIterable, Identifiable {
    case months3 = 3
    case months6 = 6
    case year1   = 12
    case year2   = 24
    case year3   = 36

    var id: Int { rawValue }
    /// 集計に使う月数
    var months: Int { rawValue }

    var localizedKey: String {
        switch self {
        case .months3: "settings.frequent.period.months3"
        case .months6: "settings.frequent.period.months6"
        case .year1:   "settings.frequent.period.year1"
        case .year2:   "settings.frequent.period.year2"
        case .year3:   "settings.frequent.period.year3"
        }
    }
}

/// 金額付きカプセル（「ラベル ¥金額」）を出す条件。
enum FrequentAmountRule: String, CaseIterable, Identifiable {
    case off       = "off"    // 金額付きカプセルを出さない（ラベルのみ）
    case threePlus = "three"  // 同額が3回以上（既定）
    case fivePlus  = "five"   // 同額が5回以上

    var id: String { rawValue }
    /// 金額付きカプセルに必要な最小回数（nil＝金額付きカプセルを出さない）
    var minCount: Int? {
        switch self {
        case .off:       nil
        case .threePlus: 3
        case .fivePlus:  5
        }
    }

    var localizedKey: String {
        switch self {
        case .off:       "settings.frequent.amount.off"
        case .threePlus: "settings.frequent.amount.three"
        case .fivePlus:  "settings.frequent.amount.five"
        }
    }
}

/// 「よくある決済」候補にするラベルの最小利用回数。
enum FrequentMinUses: Int, CaseIterable, Identifiable {
    case one   = 1
    case two   = 2
    case three = 3

    var id: Int { rawValue }
    var count: Int { rawValue }

    var localizedKey: String {
        switch self {
        case .one:   "settings.frequent.minUses.one"
        case .two:   "settings.frequent.minUses.two"
        case .three: "settings.frequent.minUses.three"
        }
    }
}

/// 「よくある決済」カプセルの並び順。
/// 「よくある決済」ラベル一覧をカプセルで並べるときの寄せ方。
/// タグ一覧・タグ複数選択シートは常に均等なので、この設定は使わない
enum CapsuleAlignment: String, CaseIterable, Identifiable {
    case justified = "justified" // 均等に（間隔は固定でカプセル幅を広げる。最終行も同じ、既定）
    case leading  = "leading"   // 左寄せ
    case center   = "center"    // 中央寄せ
    case trailing = "trailing"  // 右寄せ

    var id: String { rawValue }

    var localizedKey: String {
        switch self {
        case .justified: "settings.frequent.alignment.justified"
        case .leading:   "settings.frequent.alignment.leading"
        case .center:    "settings.frequent.alignment.center"
        case .trailing:  "settings.frequent.alignment.trailing"
        }
    }

    /// AZFlowLayout へ渡す行内の寄せ。均等は行幅いっぱいに広げるので寄せは効かない
    var horizontalAlignment: HorizontalAlignment {
        switch self {
        case .justified: .center
        case .leading:   .leading
        case .center:    .center
        case .trailing:  .trailing
        }
    }

    /// 各行の余りをカプセル幅へ配って行幅いっぱいに広げるか（間隔は固定）
    var isJustified: Bool { self == .justified }
}

enum FrequentSortOrder: String, CaseIterable, Identifiable {
    case frequency = "frequency"  // よく使う順（頻度×最近性、既定）
    case recency   = "recency"    // 最近使った順

    var id: String { rawValue }

    var localizedKey: String {
        switch self {
        case .frequency: "settings.frequent.sort.frequency"
        case .recency:   "settings.frequent.sort.recency"
        }
    }
}

/// 旧 GD_OptE4SortMode / GD_OptE5SortMode
enum SortMode: Int, CaseIterable, Identifiable {
    case recent = 0
    case count  = 1
    case amount = 2
    case name   = 3

    /// タグ一覧とタグ選択シートの既定値
    static let defaultForTags: SortMode = .count

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

/// 複数タグで絞り込む時の一致条件
enum TagMatchMode: Int, CaseIterable, Identifiable {
    /// いずれかのタグを持つ明細を対象にする
    case or  = 0
    /// すべてのタグを持つ明細だけを対象にする
    case and = 1

    /// タグ絞り込みの既定値
    static let defaultMode: TagMatchMode = .or

    var id: Int { rawValue }

    var localizedKey: String {
        switch self {
        case .or:  "tag.match.or"
        case .and: "tag.match.and"
        }
    }

    /// 選択タグ名を列記する時の区切り記号
    var separator: String {
        switch self {
        case .or:  " / "
        case .and: " & "
        }
    }

    /// 明細のタグが絞り込み条件に一致するか。
    /// 選択タグが空のときは絞り込みをかけない（すべて対象）
    func matches(recordTagIDs: Set<String>, selectedTagIDs: Set<String>) -> Bool {
        if selectedTagIDs.isEmpty { return true }
        switch self {
        case .or:
            // いずれかのタグを持てば対象にする
            return !recordTagIDs.isDisjoint(with: selectedTagIDs)
        case .and:
            // 選択したタグをすべて持つ明細だけを対象にする
            return selectedTagIDs.isSubset(of: recordTagIDs)
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
        // 日本語以外は地域の並び順で年と曜日を表示する
        return localizedYearWeekdayFormatter.string(from: date)
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
        return localizedWeekdayFormatter.string(from: date)
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

    /// 1行表示の日付で、月日だけ大きく太くし、年・曜日・区切りは小さく薄くする
    static func singleLineAttributed(
        _ date: Date,
        font: Font = .title3.bold(),
        yearFont: Font = .footnote
    ) -> AttributedString {
        let plain = singleLineText(date)
        var text = AttributedString(plain)
        // 月日は呼び出し側の色（アクセントカラー等）をそのまま使う
        text.font = font

        // 並び順は地域で変わるため、年以外の数字が並ぶ範囲を「月日」とみなす
        // （例: "2026 10/3(土)" → "10/3"、"Sat, 10/3/2026" → "10/3"、"Sa., 3.10.2026" → "3.10"）
        let yearRange = plain.range(of: yearText(date))
        let monthDayOffsets = plain.indices.enumerated().compactMap { offset, index in
            plain[index].isNumber && !(yearRange?.contains(index) ?? false) ? offset : nil
        }
        // 月日が見つからない想定外の書式では全体を大きく見せる
        guard let first = monthDayOffsets.first, let last = monthDayOffsets.last else { return text }

        let lower = text.characters.index(text.startIndex, offsetBy: first)
        let upper = text.characters.index(text.startIndex, offsetBy: last + 1)
        // 月日の前後（年・曜日・区切り）は小さく、決済一覧の年と同じ控えめな色にする
        for range in [text.startIndex..<lower, upper..<text.endIndex] where !range.isEmpty {
            text[range].font = yearFont
            text[range].foregroundColor = Color(.secondaryLabel)
        }
        return text
    }

    /// 1行表示用: 月/日 曜（曜日のカッコは付けない）
    static func monthDayWeekdayText(_ date: Date) -> String {
        if Locale.current.identifier.hasPrefix("ja") {
            return jaMonthDayWeekdayFormatter.string(from: date)
        }
        let text = localizedMonthDayWeekdayFormatter.string(from: date)
        // 韓国語 "10. 3. (토)" など地域書式が付けるカッコを外す
        return text.filter { !"()（）".contains($0) }
    }

    /// 自動ロケールのテンプレート方式フォーマッタ。
    /// フィールドの並び順・区切り記号は地域（en_US は月→日、独仏西などは日→月）に追従する
    private static func autoTemplateFormatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        // 端末が和暦でも表示する年は保存・集計と同じ西暦に揃える
        formatter.calendar = AppCalendar.gregorian
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    private static let jaYearWeekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = AppCalendar.gregorian
        formatter.dateFormat = "yyyy(E)"
        return formatter
    }()

    // 非 ja ロケールは並び順を地域へ追従させる
    private static let localizedYearWeekdayFormatter = autoTemplateFormatter("yyyyEEE")
    // 年のみは並び順の問題がなく、ja テンプレートだと「2026年」になるため数字だけの固定書式にする
    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = AppCalendar.gregorian
        formatter.dateFormat = "yyyy"
        return formatter
    }()
    private static let monthDayFormatter = autoTemplateFormatter("Md")
    private static let jaWeekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = AppCalendar.gregorian
        formatter.dateFormat = "E"
        return formatter
    }()
    private static let localizedWeekdayFormatter = autoTemplateFormatter("EEE")
    private static let jaMonthDayWeekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = AppCalendar.gregorian
        formatter.dateFormat = "M/d E"
        return formatter
    }()
    private static let localizedMonthDayWeekdayFormatter = autoTemplateFormatter("MdEEE")
    // 西欧の1行表示。年・月日・曜日の並びを地域へ完全に委ねる（年は末尾に来る）
    private static let westernSingleLineFormatter = autoTemplateFormatter("yyyyMdEEE")
}
