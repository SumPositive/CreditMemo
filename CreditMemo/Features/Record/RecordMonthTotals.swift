//
//  決済一覧の月計と、当日への頭出し位置の算出
//  View の状態から切り離し、ページ境界や未来日の扱いを単体で確かめられるようにする
//

import Foundation

/// 月計・頭出しの計算に必要な最小限の情報。
/// SwiftData のモデルに依存させないことで、単体テストから組み立てられる
struct RecordSummaryInput {
    let id: String
    let dateUse: Date
    let amount: Decimal

    init(id: String, dateUse: Date, amount: Decimal) {
        self.id = id
        self.dateUse = dateUse
        self.amount = amount
    }
}

enum RecordMonthTotals {

    /// 同じ年月かどうかを判定する識別子
    static func monthID(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)"
    }

    /// 月の最後の1件（＝その下に月計を出す決済）の id と、その月の合計を返す。
    ///
    /// - Parameters:
    ///   - loaded: 画面に載っている明細（利用日順に並んでいる前提）
    ///   - totalCount: 絞り込み後の全件数。`loaded.count` より多ければ続きが未読込
    ///   - nextUnloadedDate: 未読込の先頭にある明細の利用日（無ければ nil）
    ///
    /// 次ページに同じ月が続く場合は合計が確定しないため、その月の行は返さない。
    static func totalsByRecordID(
        loaded: [RecordSummaryInput],
        totalCount: Int,
        nextUnloadedDate: Date?,
        calendar: Calendar = .current
    ) -> [String: Decimal] {
        var totals: [String: Decimal] = [:]
        var runningTotal = Decimal.zero
        var currentMonthID: String?

        for (index, record) in loaded.enumerated() {
            let month = monthID(for: record.dateUse, calendar: calendar)
            if month != currentMonthID {
                // 月が変わったので合計を持ち越さない
                runningTotal = .zero
                currentMonthID = month
            }
            runningTotal += record.amount

            // 次の明細が同じ月なら、ここはまだ月の区切りではない
            let nextIndex = index + 1
            if nextIndex < loaded.count,
               monthID(for: loaded[nextIndex].dateUse, calendar: calendar) == month {
                continue
            }
            // 未読込のページに同じ月が続くなら、合計が確定していないので出さない
            if loaded.count < totalCount,
               let nextUnloadedDate,
               monthID(for: nextUnloadedDate, calendar: calendar) == month {
                continue
            }
            totals[record.id] = runningTotal
        }
        return totals
    }

    /// 今日との差が最も小さい明細の位置を返す。
    /// 未来日の明細が先頭に並んでいても、当日へ寄せた位置を指す
    static func closestToTodayIndex(
        in records: [RecordSummaryInput],
        today: Date,
        calendar: Calendar = .current
    ) -> Int? {
        let startOfToday = calendar.startOfDay(for: today)
        var targetIndex: Int?
        var closestDistance = TimeInterval.greatestFiniteMagnitude

        for index in records.indices {
            let date = calendar.startOfDay(for: records[index].dateUse)
            let distance = abs(date.timeIntervalSince(startOfToday))
            if distance < closestDistance {
                closestDistance = distance
                targetIndex = index
            }
        }
        return targetIndex
    }
}

/// 頭出しの再試行を続けてよいかの判定。
/// List の遅延生成に合わせて数回スクロールし直すが、
/// ユーザーが触った後まで続けると手動スクロールを引き戻してしまう
enum ScrollRetryPolicy {

    /// この再試行を実行してよいか。
    /// - Parameters:
    ///   - isActive: ユーザー操作で打ち切られていないか
    ///   - issuedRequest: この再試行が予約された時点の要求番号
    ///   - currentRequest: 現在の要求番号（新しい条件で頭出しし直すと増える）
    static func shouldScroll(
        isActive: Bool,
        issuedRequest: Int,
        currentRequest: Int
    ) -> Bool {
        // ユーザーが触ったら以降は動かさない
        guard isActive else { return false }
        // 新しい要求が来ていれば、古い予約は捨てる
        return issuedRequest == currentRequest
    }
}
