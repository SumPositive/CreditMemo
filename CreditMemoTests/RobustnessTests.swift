import Foundation
import SwiftData
import Testing
@testable import CreditMemo

@MainActor
struct RobustnessTests {
    @Test("決済を削除すると孤児の請求・支払も掃除される")
    func deleteRecordRemovesOrphanBilling() throws {
        let context = try TestStore.makeContext()
        let bank = TestFixtures.makeBank(name: "口座", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bank, in: context)

        let record = try TestFixtures.saveRecord(
            amount: 5_000,
            dateUse: TestStore.date(2026, 4, 5),
            card: card,
            in: context
        )
        #expect(try context.fetch(FetchDescriptor<E2invoice>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<E7payment>()).count == 1)

        try RecordService.delete(record, context: context)

        #expect(try context.fetch(FetchDescriptor<E3record>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<E6part>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<E2invoice>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<E7payment>()).isEmpty)

        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.hasIssue == false)
    }

    @Test("カードの引き落とし口座を変更すると、過去請求も新口座の E7payment に再配置される")
    func cardBankChangeReassignsPayments() throws {
        let context = try TestStore.makeContext()
        let bankA = TestFixtures.makeBank(name: "A口座", in: context)
        let bankB = TestFixtures.makeBank(name: "B口座", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bankA, in: context)

        _ = try TestFixtures.saveRecord(
            amount: 1_000,
            dateUse: TestStore.date(2026, 4, 5),
            card: card,
            in: context
        )

        // 初期は A 口座に紐づく
        let payment0 = try #require(try context.fetch(FetchDescriptor<E7payment>()).first)
        #expect(payment0.e8bank?.id == bankA.id)

        // 引き落とし口座を切り替えてから整合性掃除を呼ぶ（CardService 経由ではなく直接で十分）
        card.e8bank = bankB
        RecordService.cleanupOrphanBilling(context: context)

        let paymentsAfter = try context.fetch(FetchDescriptor<E7payment>())
            .filter { !$0.e2invoices.isEmpty }
        #expect(paymentsAfter.count == 1)
        #expect(paymentsAfter.first?.e8bank?.id == bankB.id)

        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.hasIssue == false)
    }

    @Test("cleanupOrphanBilling は冪等（連続呼び出しで状態が変わらない）")
    func cleanupOrphanBillingIsIdempotent() throws {
        let context = try TestStore.makeContext()
        let bank = TestFixtures.makeBank(name: "口座", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bank, in: context)

        for day in [3, 7, 15] {
            _ = try TestFixtures.saveRecord(
                amount: Decimal(day * 1_000),
                dateUse: TestStore.date(2026, 4, day),
                card: card,
                in: context
            )
        }
        RecordService.cleanupOrphanBilling(context: context)
        let snapshot1 = try snapshot(context)
        RecordService.cleanupOrphanBilling(context: context)
        let snapshot2 = try snapshot(context)
        #expect(snapshot1 == snapshot2)

        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.hasIssue == false)
    }

    @Test("同一の (日付 + 口座 + 状態) を持つ重複 payment は normalize で 1 件に統合される")
    func duplicatePaymentsAreNormalized() throws {
        let context = try TestStore.makeContext()
        let bank = TestFixtures.makeBank(name: "口座", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bank, in: context)

        _ = try TestFixtures.saveRecord(
            amount: 1_000,
            dateUse: TestStore.date(2026, 4, 5),
            card: card,
            in: context
        )
        let originalPayment = try #require(try context.fetch(FetchDescriptor<E7payment>()).first)

        // 同じキーを持つ重複 payment を意図的に挿入してから掃除を呼ぶ
        let dupe = E7payment(date: originalPayment.date)
        dupe.e8unpaid = bank
        bank.e7unpaids.append(dupe)
        context.insert(dupe)
        #expect(try context.fetch(FetchDescriptor<E7payment>()).count == 2)

        RecordService.cleanupOrphanBilling(context: context)
        let paymentsAfter = try context.fetch(FetchDescriptor<E7payment>())
        #expect(paymentsAfter.count == 1)

        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.hasIssue == false)
    }

    @Test("古い履歴のまとめ削除で、対象だけが消えて整合性は保たれる")
    func deleteRecordsOlderThanYears() async throws {
        let context = try TestStore.makeContext()
        let bank = TestFixtures.makeBank(name: "口座", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bank, in: context)

        let oldDate = Calendar.current.date(byAdding: .year, value: -5, to: Date()) ?? Date()
        let recentDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        _ = try TestFixtures.saveRecord(amount: 1, dateUse: oldDate, card: card, in: context)
        _ = try TestFixtures.saveRecord(amount: 2, dateUse: recentDate, card: card, in: context)

        #expect(try context.fetch(FetchDescriptor<E3record>()).count == 2)
        try await RecordService.deleteRecords(olderThanYears: 3, context: context)
        let remaining = try context.fetch(FetchDescriptor<E3record>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.dateUse == recentDate)

        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.hasIssue == false)
    }

    @Test("決済手段の口座変更は、対象記録と兄弟記録の再構築を1回の保存で完了する")
    func cardBankChangeReassignsAllSiblingsInSingleSave() throws {
        let context = try TestStore.makeContext()
        let bankA = TestFixtures.makeBank(name: "A口座", in: context)
        let bankB = TestFixtures.makeBank(name: "B口座", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bankA, in: context)

        // 別月にして請求・支払が記録ごとに分かれる状態を作る
        var records: [E3record] = []
        for month in [4, 5, 6] {
            records.append(try TestFixtures.saveRecord(
                amount: Decimal(month * 1_000),
                dateUse: TestStore.date(2026, month, 5),
                card: card,
                in: context
            ))
        }
        let paymentsBefore = try context.fetch(FetchDescriptor<E7payment>())
            .filter { !$0.e2invoices.isEmpty }
        #expect(paymentsBefore.count == 3)
        #expect(paymentsBefore.allSatisfy { $0.e8bank?.id == bankA.id })

        // 編集画面と同じ手順: 保存直前にカードの口座を変え、対象記録＋兄弟をまとめて保存する
        card.e8bank = bankB
        try RecordService.saveFromEditor(records[0], rebuildSiblingsForCard: card, context: context)

        // 単一トランザクションで完了し、未保存変更が残らない
        #expect(context.hasChanges == false)
        // 対象記録だけでなく兄弟記録の支払も全て新口座へ移る（部分更新が起きない）
        let paymentsAfter = try context.fetch(FetchDescriptor<E7payment>())
            .filter { !$0.e2invoices.isEmpty }
        #expect(paymentsAfter.count == 3)
        #expect(paymentsAfter.allSatisfy { $0.e8bank?.id == bankB.id })

        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.hasIssue == false)
    }

    @Test("新規の複数回払いを最初から済みにしても、全明細が1回の保存で済みになる")
    func newInstallmentMarkedPaidCommitsAllPartsInSingleSave() throws {
        let context = try TestStore.makeContext()
        let bank = TestFixtures.makeBank(name: "口座", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bank, in: context)

        // 「済み側から追加」相当の 2 回払い新規記録
        let record = E3record(
            dateUse: TestStore.date(2026, 4, 5),
            zName: "2回払い",
            nAmount: 2_000,
            nPayType: 2,
            nRepeat: 0
        )
        record.e1card = card
        context.insert(record)

        try RecordService.saveFromEditor(record, markAllPartsPaid: true, context: context)

        // 単一トランザクションで完了する
        #expect(context.hasChanges == false)
        // 全明細が済みの請求に属し、途中まで済みの部分更新が残らない
        let parts = try context.fetch(FetchDescriptor<E6part>())
        #expect(parts.count == 2)
        #expect(parts.allSatisfy { $0.e2invoice?.isPaid == true })
        let invoices = try context.fetch(FetchDescriptor<E2invoice>())
        #expect(!invoices.isEmpty)
        #expect(invoices.allSatisfy { $0.isPaid })

        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.hasIssue == false)
    }

    @Test("メタ情報だけの編集が保存失敗したら、未保存のラベル・メモ・タグも残らない")
    func metadataSaveFailureRollsBackUnsavedEdits() throws {
        let context = try TestStore.makeContext()
        let bank = TestFixtures.makeBank(name: "口座", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bank, in: context)
        let tag = TestFixtures.makeTag(name: "タグ", in: context)

        let record = try TestFixtures.saveRecord(
            amount: 1_000,
            label: "元ラベル",
            dateUse: TestStore.date(2026, 4, 5),
            card: card,
            in: context
        )
        record.zNote = "元メモ"
        try RecordService.saveMetadata(record, context: context)
        let snapshotBefore = try snapshot(context)

        // 編集画面と同じ手順: 保存前に記録モデルへ直接書き込んでから保存を試みる
        RecordService.commitFailureForTesting = TestSaveError.forced
        defer { RecordService.commitFailureForTesting = nil }

        record.zName = "新ラベル"
        record.zNote = "新メモ"
        record.e5tags = [tag]

        #expect(throws: TestSaveError.self) {
            try RecordService.saveMetadata(record, context: context)
        }

        // 失敗後に未保存変更が残らない（後続の自動保存で確定してしまわない）
        #expect(context.hasChanges == false)
        // 直接書き込んだメタ情報も変更前へ戻る
        #expect(record.zName == "元ラベル")
        #expect(record.zNote == "元メモ")
        #expect(record.e5tags.isEmpty)
        // DB 全体の件数も変わらない
        #expect(try snapshot(context) == snapshotBefore)

        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.hasIssue == false)
    }

    @Test("口座変更の保存が失敗したら、対象記録も兄弟記録も旧口座のまま戻る")
    func editorSaveFailureRollsBackCardBankChange() throws {
        let context = try TestStore.makeContext()
        let bankA = TestFixtures.makeBank(name: "A口座", in: context)
        let bankB = TestFixtures.makeBank(name: "B口座", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bankA, in: context)

        // 成功経路のテストと同じく、別月にして請求・支払を記録ごとに分ける
        var records: [E3record] = []
        for month in [4, 5, 6] {
            records.append(try TestFixtures.saveRecord(
                amount: Decimal(month * 1_000),
                dateUse: TestStore.date(2026, month, 5),
                card: card,
                in: context
            ))
        }
        let snapshotBefore = try snapshot(context)

        RecordService.commitFailureForTesting = TestSaveError.forced
        defer { RecordService.commitFailureForTesting = nil }

        // 編集画面と同じ手順: 保存直前にカードの口座を変えてから保存を試みる
        card.e8bank = bankB
        #expect(throws: TestSaveError.self) {
            try RecordService.saveFromEditor(
                records[0],
                rebuildSiblingsForCard: card,
                context: context
            )
        }

        // 未保存変更が残らない
        #expect(context.hasChanges == false)
        // 保存直前に書き換えたカードの口座も戻る（部分的な口座変更が残らない）
        #expect(card.e8bank?.id == bankA.id)
        // 兄弟記録を含む全支払が旧口座のまま
        let paymentsAfter = try context.fetch(FetchDescriptor<E7payment>())
            .filter { !$0.e2invoices.isEmpty }
        #expect(paymentsAfter.count == 3)
        #expect(paymentsAfter.allSatisfy { $0.e8bank?.id == bankA.id })
        #expect(try snapshot(context) == snapshotBefore)

        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.hasIssue == false)
    }

    @Test("新規を済みにする保存が失敗したら、記録ごと残らず途中まで済みの明細も出ない")
    func editorSaveFailureRollsBackNewPaidRecord() throws {
        let context = try TestStore.makeContext()
        let bank = TestFixtures.makeBank(name: "口座", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bank, in: context)

        let snapshotBefore = try snapshot(context)

        RecordService.commitFailureForTesting = TestSaveError.forced
        defer { RecordService.commitFailureForTesting = nil }

        // 「済み側から追加」相当の 2 回払い新規記録
        let record = E3record(
            dateUse: TestStore.date(2026, 4, 5),
            zName: "2回払い",
            nAmount: 2_000,
            nPayType: 2,
            nRepeat: 0
        )
        record.e1card = card
        context.insert(record)

        #expect(throws: TestSaveError.self) {
            try RecordService.saveFromEditor(record, markAllPartsPaid: true, context: context)
        }

        // 未保存の insert ごと破棄され、途中まで済みの明細も残らない
        #expect(context.hasChanges == false)
        #expect(try context.fetch(FetchDescriptor<E3record>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<E6part>()).isEmpty)
        #expect(try snapshot(context) == snapshotBefore)

        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.hasIssue == false)
    }

    private enum TestSaveError: Error {
        case forced
    }

    private func snapshot(_ context: ModelContext) throws -> Snapshot {
        Snapshot(
            recordCount: try context.fetch(FetchDescriptor<E3record>()).count,
            partCount: try context.fetch(FetchDescriptor<E6part>()).count,
            invoiceCount: try context.fetch(FetchDescriptor<E2invoice>()).count,
            paymentCount: try context.fetch(FetchDescriptor<E7payment>()).count
        )
    }

    private struct Snapshot: Equatable {
        let recordCount: Int
        let partCount: Int
        let invoiceCount: Int
        let paymentCount: Int
    }
}
