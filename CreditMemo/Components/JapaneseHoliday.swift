import Foundation

/// 日本の祝日判定（1948年法施行〜2099年想定）。
/// - 固定祝日／ハッピーマンデー／春分・秋分（簡略天文式）
/// - 振替休日（祝日が日曜の場合、その後最初の平日）
/// - 国民の休日（祝日に挟まれた平日）
/// - 2019・2020・2021 などの特例措置を個別に反映
///
/// 法改正があれば本ファイルの更新で追従する想定。
enum JapaneseHoliday {

    // MARK: - 公開API

    /// 指定日が祝日（振替休日・国民の休日含む）か
    static func isHoliday(_ date: Date) -> Bool {
        holidayName(date) != nil
    }

    /// 指定日が土日か
    static func isWeekend(_ date: Date) -> Bool {
        let w = Calendar(identifier: .gregorian).component(.weekday, from: date)
        return w == 1 || w == 7
    }

    /// 銀行営業日（平日 かつ 祝日でない）
    static func isBusinessDay(_ date: Date) -> Bool {
        !isWeekend(date) && !isHoliday(date)
    }

    /// 指定日が営業日でなければ、翌営業日を返す。営業日ならそのまま返す
    static func nextBusinessDay(from date: Date) -> Date {
        let cal = Calendar(identifier: .gregorian)
        var current = cal.startOfDay(for: date)
        // 安全のため最大 30 日を上限にループ
        for _ in 0..<30 {
            if isBusinessDay(current) { return current }
            guard let next = cal.date(byAdding: .day, value: 1, to: current) else { return current }
            current = next
        }
        return current
    }

    // MARK: - 内部：祝日名

    /// 祝日名を返す（祝日でなければ nil）
    static func holidayName(_ date: Date) -> String? {
        let cal = Calendar(identifier: .gregorian)
        let comp = cal.dateComponents([.year, .month, .day], from: date)
        guard let y = comp.year, let m = comp.month, let d = comp.day else { return nil }
        if let name = fixedHoliday(year: y, month: m, day: d) { return name }
        if let name = happyMondayHoliday(year: y, month: m, day: d) { return name }
        if let name = equinoxHoliday(year: y, month: m, day: d) { return name }
        if let name = substituteHoliday(date: date) { return name }
        if let name = nationalHoliday(date: date) { return name }
        return nil
    }

    // MARK: - 固定祝日／特例

    private static func fixedHoliday(year: Int, month: Int, day: Int) -> String? {
        switch (month, day) {
        case (1, 1):  return "元日"
        case (2, 11) where year >= 1967: return "建国記念の日"
        case (2, 23) where year >= 2020: return "天皇誕生日"
        case (4, 29):
            if year >= 2007 { return "昭和の日" }
            if year >= 1989 { return "みどりの日" }
            return "天皇誕生日"
        case (5, 3):  return "憲法記念日"
        case (5, 4) where year >= 2007: return "みどりの日"
        case (5, 5):  return "こどもの日"
        case (8, 11) where year >= 2016 && year != 2020 && year != 2021: return "山の日"
        case (8, 10) where year == 2020: return "山の日"   // 五輪特例
        case (8, 8)  where year == 2021: return "山の日"   // 五輪特例
        case (11, 3): return "文化の日"
        case (11, 23) where year != 1989: return "勤労感謝の日"
        // 旧天皇誕生日（昭和→平成→令和の移行）
        case (12, 23) where year >= 1989 && year <= 2018: return "天皇誕生日"
        // 平成→令和の特例
        case (5, 1)   where year == 2019: return "天皇の即位の日"
        case (10, 22) where year == 2019: return "即位礼正殿の儀"
        // 2020・2021 五輪の海の日・スポーツの日移動
        case (7, 23) where year == 2020: return "海の日"
        case (7, 24) where year == 2020: return "スポーツの日"
        case (7, 22) where year == 2021: return "海の日"
        case (7, 23) where year == 2021: return "スポーツの日"
        default: return nil
        }
    }

    // MARK: - ハッピーマンデー

