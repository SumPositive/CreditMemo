import Foundation

/// クレジットカードの支払日計算
enum BillingService {
    // 決済手段未選択時の仮スケジュール（27日締め・翌月27日払い）
    static let fallbackClosingDay: Int16 = 27
    static let fallbackPayDay: Int16 = 27
    static let fallbackPayMonth: Int16 = 1

    /// 利用日とカード設定から n 番目の支払日を返す（partOffset=0 が 1 回目）
    static func billingDate(useDate: Date, card: E1card, partOffset: Int = 0) -> Date {
        let raw: Date
        // nClosingDay=0 は N日後型として扱う
        if card.nClosingDay == 0 {
            raw = billingDateAfterDays(
                useDate: useDate,
                // N日後型は nPayDay をそのまま日数として使う
                daysLater: Int(card.nPayDay),
                partOffset: partOffset
            )
        } else {
            raw = billingDate(
                useDate: useDate,
                closingDay: card.nClosingDay,
                payDay: card.nPayDay,
                payMonth: card.nPayMonth,
                partOffset: partOffset
            )
        }
        return applyJapaneseHolidayShiftIfNeeded(raw, card: card)
    }

    /// 決済手段未選択を含めた支払日を返す（未選択時は仮スケジュール）
    static func billingDate(useDate: Date, card: E1card?, partOffset: Int = 0) -> Date {
        if let card {
            return billingDate(useDate: useDate, card: card, partOffset: partOffset)
        }
        return billingDate(
            useDate: useDate,
            closingDay: fallbackClosingDay,
            payDay: fallbackPayDay,
            payMonth: fallbackPayMonth,
            partOffset: partOffset
        )
    }

    /// 日付計算の本体
    private static func billingDate(
        useDate: Date,
        closingDay: Int16,
        payDay: Int16,
        payMonth: Int16,
        partOffset: Int
    ) -> Date {
        let cal = Calendar.current
        let dc  = cal.dateComponents([.year, .month, .day], from: useDate)
        let useDay   = dc.day   ?? 1
        let useMonth = dc.month ?? 1
        let useYear  = dc.year  ?? cal.component(.year, from: useDate)

        let closingDayValue: Int = closingDay == 29
            ? daysInMonth(year: useYear, month: useMonth)
            : Int(closingDay)

        let overClose = closingDayValue < useDay ? 1 : 0
        let totalOffset = Int(payMonth) + overClose + partOffset

        return makeDate(year: useYear, month: useMonth + totalOffset, payDay: Int(payDay))
    }

    /// 都度 n 日後型の請求日計算
    private static func billingDateAfterDays(
        useDate: Date,
        daysLater: Int,
        partOffset: Int
    ) -> Date {
        let cal = Calendar.current
        let baseDate = cal.startOfDay(for: useDate)
        let monthShifted = cal.date(byAdding: .month, value: partOffset, to: baseDate) ?? baseDate
        let billed = cal.date(byAdding: .day, value: daysLater, to: monthShifted) ?? monthShifted
        return cal.startOfDay(for: billed)
    }

    /// E3record の各 E6part に対応する支払日リストを返す
    static func partDates(record: E3record, card: E1card) -> [Date] {
        (0..<record.payCount).map {
            billingDate(useDate: record.dateUse, card: card, partOffset: $0)
        }
    }

    /// E3record の各 E6part に対応する支払日リストを返す（未選択対応）
    static func partDates(record: E3record, card: E1card?) -> [Date] {
        (0..<record.payCount).map {
            billingDate(useDate: record.dateUse, card: card, partOffset: $0)
        }
    }

    /// E3record の各 E6part に対応する金額リストを返す
    static func partAmounts(record: E3record) -> [Decimal] {
        installmentAmounts(total: record.nAmount, count: record.payCount)
    }

    /// N 回払いの初期配分を返す。均等割し、端数は初回へ寄せる（初回調整）。
    /// カード分割・BNPL の一般的な慣行に合わせ、初回を高く以降を均等にする。
    /// count <= 1 のときは総額 1 件（一括）を返す。
    static func installmentAmounts(total: Decimal, count: Int, locale: Locale = .current) -> [Decimal] {
        let n = max(1, count)
        let roundedTotal = total.roundedAmount(locale: locale)
        if n == 1 {
            return [roundedTotal]
        }
        let totalMinor = (roundedTotal.minorUnits(locale: locale) as NSDecimalNumber).int64Value
        let baseMinor = totalMinor / Int64(n)
        let remainderMinor = totalMinor - baseMinor * Int64(n)
        var amounts: [Decimal] = []
        for index in 0..<n {
            // 端数（remainder）は初回に寄せ、2 回目以降は均等にする
            let minor = index == 0 ? baseMinor + remainderMinor : baseMinor
            amounts.append(Decimal.fromMinorUnits(Decimal(minor), locale: locale))
        }
        return amounts
    }

    /// 後方互換のため 2 回払いのショートカットを残す
    static func twoPaymentAmounts(total: Decimal, locale: Locale = .current) -> [Decimal] {
        installmentAmounts(total: total, count: 2, locale: locale)
    }

    static func partCount(for record: E3record) -> Int {
        record.payCount
    }

    // MARK: - Japanese Holiday Shift

    /// 締日/支払日型のみ、設定 ON 時に土日祝なら翌営業日へ繰り下げる。
    /// N日後型は適用外（カード会社の運用が多様なので触らない）。
    /// 設定 UI は日本ロケールでのみ表示されるが、判定自体は設定値に従い、
    /// ロケール文字列に依存しない（シミュレーター差異で取りこぼさないため）。
    private static func applyJapaneseHolidayShiftIfNeeded(_ date: Date, card: E1card) -> Date {
        // N日後型は対象外
        guard card.nClosingDay != 0 else { return date }
        // 設定キーはデフォルト ON。未設定なら true として扱う
        let key = AppStorageKey.shiftDueDateOffHoliday
        let on  = (UserDefaults.standard.object(forKey: key) as? Bool) ?? true
        guard on else { return date }
        return JapaneseHoliday.nextBusinessDay(from: date)
    }

    // MARK: - Private

    private static func daysInMonth(year: Int, month: Int) -> Int {
        var dc = DateComponents()
        dc.year = year; dc.month = month + 1; dc.day = 0
        return Calendar.current.dateComponents([.day],
            from: Calendar.current.date(from: dc)!).day ?? 28
    }

    private static func makeDate(year: Int, month: Int, payDay: Int) -> Date {
        let cal  = Calendar.current
        var dc   = DateComponents(); dc.year = year; dc.month = month
        let base = cal.date(from: dc) ?? Date()
        let bc   = cal.dateComponents([.year, .month], from: base)
        let y    = bc.year  ?? year
        let m    = bc.month ?? 1
        let maxD = daysInMonth(year: y, month: m)
        var fd   = DateComponents()
        fd.year = y; fd.month = m
        fd.day  = payDay == 29 ? maxD : min(payDay, maxD)
        return cal.date(from: fd) ?? base
    }
}
