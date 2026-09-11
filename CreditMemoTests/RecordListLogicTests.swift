import Foundation
import Testing
@testable import CreditMemo

/// 決済一覧の月計・タグ絞り込み・当日への頭出し。
///
/// 日付はテスト実行日に左右されないよう、固定のカレンダー（JST）で組み立てる。
struct RecordListLogicTests {

    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        return cal
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d)) ?? Date()
    }

    private func input(_ id: String, _ y: Int, _ m: Int, _ d: Int, _ amount: Decimal) -> RecordSummaryInput {
        RecordSummaryInput(id: id, dateUse: date(y, m, d), amount: amount)
    }

    private func totals(
        _ loaded: [RecordSummaryInput],
        totalCount: Int? = nil,
        nextUnloaded: Date? = nil
    ) -> [String: Decimal] {
        RecordMonthTotals.totalsByRecordID(
            loaded: loaded,
            totalCount: totalCount ?? loaded.count,
            nextUnloadedDate: nextUnloaded,
            calendar: calendar
        )
    }

    // MARK: - 月計

    @Test("月ごとの合計が、その月の最後の1件に付く")
    func totalsAttachToLastRecordOfMonth() {
        // 利用日の降順（画面の既定）
        let loaded = [
            input("a", 2026, 9, 20, 100),
            input("b", 2026, 9, 5, 200),
            input("c", 2026, 8, 30, 300),
        ]
        let result = totals(loaded)

        // 9月の合計は 9月の最後の1件（b）に付く
        #expect(result["b"] == 300)
        // 8月の合計は c に付く
        #expect(result["c"] == 300)
        // 月の途中である a には付かない
        #expect(result["a"] == nil)
        #expect(result.count == 2)
    }

    @Test("全件が同じ月なら、最後の1件にだけ合計が付く")
    func singleMonthGetsOneTotal() {
        let loaded = [
            input("a", 2026, 9, 20, 100),
            input("b", 2026, 9, 10, 200),
            input("c", 2026, 9, 1, 300),
        ]
        let result = totals(loaded)
        #expect(result == ["c": 600])
    }

    @Test("年をまたいでも別の月として合計する")
    func totalsSeparateAcrossYears() {
        let loaded = [
            input("a", 2027, 1, 5, 100),
            input("b", 2026, 12, 25, 200),
        ]
        let result = totals(loaded)
        #expect(result["a"] == 100)
        #expect(result["b"] == 200)
    }

    /// ページ境界の扱い。次ページに同じ月が続くなら、その月の合計はまだ確定しない
    @Test("次ページに同じ月が続くなら、その月の合計は出さない")
    func skipsTotalWhenMonthContinuesOnNextPage() {
        let loaded = [
            input("a", 2026, 9, 20, 100),
            input("b", 2026, 9, 5, 200),
        ]
        // 未読込の先頭も9月 → 9月の合計はまだ出せない
        let result = totals(loaded, totalCount: 3, nextUnloaded: date(2026, 9, 1))
        #expect(result.isEmpty)
    }

    @Test("次ページが別の月なら、その月の合計を出す")
    func showsTotalWhenNextPageStartsNewMonth() {
        let loaded = [
            input("a", 2026, 9, 20, 100),
            input("b", 2026, 9, 5, 200),
        ]
        // 未読込の先頭は8月 → 9月は確定したので合計を出す
        let result = totals(loaded, totalCount: 3, nextUnloaded: date(2026, 8, 31))
        #expect(result == ["b": 300])
    }

    @Test("ページ境界より前の月は、未読込があっても合計が出る")
    func earlierMonthsStillGetTotals() {
        let loaded = [
            input("a", 2026, 9, 20, 100),
            input("b", 2026, 8, 30, 200),
            input("c", 2026, 8, 10, 300),
        ]
        // 未読込の先頭は8月 → 8月は保留、9月は確定済み
        let result = totals(loaded, totalCount: 4, nextUnloaded: date(2026, 8, 1))
        #expect(result["a"] == 100)
        #expect(result["c"] == nil)
    }

    @Test("読み込み済みが空なら月計も空")
    func emptyLoadedProducesNoTotals() {
        #expect(totals([]).isEmpty)
    }

    // MARK: - タグ絞り込み（OR / AND）

    @Test("OR はいずれかのタグを持つ明細を通す")
    func orMatchesAnyTag() {
        let selected: Set<String> = ["food", "car"]
        #expect(TagMatchMode.or.matches(recordTagIDs: ["food"], selectedTagIDs: selected))
        #expect(TagMatchMode.or.matches(recordTagIDs: ["car"], selectedTagIDs: selected))
        #expect(TagMatchMode.or.matches(recordTagIDs: ["food", "car"], selectedTagIDs: selected))
        // 選択外のタグしか持たない明細は通さない
        #expect(!TagMatchMode.or.matches(recordTagIDs: ["hobby"], selectedTagIDs: selected))
        // タグなしの明細も通さない
        #expect(!TagMatchMode.or.matches(recordTagIDs: [], selectedTagIDs: selected))
    }

    @Test("AND は選択タグをすべて持つ明細だけを通す")
    func andRequiresAllTags() {
        let selected: Set<String> = ["food", "car"]
        #expect(TagMatchMode.and.matches(recordTagIDs: ["food", "car"], selectedTagIDs: selected))
        // 余分なタグを持っていても、選択分を満たせば通す
        #expect(TagMatchMode.and.matches(recordTagIDs: ["food", "car", "hobby"], selectedTagIDs: selected))
        // 片方しか持たない明細は通さない
        #expect(!TagMatchMode.and.matches(recordTagIDs: ["food"], selectedTagIDs: selected))
        #expect(!TagMatchMode.and.matches(recordTagIDs: [], selectedTagIDs: selected))
    }

    @Test("タグ1つならORとANDの結果は変わらない")
    func singleTagBehavesSameInBothModes() {
        let selected: Set<String> = ["food"]
        for mode in TagMatchMode.allCases {
            #expect(mode.matches(recordTagIDs: ["food"], selectedTagIDs: selected))
            #expect(!mode.matches(recordTagIDs: ["car"], selectedTagIDs: selected))
        }
    }

    @Test("タグ未選択ならどちらの条件でも全件を通す")
    func noSelectionMatchesEverything() {
        for mode in TagMatchMode.allCases {
            #expect(mode.matches(recordTagIDs: [], selectedTagIDs: []))
            #expect(mode.matches(recordTagIDs: ["food"], selectedTagIDs: []))
        }
    }

    @Test("既定はOR")
    func defaultModeIsOr() {
        #expect(TagMatchMode.defaultMode == .or)
        // 区切り記号も条件に対応している
        #expect(TagMatchMode.or.separator == " / ")
        #expect(TagMatchMode.and.separator == " & ")
    }

    // MARK: - 当日への頭出し

    @Test("未来日が並んでいても、当日に最も近い明細を指す")
    func targetsClosestToTodayAmongFutureRecords() {
        let today = date(2026, 9, 10)
        // 利用日の降順。先頭2件は未来
        let records = [
            input("future1", 2027, 6, 15, 100),
            input("future2", 2026, 10, 30, 200),
            input("today",   2026, 9, 13, 300),
            input("past1",   2026, 8, 20, 400),
        ]
        let index = RecordMonthTotals.closestToTodayIndex(in: records, today: today, calendar: calendar)
        #expect(index == 2)
        #expect(records[index ?? 0].id == "today")
    }

    @Test("昇順で並んでいても当日に近い明細を指す")
    func targetsClosestWhenAscending() {
        let today = date(2026, 9, 10)
        let records = [
            input("past1",   2026, 8, 20, 100),
            input("today",   2026, 9, 8, 200),
            input("future1", 2026, 10, 30, 300),
            input("future2", 2027, 6, 15, 400),
        ]
        let index = RecordMonthTotals.closestToTodayIndex(in: records, today: today, calendar: calendar)
        #expect(records[index ?? -1].id == "today")
    }

    @Test("当日ちょうどの明細があればそれを指す")
    func targetsExactToday() {
        let today = date(2026, 9, 10)
        let records = [
            input("future", 2026, 9, 20, 100),
            input("exact",  2026, 9, 10, 200),
            input("past",   2026, 9, 1, 300),
        ]
        let index = RecordMonthTotals.closestToTodayIndex(in: records, today: today, calendar: calendar)
        #expect(records[index ?? -1].id == "exact")
    }

    @Test("同じ距離なら先に並んでいる方を指す")
    func prefersEarlierIndexOnTie() {
        let today = date(2026, 9, 10)
        // 前後に3日ずつ。降順なので未来側が先
        let records = [
            input("future", 2026, 9, 13, 100),
            input("past",   2026, 9, 7, 200),
        ]
        let index = RecordMonthTotals.closestToTodayIndex(in: records, today: today, calendar: calendar)
        #expect(records[index ?? -1].id == "future")
    }

    @Test("すべて過去でも最も新しい明細を指す")
    func targetsNewestWhenAllPast() {
        let today = date(2026, 9, 10)
        let records = [
            input("newest", 2026, 8, 30, 100),
            input("older",  2026, 7, 30, 200),
        ]
        let index = RecordMonthTotals.closestToTodayIndex(in: records, today: today, calendar: calendar)
        #expect(records[index ?? -1].id == "newest")
    }

    @Test("明細が無ければ頭出し先も無い")
    func noTargetWhenEmpty() {
        #expect(RecordMonthTotals.closestToTodayIndex(in: [], today: date(2026, 9, 10), calendar: calendar) == nil)
    }

    // MARK: - 頭出しの再試行を止める条件

    @Test("手動スクロール後は再試行しない")
    func stopsRetryAfterUserScroll() {
        // 打ち切られていなければ実行する
        #expect(ScrollRetryPolicy.shouldScroll(isActive: true, issuedRequest: 1, currentRequest: 1))
        // ユーザーが触った後は、要求番号が同じでも実行しない
        #expect(!ScrollRetryPolicy.shouldScroll(isActive: false, issuedRequest: 1, currentRequest: 1))
    }

    @Test("新しい頭出し要求が来たら、古い予約は実行しない")
    func discardsRetriesFromOlderRequest() {
        #expect(!ScrollRetryPolicy.shouldScroll(isActive: true, issuedRequest: 1, currentRequest: 2))
        // 打ち切りと重なっていても当然実行しない
        #expect(!ScrollRetryPolicy.shouldScroll(isActive: false, issuedRequest: 1, currentRequest: 2))
    }

    @Test("時刻が入っていても日付単位で比べる")
    func comparesByDayNotTime() {
        // 当日の 23:59 と、翌日の 00:01。日付で見れば当日側が近い
        let late = DateComponents(year: 2026, month: 9, day: 10, hour: 23, minute: 59)
        let nextDay = DateComponents(year: 2026, month: 9, day: 11, hour: 0, minute: 1)
        let records = [
            RecordSummaryInput(id: "next", dateUse: calendar.date(from: nextDay) ?? Date(), amount: 100),
            RecordSummaryInput(id: "today", dateUse: calendar.date(from: late) ?? Date(), amount: 200),
        ]
        let index = RecordMonthTotals.closestToTodayIndex(
            in: records,
            today: date(2026, 9, 10),
            calendar: calendar
        )
        #expect(records[index ?? -1].id == "today")
    }
}
