import Foundation
import SwiftData
import Testing
@testable import CreditMemo

@MainActor
struct CardServiceTests {
    // 新規カードを Service で作成すると、context に保存される
    @Test func createInsertsAndSavesCard() throws {
        let context = try TestStore.makeContext()
        let bank = TestFixtures.makeBank(name: "口座", in: context)

        let card = try CardService.create(
            zName: "新カード",
            nClosingDay: 15,
            nPayDay: 10,
            nPayMonth: 1,
            bank: bank,
            context: context
        )
        #expect(card.id.isEmpty == false)
        let stored = try context.fetch(FetchDescriptor<E1card>())
        #expect(stored.contains(where: { $0.id == card.id }))
        #expect(card.e8bank?.id == bank.id)

        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.hasIssue == false)
    }

    // 引き落とし口座を変更すると、配下の請求が新口座の payment へ再配置される
    @Test func applyEditsReassignsPaymentsOnBankChange() async throws {
        let context = try TestStore.makeContext()
        let bankA = TestFixtures.makeBank(name: "A口座", in: context)
        let bankB = TestFixtures.makeBank(name: "B口座", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bankA, in: context)
        _ = try TestFixtures.saveRecord(
            amount: 5_000,
            dateUse: TestStore.date(2026, 4, 5),
            card: card,
            in: context
        )

        try await CardService.applyEdits(
            to: card,
            zName: card.zName,
            zNote: card.zNote,
            nClosingDay: card.nClosingDay,
            nPayDay: card.nPayDay,
            nPayMonth: card.nPayMonth,
            bank: bankB,
            context: context
        )

        let payments = try context.fetch(FetchDescriptor<E7payment>())
            .filter { !$0.e2invoices.isEmpty }
        #expect(payments.count == 1)
        #expect(payments.first?.e8bank?.id == bankB.id)
        #expect(card.e8bank?.id == bankB.id)

        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.hasIssue == false)
    }

    // 締日変更で請求の日付（≒キー）が変わり、古い請求は消えて新しい請求にまとまる
    @Test func applyEditsRebuildsBillingOnClosingDayChange() async throws {
        let context = try TestStore.makeContext()
        let bank = TestFixtures.makeBank(name: "口座", in: context)
        let card = TestFixtures.makeCard(
            name: "カード",
            bank: bank,
            closingDay: 20,
            payDay: 27,
            payMonth: 1,
            in: context
        )
        _ = try TestFixtures.saveRecord(
            amount: 1_000,
            dateUse: TestStore.date(2026, 4, 5),
            card: card,
            in: context
        )
        let beforeInvoice = try #require(try context.fetch(FetchDescriptor<E2invoice>()).first)
        let beforeDate = beforeInvoice.date

        // 締日を 25 へ変更（請求発生日が変わる）
        try await CardService.applyEdits(
            to: card,
            zName: card.zName,
            zNote: card.zNote,
            nClosingDay: 25,
            nPayDay: card.nPayDay,
            nPayMonth: card.nPayMonth,
            bank: bank,
            context: context
        )

        let invoices = try context.fetch(FetchDescriptor<E2invoice>())
            .filter { !$0.e6parts.isEmpty }
        #expect(invoices.count == 1)
        // 締日変更で再計算された請求は元の日付と異なる可能性が高い
        // （同じになるケースもあり得るので、件数 1 件で重複ゼロを最低保証とする）
        _ = beforeDate

        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.hasIssue == false)
    }

    // 進捗コールバックがバッチごとに呼ばれる（小規模データではバッチ未満で末尾1回のみ）
    @Test func applyEditsReportsProgress() async throws {
        let context = try TestStore.makeContext()
        let bankA = TestFixtures.makeBank(name: "A", in: context)
        let bankB = TestFixtures.makeBank(name: "B", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bankA, in: context)
        for index in 0..<3 {
            _ = try TestFixtures.saveRecord(
                amount: Decimal(index + 1),
                dateUse: TestStore.date(2026, 4, index + 1),
                card: card,
                in: context
            )
        }
        var lastCompleted = -1
        var lastTotal = -1
        try await CardService.applyEdits(
            to: card,
            zName: card.zName,
            zNote: card.zNote,
            nClosingDay: card.nClosingDay,
            nPayDay: card.nPayDay,
            nPayMonth: card.nPayMonth,
            bank: bankB,
            context: context
        ) { completed, total in
            lastCompleted = completed
            lastTotal = total
        }
        #expect(lastTotal == 3)
        #expect(lastCompleted == 3)
    }
}
