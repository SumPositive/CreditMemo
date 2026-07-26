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
