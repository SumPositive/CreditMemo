import Foundation
import SwiftData
import Testing
@testable import CreditMemo

/// BillingService の支払日計算（締日・支払日・支払月・月末・うるう年・N日後型・祝日繰り下げ）。
///
/// 日付は BillingService と同じ Calendar.current で組み立て、日付成分を一致させる
/// （TestStore.date は JST 固定なのでマシン TZ 差で日がずれ得る。ここでは使わない）。
///
/// 祝日繰り下げ設定は UserDefaults.standard の実行時の値に依存させず、
/// 各テストで明示的に ON/OFF を設定して終了時に元へ戻す。
/// 期待値は JapaneseHoliday.nextBusinessDay を使わず具体的な日付を直書きし、
/// 繰り下げ関数自体の誤りも検出できるようにする。
///
/// 設定を書き換えるため、並列実行で他テストと干渉しないよう直列化する
@Suite(.serialized)
@MainActor
struct BillingDateTests {
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d)) ?? Date()
    }

    private func sameDay(_ a: Date, _ b: Date) -> Bool {
        Calendar.current.isDate(a, inSameDayAs: b)
    }

    /// 祝日繰り下げ設定を指定値にして body を実行し、必ず元の値へ戻す
    private func withHolidayShift<T>(_ enabled: Bool, _ body: () throws -> T) rethrows -> T {
        let key = AppStorageKey.shiftDueDateOffHoliday
        let original = UserDefaults.standard.object(forKey: key) as? Bool
        UserDefaults.standard.set(enabled, forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                // 未設定だった状態（既定 ON 扱い）へ戻す
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        return try body()
    }

    // MARK: - 繰り下げ OFF（純粋な支払日計算）

    // 締日以内は支払月ぶん、締日超えはさらに+1か月ずれる
    @Test("締日と締日跨ぎで支払月が決まる")
    func closingAndOverCloseComputesPayMonth() throws {
        let context = try TestStore.makeContext()
        let card = TestFixtures.makeCard(name: "C", closingDay: 15, payDay: 10, payMonth: 1, in: context)

        withHolidayShift(false) {
            // 6/10 は締日(15)以内 → 翌月(7)/10
            #expect(sameDay(BillingService.billingDate(useDate: date(2025, 6, 10), card: card),
                            date(2025, 7, 10)))
            // 6/20 は締日超え → さらに+1か月 → 8/10
            #expect(sameDay(BillingService.billingDate(useDate: date(2025, 6, 20), card: card),
                            date(2025, 8, 10)))
        }
    }

    // 支払月 0（当月）/ 2（2か月後）で請求月がずれる
    @Test("支払月オフセットで請求月がずれる")
    func payMonthOffsetShiftsBillingMonth() throws {
        let context = try TestStore.makeContext()
        let sameMonth = TestFixtures.makeCard(name: "M0", closingDay: 15, payDay: 10, payMonth: 0, in: context)
        let twoMonths = TestFixtures.makeCard(name: "M2", closingDay: 15, payDay: 10, payMonth: 2, in: context)

        withHolidayShift(false) {
            // payMonth0・締日以内 → 当月 6/10
            #expect(sameDay(BillingService.billingDate(useDate: date(2025, 6, 10), card: sameMonth),
                            date(2025, 6, 10)))
            // payMonth2・締日以内 → 2か月後 8/10
            #expect(sameDay(BillingService.billingDate(useDate: date(2025, 6, 10), card: twoMonths),
                            date(2025, 8, 10)))
        }
    }

    // payDay=29 は「月末」の意味で、対象月の最終日へ丸める
    @Test("支払日29は対象月の月末になる")
    func payDay29ResolvesToMonthEnd() throws {
        let context = try TestStore.makeContext()
        let card = TestFixtures.makeCard(name: "EOM", closingDay: 15, payDay: 29, payMonth: 1, in: context)

        withHolidayShift(false) {
            // 5/10 利用 → 6月払い → 6月末(30日)
            #expect(sameDay(BillingService.billingDate(useDate: date(2025, 5, 10), card: card),
                            date(2025, 6, 30)))
            // 1/10 利用 → 2月払い(非うるう) → 2/28
            #expect(sameDay(BillingService.billingDate(useDate: date(2025, 1, 10), card: card),
                            date(2025, 2, 28)))
        }
    }

    // うるう年は月末（締日29・支払日29）が2月29日になる
    @Test("うるう年で2月末が29日になる")
    func leapYearAffectsMonthEndAndClosing() throws {
        let context = try TestStore.makeContext()
        let payEndCard = TestFixtures.makeCard(name: "EOM", closingDay: 15, payDay: 29, payMonth: 1, in: context)
        let closeEndCard = TestFixtures.makeCard(name: "CEND", closingDay: 29, payDay: 10, payMonth: 1, in: context)

        withHolidayShift(false) {
            // 2024/1/10 → 2月払い(うるう) → 2/29
            #expect(sameDay(BillingService.billingDate(useDate: date(2024, 1, 10), card: payEndCard),
                            date(2024, 2, 29)))
            // 2025/1/10 → 2月払い(平年) → 2/28
            #expect(sameDay(BillingService.billingDate(useDate: date(2025, 1, 10), card: payEndCard),
                            date(2025, 2, 28)))
            // 締日29 は利用月の月末扱い。うるう年2/29 利用は締日超えにならず翌月10日
            #expect(sameDay(BillingService.billingDate(useDate: date(2024, 2, 29), card: closeEndCard),
                            date(2024, 3, 10)))
        }
    }

    // 支払月・締日跨ぎで月が12を超えたら翌年へ繰り上がる
    @Test("月あふれは翌年へ繰り上がる")
    func monthOverflowRollsIntoNextYear() throws {
        let context = try TestStore.makeContext()
        let card = TestFixtures.makeCard(name: "Y", closingDay: 15, payDay: 10, payMonth: 2, in: context)

        withHolidayShift(false) {
            // 2025/11/20（締日超え）→ +payMonth2 +1 = +3か月 → 2026/2/10
            #expect(sameDay(BillingService.billingDate(useDate: date(2025, 11, 20), card: card),
                            date(2026, 2, 10)))
        }
    }

    // MARK: - N日後型（設定によらず繰り下げない）

    // N日後型（締日0）は利用日+payDay日。分割は月ずらししてから加算する。祝日繰り下げは対象外。
    @Test("N日後型は日数加算し、設定ONでも祝日繰り下げしない")
    func afterDaysTypeAddsDaysAndSkipsHolidayShift() throws {
        let context = try TestStore.makeContext()
        let card = TestFixtures.makeCard(name: "AF", closingDay: 0, payDay: 40, payMonth: 0, in: context)
        let nextDayCard = TestFixtures.makeCard(name: "AF1", closingDay: 0, payDay: 1, payMonth: 0, in: context)

        // 繰り下げ ON でも N日後型は動かないことを確認する
        withHolidayShift(true) {
            // 2025/1/15 + 40日 = 2025/2/24
            #expect(sameDay(BillingService.billingDate(useDate: date(2025, 1, 15), card: card),
                            date(2025, 2, 24)))
            // 分割2回目: +1か月してから+40日 → 2025/2/15 +40日 = 2025/3/27
            #expect(sameDay(BillingService.billingDate(useDate: date(2025, 1, 15), card: card, partOffset: 1),
                            date(2025, 3, 27)))

            // 週末（日曜）に着地しても繰り下げず、その週末日のまま
            let sundayResult = BillingService.billingDate(useDate: date(2025, 1, 4), card: nextDayCard) // 土 +1 = 日
            #expect(sameDay(sundayResult, date(2025, 1, 5)))
            #expect(JapaneseHoliday.isWeekend(sundayResult))   // 繰り下げされていない証拠
        }
    }

    // MARK: - 祝日繰り下げ ON/OFF

    /// 2025-05-10(土) 着地。5/11 は日曜なので、繰り下げ先は 5/12(月)
    @Test("設定ONなら週末着地を翌営業日へ繰り下げる")
    func closingPayTypeAppliesHolidayShiftWhenEnabled() throws {
        let context = try TestStore.makeContext()
        let card = TestFixtures.makeCard(name: "H", closingDay: 15, payDay: 10, payMonth: 1, in: context)

        // シナリオ前提: 繰り下げ前の日付は週末
        #expect(JapaneseHoliday.isWeekend(date(2025, 5, 10)))

        withHolidayShift(true) {
            let result = BillingService.billingDate(useDate: date(2025, 4, 10), card: card)
            // 土 → 日を飛ばして月曜へ（期待日を直書きし、繰り下げ関数の誤りも検出する）
            #expect(sameDay(result, date(2025, 5, 12)))
            #expect(JapaneseHoliday.isBusinessDay(result))
        }
    }

    /// 祝日を挟む繰り下げ。2025-08-10(日) 着地 → 8/11 は山の日 → 8/12(火)
    @Test("設定ONなら祝日も飛ばして翌営業日へ繰り下げる")
    func holidayShiftSkipsNationalHoliday() throws {
        let context = try TestStore.makeContext()
        let card = TestFixtures.makeCard(name: "H2", closingDay: 15, payDay: 10, payMonth: 1, in: context)

        // シナリオ前提: 8/10 は日曜、8/11 は祝日（山の日）
        #expect(JapaneseHoliday.isWeekend(date(2025, 8, 10)))
        #expect(JapaneseHoliday.isHoliday(date(2025, 8, 11)))

        withHolidayShift(true) {
            // 6/20 利用（締日超え）→ 8/10 着地 → 日曜+祝日を飛ばして 8/12
            let result = BillingService.billingDate(useDate: date(2025, 6, 20), card: card)
            #expect(sameDay(result, date(2025, 8, 12)))
            #expect(JapaneseHoliday.isBusinessDay(result))
        }
    }

    /// 設定 OFF なら週末・祝日に着地したままにする
    @Test("設定OFFなら週末着地でも繰り下げない")
    func closingPayTypeKeepsWeekendWhenDisabled() throws {
        let context = try TestStore.makeContext()
        let card = TestFixtures.makeCard(name: "H3", closingDay: 15, payDay: 10, payMonth: 1, in: context)

        withHolidayShift(false) {
            let result = BillingService.billingDate(useDate: date(2025, 4, 10), card: card)
            // 繰り下げず 5/10(土) のまま
            #expect(sameDay(result, date(2025, 5, 10)))
            #expect(JapaneseHoliday.isWeekend(result))
        }
    }

    /// 設定 ON/OFF で結果が実際に変わることを 1 つのシナリオで対比する
    @Test("同一シナリオで設定ON/OFFの結果が異なる")
    func holidayShiftSettingChangesResult() throws {
        let context = try TestStore.makeContext()
        let card = TestFixtures.makeCard(name: "H4", closingDay: 15, payDay: 10, payMonth: 1, in: context)
        let useDate = date(2025, 4, 10)

        let off = withHolidayShift(false) { BillingService.billingDate(useDate: useDate, card: card) }
        let on = withHolidayShift(true) { BillingService.billingDate(useDate: useDate, card: card) }

        #expect(sameDay(off, date(2025, 5, 10)))
        #expect(sameDay(on, date(2025, 5, 12)))
        #expect(!sameDay(off, on))
    }
}
