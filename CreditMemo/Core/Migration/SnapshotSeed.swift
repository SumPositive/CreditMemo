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

        let cal = AppCalendar.gregorian
        let today = cal.startOfDay(for: Date())
        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today) ?? today }

        // 撮影言語に合わせたタグ。プリセット（ja 以外は英語）を言語に合わせて付け替え、足りない分は追加する
        let words = localizedWords()
        let tags = prepareTags(words.tags, context: context)
        func tag(_ key: TagKey) -> [E5tag] { tags[key].map { [$0] } ?? [] }

        // 利用日(=当日払なら引き落とし日)を各バケットに散らす:
        //   確認待ち(過去): -5 / 直近15日: +3, +6, +10 / 次の15日: +18, +22 / 将来: +35, +40, +50, +60
        // ラベルは「よくある決済」のカプセルとして新しい決済画面に並ぶので、撮影言語の言葉にする
        let samples: [(amount: Decimal, label: LabelKey, tags: [E5tag], cardIndex: Int, dateUse: Date)] = [
            (8600,  .restaurant,  tag(.food),         0, day(-5)),   // 確認待ち（overdue）
            (12800, .supermarket, tag(.food),         0, day(3)),    // 直近15日
            (1200,  .transitTopUp, tag(.topUp),       0, day(6)),    // 直近15日
            (3480,  .cafe,        tag(.food),         1, day(10)),   // 直近15日
            (1980,  .streaming,   tag(.subscription), 1, day(18)),   // 次の15日
            (2400,  .highwayToll, tag(.toll),         1, day(22)),   // 次の15日
            (54000, .electronics, tag(.important),    2, day(35)),   // 将来
            (2980,  .drugstore,   [],                 2, day(40)),   // 将来
            (29800, .travel,      tag(.important),    2, day(50)),   // 将来
            (7700,  .gym,         tag(.subscription), 2, day(60)),   // 将来
        ]

        for s in samples {
            _ = try? RecordService.addQuickRecord(
                amount: s.amount,
                label: words.labels[s.label] ?? "",
                card: card(s.cardIndex),
                tags: s.tags,
                dateUse: s.dateUse,
                context: context
            )
        }
        #endif
    }

    /// 新しい決済画面で、最初から選んでおくタグ（タグ欄にタグが並んだ状態を撮る）
    static func previewTags(from categories: [E5tag]) -> [E5tag] {
        #if DEBUG
        let words = localizedWords()
        let names = [TagKey.food, .important].compactMap { words.tags[$0] }
        return names.compactMap { name in categories.first { $0.zName == name } }
        #else
        return []
        #endif
    }

    // MARK: - 撮影言語の言葉

    enum TagKey: CaseIterable {
        case topUp, toll, caution, important, food, subscription
    }

    enum LabelKey {
        case restaurant, supermarket, transitTopUp, cafe, streaming
        case highwayToll, electronics, drugstore, travel, gym
    }

    struct Words {
        var tags: [TagKey: String]
        var labels: [LabelKey: String]
    }

    /// SeedData の英語タグプリセット名（ja 以外はこの名前で入る）
    private static let westernPresetTagNames: [TagKey: String] = [
        .topUp: "Top-up", .toll: "Toll", .caution: "Caution", .important: "Important",
    ]

    /// 撮影言語（SeedData と同じく Bundle.main.preferredLocalizations で判定）の言葉
    static func localizedWords() -> Words {
        switch Bundle.main.preferredLocalizations.first ?? "en" {
        case "ja":
            return Words(
                tags: [.topUp: "チャージ", .toll: "ETC", .caution: "注意", .important: "重要",
                       .food: "食費", .subscription: "サブスク"],
                labels: [.restaurant: "レストラン", .supermarket: "スーパー", .transitTopUp: "交通系チャージ",
                         .cafe: "カフェ", .streaming: "動画配信", .highwayToll: "高速道路",
                         .electronics: "家電量販店", .drugstore: "ドラッグストア", .travel: "旅行", .gym: "ジム"])
        case "de":
            return Words(
                tags: [.topUp: "Aufladung", .toll: "Maut", .caution: "Achtung", .important: "Wichtig",
                       .food: "Essen", .subscription: "Abo"],
                labels: [.restaurant: "Restaurant", .supermarket: "Supermarkt", .transitTopUp: "ÖPNV-Guthaben",
                         .cafe: "Café", .streaming: "Streaming", .highwayToll: "Autobahnmaut",
                         .electronics: "Elektronik", .drugstore: "Drogerie", .travel: "Reise", .gym: "Fitnessstudio"])
        case "ko":
            return Words(
                tags: [.topUp: "충전", .toll: "통행료", .caution: "주의", .important: "중요",
                       .food: "식비", .subscription: "구독"],
                labels: [.restaurant: "레스토랑", .supermarket: "마트", .transitTopUp: "교통카드 충전",
                         .cafe: "카페", .streaming: "스트리밍", .highwayToll: "고속도로",
                         .electronics: "전자제품", .drugstore: "드럭스토어", .travel: "여행", .gym: "헬스장"])
        case "zh-Hant":
            return Words(
                tags: [.topUp: "儲值", .toll: "過路費", .caution: "注意", .important: "重要",
                       .food: "餐飲", .subscription: "訂閱"],
                labels: [.restaurant: "餐廳", .supermarket: "超市", .transitTopUp: "悠遊卡儲值",
                         .cafe: "咖啡廳", .streaming: "串流影音", .highwayToll: "高速公路",
                         .electronics: "3C家電", .drugstore: "藥妝店", .travel: "旅遊", .gym: "健身房"])
        default:
            return Words(
                tags: [.topUp: "Top-up", .toll: "Toll", .caution: "Caution", .important: "Important",
                       .food: "Food", .subscription: "Subscription"],
                labels: [.restaurant: "Restaurant", .supermarket: "Supermarket", .transitTopUp: "Transit Top-up",
                         .cafe: "Cafe", .streaming: "Streaming", .highwayToll: "Highway Toll",
                         .electronics: "Electronics", .drugstore: "Drugstore", .travel: "Travel", .gym: "Gym"])
        }
    }

    /// プリセットのタグを撮影言語の名前に付け替え、無いタグを追加して、キーごとに返す
    private static func prepareTags(_ names: [TagKey: String], context: ModelContext) -> [TagKey: E5tag] {
        let existing = (try? context.fetch(FetchDescriptor<E5tag>())) ?? []
        var result: [TagKey: E5tag] = [:]
        for key in TagKey.allCases {
            guard let name = names[key] else { continue }
            let preset = existing.first { $0.zName == name }
                ?? westernPresetTagNames[key].flatMap { western in existing.first { $0.zName == western } }
            if let preset {
                preset.zName = name
                preset.sortName = name
                result[key] = preset
            } else {
                let tag = E5tag(zName: name, sortName: name)
                context.insert(tag)
                result[key] = tag
            }
        }
        return result
    }
}
