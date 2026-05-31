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
        (0..<partCount(for: record.payType)).map {
            billingDate(useDate: record.dateUse, card: card, partOffset: $0)
        }
    }

    /// E3record の各 E6part に対応する支払日リストを返す（未選択対応）
    static func partDates(record: E3record, card: E1card?) -> [Date] {
        (0..<partCount(for: record.payType)).map {
            billingDate(useDate: record.dateUse, card: card, partOffset: $0)
        }
    }

    /// E3record の各 E6part に対応する金額リストを返す
    static func partAmounts(record: E3record) -> [Decimal] {
        switch record.payType {
        case .lumpSum:
            return [record.nAmount]
        case .twoPayments:
            // まず合計を通貨精度へ正規化する（インポート値など精度超過を防ぐ）
            // 丸めは .plain（0.5 を絶対値方向へ切り上げる商業丸め）で統一する
            let total     = record.nAmount.roundedAmount()
            let half      = (total / 2).roundedAmount()
            // remainder は合計から half を引くことで必ず total と一致させる
            let remainder = total - half
            return [half, remainder]
        }
    }

    static func partCount(for payType: PayType) -> Int {
        switch payType {
        case .lumpSum:     return 1
        case .twoPayments: return 2
        }
    }

    // MARK: - Japanese Holiday Shift

    /// 日本ロケール・締日/支払日型のみ、設定 ON 時に土日祝なら翌営業日へ繰り下げる。
    /// N日後型は適用外（カード会社の運用が多様なので触らない）。
    private static func applyJapaneseHolidayShiftIfNeeded(_ date: Date, card: E1card) -> Date {
        // N日後型は対象外
        guard card.nClosingDay != 0 else { return date }
        // 日本ロケールのみ
        guard Locale.current.language.languageCode?.identifier == "ja" else { return date }
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