    private static func happyMondayHoliday(year: Int, month: Int, day: Int) -> String? {
        // 成人の日: 1月第2月曜 (2000〜)
        if year >= 2000, month == 1, day == nthMondayOfMonth(year: year, month: 1, n: 2) {
            return "成人の日"
        }
        // 海の日: 7月第3月曜 (2003〜)。2020・2021 は別途固定で扱う
        if year >= 2003, year != 2020, year != 2021, month == 7,
           day == nthMondayOfMonth(year: year, month: 7, n: 3) {
            return "海の日"
        }
        // 敬老の日: 9月第3月曜 (2003〜)
        if year >= 2003, month == 9, day == nthMondayOfMonth(year: year, month: 9, n: 3) {
            return "敬老の日"
        }
        // 体育の日 → 2020〜 スポーツの日: 10月第2月曜。2020・2021 は固定で扱う
        if year >= 2000, year != 2020, year != 2021, month == 10,
           day == nthMondayOfMonth(year: year, month: 10, n: 2) {
            return year >= 2020 ? "スポーツの日" : "体育の日"
        }
        return nil
    }

    /// 指定月の n 番目（1〜5）の月曜の日付（1〜31）
    private static func nthMondayOfMonth(year: Int, month: Int, n: Int) -> Int {
        var dc = DateComponents()
        dc.year = year; dc.month = month; dc.day = 1
        let cal = Calendar(identifier: .gregorian)
        guard let first = cal.date(from: dc) else { return 1 }
        let firstWeekday = cal.component(.weekday, from: first) // 1=日, 2=月, ..., 7=土
        // 月初から最初の月曜までの日数（月初が月曜なら0）
        let mondayOffset = (9 - firstWeekday) % 7
        return 1 + mondayOffset + (n - 1) * 7
    }

    // MARK: - 春分・秋分（簡略天文式：1980〜2099）

    private static func equinoxHoliday(year: Int, month: Int, day: Int) -> String? {
        if month == 3, day == vernalEquinoxDay(year: year) { return "春分の日" }
        if month == 9, day == autumnalEquinoxDay(year: year) { return "秋分の日" }
        return nil
    }

    /// 春分の日（1980〜2099）
    private static func vernalEquinoxDay(year: Int) -> Int {
        let y = Double(year)
        return Int(20.8431 + 0.242194 * (y - 1980)) - Int((y - 1980) / 4)
    }

    /// 秋分の日（1980〜2099）
    private static func autumnalEquinoxDay(year: Int) -> Int {
        let y = Double(year)
        return Int(23.2488 + 0.242194 * (y - 1980)) - Int((y - 1980) / 4)
    }

    // MARK: - 振替休日・国民の休日

    /// 振替休日：直前の祝日が日曜だった場合、その後最初の平日（祝日でない日）が振替休日
    private static func substituteHoliday(date: Date) -> String? {
        let cal = Calendar(identifier: .gregorian)
        // 当日が日曜なら振替対象にならない
        let weekday = cal.component(.weekday, from: date)
        if weekday == 1 { return nil }
        // 法施行（2007/9/23 以降の改正で連休対応）
        // 連続祝日でも遡って日曜祝日を探す（最大7日遡り）
        var prev = cal.date(byAdding: .day, value: -1, to: date) ?? date
        for _ in 0..<7 {
            let prevWeekday = cal.component(.weekday, from: prev)
            // 当日より手前の連続祝日を遡り、日曜祝日に当たったら振替
            if !isOriginalHoliday(prev) { return nil }
            if prevWeekday == 1 { return "振替休日" }
            guard let next = cal.date(byAdding: .day, value: -1, to: prev) else { return nil }
            prev = next
        }
        return nil
    }

    /// 国民の休日：祝日に挟まれた平日（土日除く）
    private static func nationalHoliday(date: Date) -> String? {
        let cal = Calendar(identifier: .gregorian)
        let weekday = cal.component(.weekday, from: date)
        guard weekday != 1, weekday != 7 else { return nil }
        guard let prev = cal.date(byAdding: .day, value: -1, to: date),
              let next = cal.date(byAdding: .day, value: 1, to: date) else { return nil }
        if isOriginalHoliday(prev) && isOriginalHoliday(next) {
            return "国民の休日"
        }
        return nil
    }

    /// 固定祝日・ハッピーマンデー・春分秋分のいずれかに該当するか
    /// （振替休日・国民の休日は含めない）
    private static func isOriginalHoliday(_ date: Date) -> Bool {
        let cal = Calendar(identifier: .gregorian)
        let comp = cal.dateComponents([.year, .month, .day], from: date)
        guard let y = comp.year, let m = comp.month, let d = comp.day else { return false }
        if fixedHoliday(year: y, month: m, day: d) != nil { return true }
        if happyMondayHoliday(year: y, month: m, day: d) != nil { return true }
        if equinoxHoliday(year: y, month: m, day: d) != nil { return true }
        return false
    }
}
