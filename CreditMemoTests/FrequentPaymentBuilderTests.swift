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
        amount: Decimal = 0,
        in context: ModelContext
    ) -> E3record {
        let record = E3record(dateUse: date, zName: label, nAmount: amount)
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

    // 未ソート配列でも、期間外記録の後ろにある期間内記録を取りこぼさない
    @Test("期間判定は打ち切らず、入力の並び順に依存しない")
    func unsortedInputStillIncludesInPeriodRecords() throws {
        let context = try TestStore.makeContext()
        // わざと降順にせず、期間外(約13か月前)を先頭・期間内(5日前)を後ろに置く。
        // 旧実装(break)なら先頭の期間外で打ち切られ「期間内」が欠落していた
        let records = [
            makeRecord(label: "期間外", date: daysAgo(400), in: context),
            makeRecord(label: "期間内", date: daysAgo(5), in: context)
        ]

        let labels = FrequentPaymentBuilder.build(from: records).map(\.label)
        #expect(labels.contains("期間内"))
        // 12か月超は期間フィルタで除外される
        #expect(!labels.contains("期間外"))
    }

    // 音声入力の補塡は金額なしの基本カプセルを優先する
    // （＝音声で言った金額を上書き・補完しない）。手段・タグは補う。
    @Test("音声補塡の match は金額を持たない候補を返す")
    func matchPrefersAmountlessCandidateForVoice() throws {
        let context = try TestStore.makeContext()
        let card = TestFixtures.makeCard(name: "ETCカード", in: context)
        // 同じ金額(210)を3回使い、金額付きカプセル(既定 amountMinCount=3)を生成させる
        let records = sortedDesc([
            makeRecord(label: "ETC", date: daysAgo(3), card: card, amount: 210, in: context),
            makeRecord(label: "ETC", date: daysAgo(2), card: card, amount: 210, in: context),
            makeRecord(label: "ETC", date: daysAgo(1), card: card, amount: 210, in: context)
        ])
        let candidates = FrequentPaymentBuilder.build(from: records)
        // 前提: 金額付き(210)と基本(nil)の両カプセルが存在する
        #expect(candidates.contains { $0.label == "ETC" && $0.amount == 210 })
        #expect(candidates.contains { $0.label == "ETC" && $0.amount == nil })

        // 音声は金額を補完しないので、amount == nil の候補が返り、手段は補われる
        let matched = try #require(FrequentPaymentBuilder.match(label: "ETC", in: candidates))
        #expect(matched.amount == nil)
        #expect(matched.cardID == card.id)

        // 前後空白・大文字小文字を無視しても、金額なし候補を返す
        #expect(FrequentPaymentBuilder.match(label: "  etc  ", in: candidates)?.amount == nil)
        // 一致しないラベルは nil
        #expect(FrequentPaymentBuilder.match(label: "未登録", in: candidates) == nil)
    }

    // MARK: - 次点: 設定ノブごとの網羅

    // 集計期間の各境界（3/6/12/24/36か月）で、内側は含み外側は除外する
    @Test("ラベル抽出期間の境界で内側だけ含める")
    func periodBoundaryIncludesInsideExcludesOutside() throws {
        for months in [3, 6, 12, 24, 36] {
            let context = try TestStore.makeContext()
            let now = Date()
            let cutoff = Calendar.current.date(byAdding: .month, value: -months, to: now) ?? now
            // 境界の±3日で判定ゆらぎを避ける
            let inside = Calendar.current.date(byAdding: .day, value: 3, to: cutoff) ?? cutoff
            let outside = Calendar.current.date(byAdding: .day, value: -3, to: cutoff) ?? cutoff
            let records = sortedDesc([
                makeRecord(label: "IN", date: inside, in: context),
                makeRecord(label: "OUT", date: outside, in: context)
            ])
            let config = FrequentPaymentConfig(periodMonths: months)
            let labels = FrequentPaymentBuilder.build(from: records, config: config).map(\.label)
            #expect(labels.contains("IN"), "months=\(months): 期間内が欠落")
            #expect(!labels.contains("OUT"), "months=\(months): 期間外が混入")
        }
    }

    // 最小利用回数（1/2/3）で、回数がしきい値未満のラベルは候補にしない
    @Test("最小利用回数のしきい値で候補を絞る")
    func minUsesFiltersByThreshold() throws {
        // twice=2回, thrice=3回 の記録を毎回新しい context に作る
        func makeRecords(in context: ModelContext) -> [E3record] {
            sortedDesc([
                makeRecord(label: "twice", date: daysAgo(2), in: context),
                makeRecord(label: "twice", date: daysAgo(1), in: context),
                makeRecord(label: "thrice", date: daysAgo(3), in: context),
                makeRecord(label: "thrice", date: daysAgo(2), in: context),
                makeRecord(label: "thrice", date: daysAgo(1), in: context)
            ])
        }
        let expectations: [(min: Int, twice: Bool, thrice: Bool)] = [
            (1, true, true), (2, true, true), (3, false, true)
        ]
        for e in expectations {
            let context = try TestStore.makeContext()
            let records = makeRecords(in: context)
            let labels = FrequentPaymentBuilder.build(
                from: records, config: FrequentPaymentConfig(minUses: e.min)
            ).map(\.label)
            #expect(labels.contains("twice") == e.twice, "minUses=\(e.min)")
            #expect(labels.contains("thrice") == e.thrice, "minUses=\(e.min)")
        }
    }

    // 金額付きカプセルの最小回数（なし=nil / 3 / 5）で金額カプセルの有無が変わる
    @Test("amountMinCount で金額付きカプセルの出方が変わる")
    func amountMinCountControlsAmountCapsule() throws {
        func hasAmountCapsule(_ minCount: Int?) throws -> Bool {
            let context = try TestStore.makeContext()
            let card = TestFixtures.makeCard(name: "カード", in: context)
            let records = sortedDesc((1...3).map {
                makeRecord(label: "定額", date: daysAgo($0), card: card, amount: 500, in: context)
            })
            var config = FrequentPaymentConfig.default
            config.amountMinCount = minCount
            return FrequentPaymentBuilder.build(from: records, config: config)
                .contains { $0.label == "定額" && $0.amount == 500 }
        }
        // 3回なので nil は出さない、3 は出す、5 は満たさず出さない
        #expect(try hasAmountCapsule(nil) == false)
        #expect(try hasAmountCapsule(3) == true)
        #expect(try hasAmountCapsule(5) == false)
    }

    // hideBaseWhenAmounts で、金額付きがあるとき基本カプセルを隠す
    @Test("hideBaseWhenAmounts は金額付きがあるとき基本カプセルを隠す")
    func hideBaseWhenAmountsHidesBaseCapsule() throws {
        func baseVisible(hide: Bool) throws -> Bool {
            let context = try TestStore.makeContext()
            let card = TestFixtures.makeCard(name: "カード", in: context)
            let records = sortedDesc((1...3).map {
                makeRecord(label: "定額", date: daysAgo($0), card: card, amount: 500, in: context)
            })
            var config = FrequentPaymentConfig.default
            config.hideBaseWhenAmounts = hide
            return FrequentPaymentBuilder.build(from: records, config: config)
                .contains { $0.label == "定額" && $0.amount == nil }
        }
        #expect(try baseVisible(hide: false) == true)
        #expect(try baseVisible(hide: true) == false)
    }

    // 同一ラベルで複数金額がしきい値を満たすと、金額ごとに別カプセルを出す
    @Test("同一ラベルの複数金額はそれぞれ別カプセルになる")
    func multipleQualifyingAmountsProduceSeparateCapsules() throws {
        let context = try TestStore.makeContext()
        let card = TestFixtures.makeCard(name: "カード", in: context)
        var records: [E3record] = []
        for amount in [Decimal(100), Decimal(200)] {
            for day in 1...3 {
                records.append(makeRecord(label: "バス", date: daysAgo(day), card: card, amount: amount, in: context))
            }
        }
        let result = FrequentPaymentBuilder.build(from: sortedDesc(records))
        let busAmounts = Set(result.filter { $0.label == "バス" }.map { $0.amount })
        // 100・200 の金額カプセルと、基本(nil)の3種
        #expect(busAmounts == [100, 200, nil])
    }

    // ラベルの前後空白はトリムして同じバケットにまとめ、空文字は候補にしない
    @Test("ラベルは前後空白をトリムし、空文字は除外する")
    func labelWhitespaceTrimmedAndEmptyDropped() throws {
        let context = try TestStore.makeContext()
        let records = sortedDesc([
            makeRecord(label: " カフェ ", date: daysAgo(2), in: context),
            makeRecord(label: "カフェ", date: daysAgo(1), in: context),
            makeRecord(label: "   ", date: daysAgo(3), in: context)   // 空白のみ→除外
        ])
        let result = FrequentPaymentBuilder.build(from: records)
        // 前後空白違いは同じ「カフェ」に集約され、基本カプセルは1つ
        #expect(result.filter { $0.label == "カフェ" }.count == 1)
        // 空白のみのラベルはカプセル化されない
        #expect(!result.contains { $0.label.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    // limit が 0/1/60 のとき、返す件数が prefix される
    @Test("limit で返す候補件数を制限する")
    func limitCapsCandidateCount() throws {
        let context = try TestStore.makeContext()
        let records = sortedDesc([
            makeRecord(label: "A", date: daysAgo(1), in: context),
            makeRecord(label: "B", date: daysAgo(2), in: context),
            makeRecord(label: "C", date: daysAgo(3), in: context)
        ])
        #expect(FrequentPaymentBuilder.build(from: records, limit: 0).isEmpty)
        #expect(FrequentPaymentBuilder.build(from: records, limit: 1).count == 1)
        #expect(FrequentPaymentBuilder.build(from: records, limit: 60).count == 3)
    }

    // 負の limit は 0 件として扱う。素の prefix(limit) は負数でトラップするため、
    // このテストが落ちる場合はクラッシュ（プロセス終了）になる
    @Test("負の limit でもクラッシュせず 0 件を返す", arguments: [-1, -60, Int.min])
    func negativeLimitReturnsEmptyWithoutCrashing(limit: Int) throws {
        let context = try TestStore.makeContext()
        let records = sortedDesc([
            makeRecord(label: "A", date: daysAgo(1), in: context),
            makeRecord(label: "B", date: daysAgo(2), in: context)
        ])
        #expect(FrequentPaymentBuilder.build(from: records, limit: limit).isEmpty)
    }
}
