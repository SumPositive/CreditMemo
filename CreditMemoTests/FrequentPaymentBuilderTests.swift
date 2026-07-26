import Foundation
import SwiftData
import Testing
@testable import CreditMemo

@MainActor
struct FrequentPaymentBuilderTests {
    // build は dateUse 降順で渡す前提なので、生成後に降順へ整える
    private func sortedDesc(_ records: [E3record]) -> [E3record] {
        records.sorted { $0.dateUse > $1.dateUse }
    }

    // 集計期間（既定12か月）内に収まる相対日付を作る
    private func daysAgo(_ n: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -n, to: Date()) ?? Date()
    }

    private func makeRecord(
        label: String,
        date: Date,
        card: E1card? = nil,
        tags: [E5tag] = [],
        in context: ModelContext
    ) -> E3record {
        let record = E3record(dateUse: date, zName: label, nAmount: 0)
        record.dateUpdate = date
        record.e1card = card
        record.e5tags = tags
        context.insert(record)
        return record
    }

    // 代表カードが同数のとき、最終利用日が新しいカードを決定的に選ぶ
    @Test("代表カードの同数は最終利用日で決まる")
    func topCardTieBrokenByLatestUse() throws {
        let context = try TestStore.makeContext()
        let cardOld = TestFixtures.makeCard(name: "旧カード", in: context)
        let cardNew = TestFixtures.makeCard(name: "新カード", in: context)

        // 同じラベルで各カード2回ずつ（同数）。cardNew の方が新しい
        let records = sortedDesc([
            makeRecord(label: "ランチ", date: daysAgo(40), card: cardOld, in: context),
            makeRecord(label: "ランチ", date: daysAgo(39), card: cardOld, in: context),
            makeRecord(label: "ランチ", date: daysAgo(2), card: cardNew, in: context),
            makeRecord(label: "ランチ", date: daysAgo(1), card: cardNew, in: context)
        ])

        let result = FrequentPaymentBuilder.build(from: records)
        let base = try #require(result.first { $0.label == "ランチ" && $0.amount == nil })
        // 同数なので最終利用日が新しい cardNew が代表になる
        #expect(base.cardID == cardNew.id)
    }

    // 代表タグが同数のとき、最終利用日が新しいタグ組を決定的に選ぶ
    @Test("代表タグの同数は最終利用日で決まる")
    func topTagTieBrokenByLatestUse() throws {
        let context = try TestStore.makeContext()
        let tagOld = TestFixtures.makeTag(name: "旧タグ", in: context)
        let tagNew = TestFixtures.makeTag(name: "新タグ", in: context)

        let records = sortedDesc([
            makeRecord(label: "コーヒー", date: daysAgo(40), tags: [tagOld], in: context),
            makeRecord(label: "コーヒー", date: daysAgo(39), tags: [tagOld], in: context),
            makeRecord(label: "コーヒー", date: daysAgo(2), tags: [tagNew], in: context),
            makeRecord(label: "コーヒー", date: daysAgo(1), tags: [tagNew], in: context)
        ])

        let result = FrequentPaymentBuilder.build(from: records)
        let base = try #require(result.first { $0.label == "コーヒー" && $0.amount == nil })
        #expect(base.tagIDs == [tagNew.id])
    }

    // 回数・最終利用日が完全に同じでも、id（ラベル）昇順で決定的に並ぶ
    @Test("同スコアの候補は id 昇順で安定して並ぶ")
    func equalScoreCandidatesOrderedDeterministically() throws {
        let context = try TestStore.makeContext()
        // 3ラベルとも同一日・同一回数なのでスコアも最終利用日も完全一致させる
        let sharedDate = daysAgo(3)
        let records = sortedDesc([
            makeRecord(label: "Charlie", date: sharedDate, in: context),
            makeRecord(label: "Alpha", date: sharedDate, in: context),
            makeRecord(label: "Bravo", date: sharedDate, in: context)
        ])

        let labels = FrequentPaymentBuilder.build(from: records).map(\.label)
        #expect(labels == ["Alpha", "Bravo", "Charlie"])
    }
}
