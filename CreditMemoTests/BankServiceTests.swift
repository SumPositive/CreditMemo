import Foundation
import SwiftData
import Testing
@testable import CreditMemo

@MainActor
struct BankServiceTests {
    @Test("新規口座を Service で作成すると、context に保存される")
    func createInsertsAndSavesBank() throws {
        let context = try TestStore.makeContext()
        let bank = try BankService.create(zName: "新口座", context: context)
        let stored = try context.fetch(FetchDescriptor<E8bank>())
        #expect(stored.contains(where: { $0.id == bank.id }))
        #expect(bank.zName == "新口座")
    }

    @Test("口座削除で、配下カードの参照は外れ、関連支払も解消される")
    func deleteRemovesBankAndDetachesCards() throws {
        let context = try TestStore.makeContext()
        let bank = TestFixtures.makeBank(name: "削除予定", in: context)
        let card = TestFixtures.makeCard(name: "カード", bank: bank, in: context)
        _ = try TestFixtures.saveRecord(
            amount: 1_000,
            dateUse: TestStore.date(2026, 4, 5),
            card: card,
            in: context
        )
        try BankService.delete(bank, context: context)

        let banks = try context.fetch(FetchDescriptor<E8bank>())
        #expect(banks.contains(where: { $0.id == bank.id }) == false)
        #expect(card.e8bank == nil)

        // 口座参照を失った payment は (bank=nil, isPaid=false) に正規化される
        let payments = try context.fetch(FetchDescriptor<E7payment>())
            .filter { !$0.e2invoices.isEmpty }
        #expect(payments.allSatisfy { $0.e8bank == nil })

        let report = RecordService.checkBillingIntegrity(context: context)
        #expect(report.hasIssue == false)
    }
}
