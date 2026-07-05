//
//  SnapshotSeed.swift
//  fastlane snapshot 撮影時に、金額の入ったサンプル明細を投入する。
//
//  【重要】DEBUG ビルド限定・起動引数 -FASTLANE_SNAPSHOT YES のときだけ動く。
//  投入先は in-memory コンテナ（AppMain 側で用意）なので、実ユーザーの
//  永続ストアや Release ビルドには一切影響しない。
//
//  カード/口座/タグは既存の SeedData を流用し、明細(E3record)と
//  それに伴う請求(E2invoice)・支払(E7payment) は RecordService.addQuickRecord 経由で
//  作る（リレーションの整合を既存ロジックに任せ、手組みの破綻を避ける）。
//

import Foundation
import SwiftData

@MainActor
enum SnapshotSeed {

    /// fastlane snapshot 実行中か（起動引数 -FASTLANE_SNAPSHOT YES）
    static var isActive: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "FASTLANE_SNAPSHOT")
        #else
        return false
        #endif
    }

    /// 撮影用のサンプルデータを投入する。空のときだけ実行。
    static func seedIfNeeded(context: ModelContext) {
        #if DEBUG
        // まずカード/口座/タグのプリセット（言語に追従）
        SeedData.seedIfNeeded(context: context)

        // 既に明細があれば二重投入しない
        let recordCount = (try? context.fetchCount(FetchDescriptor<E3record>())) ?? 0
        guard recordCount == 0 else { return }

        let cards = (try? context.fetch(
            FetchDescriptor<E1card>(sortBy: [SortDescriptor(\.nRow)])
        )) ?? []

        // 引き落とし日の決まり方（BillingService.billingDate）:
        //  - N日後型(nClosingDay==0): 利用日 + nPayDay 日
        //  - 締日/支払日型:            締日・支払日ロジックで翌月等
        // メイン画面の「Debit Status（直近N日合計）」は E7payment.date（=引き落とし日）が
        // 「今日〜今日+14日」の未払のみ集計する。よってサンプルの引き落とし日がこの窓に
        // 入らないと $0 になる（言語ではなくカードの締日設定依存で ja だけ入って見えた原因）。
        //
        // 引き落とし状況(PaymentList)のサマリーは upcoming(=引き落とし日が明日以降)を
        // 3 バケットに分けて集計する（windowDays=15 の既定時。build/windowRange 参照）:
        //   - 直近15日合計 : 引き落とし日が [今日,    今日+14]  ※ただし今日ちょうどは
        //                    overdue(確認待ち)側に入るので、乗せるなら [今日+1, 今日+14]
        //   - 次の15日合計 : 引き落とし日が [今日+15, 今日+29]
        //   - 将来の合計   : 引き落とし日が 今日+30 以降
        //
        // 当日払(N日後型 payDay=0)カードは「引き落とし日＝利用日」なので、利用日を
        // ずらすだけで引き落とし日を直接コントロールできる（payDay の月ズレに悩まない）。
        // 全ロケールで当日払系を必ず1枚持つ（ja=当日払 / western=Same-Day Payment）ので
        // これを主に使い、利用日で各バケットに配置する。
        // ＋確認待ち(overdue)も 1 件残すため、過去日の 1 件を混ぜる。
        let sameDayCards = cards.filter { $0.nClosingDay == 0 && $0.nPayDay == 0 }
        let anyNDay      = cards.filter { $0.nClosingDay == 0 }
        let usableCards  = !sameDayCards.isEmpty ? sameDayCards
                         : (!anyNDay.isEmpty ? anyNDay : cards)
        guard !usableCards.isEmpty else { return }
        func card(_ i: Int) -> E1card { usableCards[i % usableCards.count] }

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today) ?? today }

        // 利用日(=当日払なら引き落とし日)を各バケットに散らす:
        //   確認待ち(過去): -5 / 直近15日: +3, +10 / 次の15日: +18 / 将来: +35, +50
        let samples: [(amount: Decimal, label: String, cardIndex: Int, dateUse: Date)] = [
            (8600,  "Restaurant",   0, day(-5)),   // 確認待ち（overdue）
            (12800, "Supermarket",  0, day(3)),    // 直近15日
            (3480,  "Cafe",         1, day(10)),   // 直近15日
            (1980,  "Streaming",    1, day(18)),   // 次の15日
            (54000, "Electronics",  2, day(35)),   // 将来
            (29800, "Travel",       2, day(50)),   // 将来
        ]

        for s in samples {
            _ = try? RecordService.addQuickRecord(
                amount: s.amount,
                label: s.label,
                card: card(s.cardIndex),
                dateUse: s.dateUse,
                context: context
            )
        }
        #endif
    }
}
