import Foundation
import SwiftData
import Testing
@testable import CreditMemo

/// BillingService の支払日計算（締日・支払日・支払月・月末・うるう年・N日後型・祝日繰り下げ）。
///
/// 日付は BillingService と同じ Calendar.current で組み立て、日付成分を一致させる
/// （TestStore.date は JST 固定なのでマシン TZ 差で日がずれ得る。ここでは使わない）。
/// 締日/支払日型は設定 ON のとき翌営業日へ繰り下がるため、期待値側にも同じ規則を適用して比較する
/// （繰り下げ自体の網羅は afterDays 除外・営業日移動の専用テストで確認する）。
@MainActor
struct BillingDateTests {
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d)) ?? Date()
    }

    private func holidayShiftEnabled() -> Bool {
        (UserDefaults.standard.object(forKey: AppStorageKey.shiftDueDateOffHoliday) as? Bool) ?? true
    }

    /// 締日/支払日型の期待支払日。手計算した「繰り下げ前」の年月日に、コードと同じ祝日繰り下げを適用する。
    private func expectedClosingPayDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
        let raw = date(y, m, d)
        return holidayShiftEnabled() ? JapaneseHoliday.nextBusinessDay(from: raw) : raw
    }

    private func sameDay(_ a: Date, _ b: Date) -> Bool {
        Calendar.current.isDate(a, inSameDayAs: b)
    }

    // 締日以内は支払月ぶん、締日超えはさらに+1か月ずれる
    @Test("締日と締日跨ぎで支払月が決まる")
    func closingAndOverCloseComputesPayMonth() throws {
        let context = try TestStore.makeContext()
        let card = TestFixtures.makeCard(name: "C", closingDay: 15, payDay: 10, payMonth: 1, in: context)

        // 6/10 は締日(15)以内 → 翌月(7)/10
        #expect(sameDay(BillingService.billingDate(useDate: date(2025, 6, 10), card: card),
                        expectedClosingPayDate(2025, 7, 10)))
        // 6/20 は締日超え → さらに+1か月 → 8/10
        #expect(sameDay(BillingService.billingDate(useDate: date(2025, 6, 20), card: card),
                        expectedClosingPayDate(2025, 8, 10)))
    }

    // 支払月 0（当月）/ 2（2か月後）で請求月がずれる
    @Test("支払月オフセットで請求月がずれる")
    func payMonthOffsetShiftsBillingMonth() throws {
        let context = try TestStore.makeContext()
        let sameMonth = TestFixtures.makeCard(name: "M0", closingDay: 15, payDay: 10, payMonth: 0, in: context)
        let twoMonths = TestFixtures.makeCard(name: "M2", closingDay: 15, payDay: 10, payMonth: 2, in: context)

        // payMonth0・締日以内 → 当月 6/10
        #expect(sameDay(BillingService.billingDate(useDate: date(2025, 6, 10), card: sameMonth),
                        expectedClosingPayDate(2025, 6, 10)))
        // payMonth2・締日以内 → 2か月後 8/10
        #expect(sameDay(BillingService.billingDate(useDate: date(2025, 6, 10), card: twoMonths),
                        expectedClosingPayDate(2025, 8, 10)))
    }

    // payDay=29 は「月末」の意味で、対象月の最終日へ丸める
    @Test("支払日29は対象月の月末になる")
    func payDay29ResolvesToMonthEnd() throws {
        let context = try TestStore.makeContext()
        let card = TestFixtures.makeCard(name: "EOM", closingDay: 15, payDay: 29, payMonth: 1, in: context)

        // 5/10 利用 → 6月払い → 6月末(30日)
        #expect(sameDay(BillingService.billingDate(useDate: date(2025, 5, 10), card: card),
                        expectedClosingPayDate(2025, 6, 30)))
        // 1/10 利用 → 2月払い(非うるう) → 2/28
        #expect(sameDay(BillingService.billingDate(useDate: date(2025, 1, 10), card: card),
                        expectedClosingPayDate(2025, 2, 28)))
    }

    // うるう年は月末（締日29・支払日29）が2月29日になる
    @Test("うるう年で2月末が29日になる")
    func leapYearAffectsMonthEndAndClosing() throws {
        let context = try TestStore.makeContext()
        let payEndCard = TestFixtures.makeCard(name: "EOM", closingDay: 15, payDay: 29, payMonth: 1, in: context)
        // 2024/1/10 → 2月払い(うるう) → 2/29
        #expect(sameDay(BillingService.billingDate(useDate: date(2024, 1, 10), card: payEndCard),
                        expectedClosingPayDate(2024, 2, 29)))
        // 2025/1/10 → 2月払い(平年) → 2/28
        #expect(sameDay(BillingService.billingDate(useDate: date(2025, 1, 10), card: payEndCard),
                        expectedClosingPayDate(2025, 2, 28)))

        // 締日29 は利用月の月末扱い。うるう年2/29 利用は締日超えにならず翌月10日
        let closeEndCard = TestFixtures.makeCard(name: "CEND", closingDay: 29, payDay: 10, payMonth: 1, in: context)
        #expect(sameDay(BillingService.billingDate(useDate: date(2024, 2, 29), card: closeEndCard),
                        expectedClosingPayDate(2024, 3, 10)))
    }

    // 支払月・締日跨ぎで月が12を超えたら翌年へ繰り上がる
    @Test("月あふれは翌年へ繰り上がる")
    func monthOverflowRollsIntoNextYear() throws {
        let context = try TestStore.makeContext()
        let card = TestFixtures.makeCard(name: "Y", closingDay: 15, payDay: 10, payMonth: 2, in: context)
        // 2025/11/20（締日超え）→ +payMonth2 +1 = +3か月 → 2026/2/10
        #expect(sameDay(BillingService.billingDate(useDate: date(2025, 11, 20), card: card),
                        expectedClosingPayDate(2026, 2, 10)))
    }

    // N日後型（締日0）は利用日+payDay日。分割は月ずらししてから加算する。祝日繰り下げは対象外。
    @Test("N日後型は日数加算し、祝日繰り下げしない")
    func afterDaysTypeAddsDaysAndSkipsHolidayShift() throws {
        let context = try TestStore.makeContext()
        let card = TestFixtures.makeCard(name: "AF", closingDay: 0, payDay: 40, payMonth: 0, in: context)

        // 2025/1/15 + 40日 = 2025/2/24
        #expect(sameDay(BillingService.billingDate(useDate: date(2025, 1, 15), card: card),
                        date(2025, 2, 24)))
        // 分割2回目: +1か月してから+40日 → 2025/2/15 +40日 = 2025/3/27
        #expect(sameDay(BillingService.billingDate(useDate: date(2025, 1, 15), card: card, partOffset: 1),
                        date(2025, 3, 27)))

        // 週末に着地する N日後型は繰り下げず、その週末日のまま
        let nextDayCard = TestFixtures.makeCard(name: "AF1", closingDay: 0, payDay: 1, payMonth: 0, in: context)
        let sundayResult = BillingService.billingDate(useDate: date(2025, 1, 4), card: nextDayCard) // 土 +1 = 日
        #expect(sameDay(sundayResult, date(2025, 1, 5)))
        #expect(JapaneseHoliday.isWeekend(sundayResult))   // 繰り下げされていない証拠
    }

    // 締日/支払日型は、支払日が週末に着地したら（設定ON時）翌営業日へ繰り下げる
    @Test("締日/支払日型は週末着地を翌営業日へ繰り下げる")
    func closingPayTypeAppliesHolidayShift() throws {
        let context = try TestStore.makeContext()
        let card = TestFixtures.makeCard(name: "H", closingDay: 15, payDay: 10, payMonth: 1, in: context)

        // 4/10 利用 → 5/10 払い。2025-05-10 は土曜
        let rawSaturday = date(2025, 5, 10)
        #expect(JapaneseHoliday.isWeekend(rawSaturday))   // シナリオ前提: raw は週末

        let result = BillingService.billingDate(useDate: date(2025, 4, 10), card: card)
        // コードと同じ規則で補正した期待値と一致する
        #expect(sameDay(result, expectedClosingPayDate(2025, 5, 10)))
        // 設定ONなら実際に営業日へ動く
        if holidayShiftEnabled() {
            #expect(JapaneseHoliday.isBusinessDay(result))
            #expect(!sameDay(result, rawSaturday))
        }
    }
}
